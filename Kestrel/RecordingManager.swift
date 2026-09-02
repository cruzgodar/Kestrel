import AVFoundation
import CoreHaptics
import CoreLocation
import Foundation
import Observation
import SwiftUI
import UIKit
import WatchConnectivity

@Observable
@MainActor
final class RecordingManager {
    private(set) var isRecording = false
    /// True while audio is being streamed in from the Apple Watch companion.
    /// The Identify view disables its own record button while this is true.
    private(set) var watchRecording = false
    /// Whether a paired Apple Watch currently has the Kestrel watch app
    /// installed. Pushed from `WatchAudioBridge` on activation and whenever the
    /// watch state changes. Drives watch-specific UI copy/controls (the Identify
    /// placeholder text and the Settings "Prefer Apple Watch microphone" toggle).
    private(set) var isWatchAppInstalled = false
    private(set) var detections: [Detection] = []
    private(set) var errorMessage: String?
    /// Set when a recording attempt was refused because location access — and so
    /// the nearby-species filter — is unavailable. Drives an alert offering to
    /// open Settings. The view clears it on dismiss (hence not `private(set)`).
    var showLocationPermissionAlert = false
    /// Set when a recording attempt was refused because microphone access is
    /// denied. Drives an alert offering to open Settings, mirroring the location
    /// one. Cleared by the view on dismiss (hence not `private(set)`).
    var showMicPermissionAlert = false
    /// Set when the user taps stop on a session the *watch* started, to ask
    /// whether the birding walk should be saved to Fitness, resumed, or thrown
    /// away. The walk lives on the watch (it owns the `HKWorkoutSession`), so the
    /// answer is relayed with the stop rather than acted on here. Cleared by the
    /// view on dismiss (hence not `private(set)`).
    var showWatchWorkoutPrompt = false
    /// When the current watch-driven session started, so a stop can tell a real
    /// walk from an accidental tap and skip the prompt for the latter — matching
    /// the watch's own `minimumDuration` cutoff, below which it discards the walk
    /// without asking either.
    private var watchSessionStart: Date?
    /// When the current phone-mic session started, used to tell a session that
    /// ran long enough to count toward the review prompt from a tap-and-stop.
    /// See `ReviewPrompt`.
    private var localSessionStart: Date?
    /// Mirrors `WatchWorkoutManager.minimumDuration`: shorter than this and the
    /// watch throws the walk away regardless, so there's nothing to ask about.
    /// `nonisolated` so `shouldPromptForWatchWorkout` — which is, so a test can
    /// drive it — can read it.
    ///
    /// **The two are measured from different events, and the order matters.**
    /// This one counts from `watchSessionStart`, stamped when the watch's `start`
    /// handshake arrives; the watch counts from the tap that sent it, 320 ms
    /// earlier. So the watch's elapsed is always the larger of the two, and the
    /// only disagreement possible is the phone declining to prompt for a walk the
    /// watch would have kept — which sends `.ask` and puts the question on the
    /// wrist instead. The opposite order is the one that loses data: the phone
    /// offering Save for a walk the watch then discards as too short, with the
    /// relayed `.save` finding nothing to write. That is what the watch dating
    /// its walk from the tap prevents — see `WatchWorkoutManager.isLongEnough`,
    /// which used to date it from the audio-engine bring-up seconds later.
    private nonisolated static let minimumWorkoutDuration: TimeInterval = 15
    /// True when location access is explicitly *denied* or *restricted* (not merely
    /// undetermined). The Identify tab grays the record button and shows a lock
    /// glyph in this state; undetermined keeps the normal button so the first tap
    /// can still bring up the system prompt. Seeded at launch and kept current via
    /// the location provider's authorization-change callback.
    private(set) var locationAccessDenied = false
    /// True when microphone access is explicitly *denied* (not merely
    /// undetermined). Like `locationAccessDenied`, this grays the record button —
    /// recording can't proceed without the mic. Seeded at launch and refreshed
    /// whenever the app returns to the foreground (there's no system callback for
    /// mic-permission changes, so we re-read it on foreground).
    private(set) var micAccessDenied = false
    /// Whether recording is currently blocked by a *denied* permission (mic or
    /// location). The record button is grayed (a locked, tap-to-open-Settings
    /// state) while this holds.
    ///
    /// The **phone's** button only. The watch used to be told this too, as a
    /// tri-state pushed over the application context, back when the phone's
    /// microphone and location were what a watch-started session ran on. They
    /// aren't: the watch records with its own mic and sends its own coordinate,
    /// and its record button is gated by `WatchSessionManager.permissionDenied` —
    /// the watch's own permissions, which are per-device and can only be granted
    /// from the wrist. Nothing on the watch has read the pushed state since. See
    /// `watchAppContext`, which that push used to share.
    var recordingBlocked: Bool { locationAccessDenied || micAccessDenied }
    /// True while neither permission Kestrel needs has been answered yet, which
    /// is what puts the first-launch `WelcomeView` up over the app. Seeded in
    /// `preload()` and cleared by `requestOnboardingPermissions()`; see the
    /// welcome screen for why this is derived from the permissions themselves
    /// rather than from a "has launched before" flag.
    private(set) var needsOnboarding = false
    /// IDs (scientific names) of detections whose confidence was just upgraded;
    /// the UI flashes their row yellow while they're in this set.
    private(set) var flashIDs: Set<String> = []
    /// Scientific names already in the life list when this recording session
    /// began. Used both by the UI (to decide which rows get the purple tint)
    /// and by `process(window:)` (to color the spectrogram detection band
    /// purple instead of goldenrod). Captured by the view via
    /// `snapshotLifeList(_:)` on the false → true transition of `isRecording`.
    private(set) var lifeListSnapshot: Set<String> = []
    /// Live set of scientific names the user has starred — read straight off the
    /// store, never frozen, so notifications, alert haptics and the spectrogram's
    /// blue band react to a star toggled mid-session.
    ///
    /// Read rather than pushed. This was a mirror the Identify tab kept up to
    /// date from an `.onChange`, which was true enough when starring happened
    /// only on that tab. It doesn't any more: the map's pin and cluster-grid
    /// menus, the full-screen viewer's menu, and the life-list row's own menu all
    /// toggle stars, and every one of them is reachable with Identify deselected
    /// — at which point whether the mirror updated came down to whether SwiftUI
    /// had re-evaluated an off-screen tab's body. `refreshLifeListFromStore` and
    /// `merge`'s `recorded` already read the store directly for exactly this
    /// reason; this is the last of the three that didn't.
    ///
    /// Empty with no store, which is only previews — nothing there records.
    var starredNames: Set<String> { lifeListStore?.starredNames ?? [] }

    /// Pushed from `KestrelApp`'s tab + scene-phase observers. When false,
    /// new-species events fire a local notification instead of relying on
    /// the in-app UI.
    var spectrogramVisible: Bool = true

    /// True while the iOS app is foregrounded (scene active), regardless of
    /// which tab is showing or which microphone is the audio source. Pushed
    /// from `KestrelApp`'s scene-phase observer. When true, fresh new/starred
    /// detections buzz the *phone* locally; when false, the haptic is sent to
    /// the watch instead.
    var appForegrounded: Bool = false

    /// The life list, wired up in `KestrelApp.init`. Held weakly since the
    /// app owns it for its whole lifetime. The manager reads it directly at
    /// session start so `lifeListSnapshot`/`starredNames` are correct even
    /// when a session is kicked off from the watch while the iOS app is
    /// suspended in the background and no SwiftUI view is observing — the
    /// case that otherwise left the snapshot empty and made every detection
    /// look like a brand-new species.
    weak var lifeListStore: LifeListStore?

    let spectrogram = SpectrogramRenderer()

    private let pipeline = AudioPipeline()
    private let locationProvider = LocationProvider()
    private var classifierTask: Task<BirdNETClassifier, Error>?
    private var rangeFilterTask: Task<SpeciesRangeFilter, Error>?
    private var allowedIndices: Set<Int>?
    private var detectionMap: [String: Detection] = [:]
    /// The session's per-species flash / haptic / notification clocks. One value
    /// rather than three dictionaries so `reset()` can't clear some of them and
    /// miss another — which is exactly what happened to the notification clock.
    /// See `DetectionCooldowns`.
    private var cooldowns = DetectionCooldowns()
    /// Scientific name of the species currently shown on the watch's "now
    /// hearing" screen, so we only push an update when it actually changes.
    /// Reset at the start of every session.
    private var lastWatchDisplaySci: String?
    /// When the watch's "now hearing" display was last pushed. The watch resets
    /// its own display to the placeholder after `idleDisplayReset` (60 s) with no
    /// update; because we otherwise de-dupe a continuously-heard bird (only
    /// pushing on a *species change*), that bird would silently drop off the watch
    /// while the phone still shows a fresh observation. So we also re-push the
    /// same species if it's still being heard and this much time has passed —
    /// comfortably under the watch's reset so its timer stays armed.
    private var lastWatchDisplayAt: Date?
    /// Re-push interval for an unchanged, still-heard watch display. Half the
    /// watch's 60 s idle-reset window, so a continuously-singing bird refreshes
    /// the watch with margin to spare.
    private let watchDisplayRefreshInterval: TimeInterval = 30
    /// The application context mirrored to the watch. `updateApplicationContext`
    /// *replaces* the whole dictionary each call, so every key is merged through
    /// this single owner rather than clobbering the others. Unlike a live
    /// `sendMessage`, the application context is delivered even from a
    /// backgrounded phone — the case where a watch-first session runs with the
    /// phone in a pocket.
    ///
    /// The now-hearing bird is currently its only occupant. It shared it with a
    /// `recordingAuthState` key until that was removed as dead — see
    /// `recordingBlocked` — and the merge is kept because the sharing is what
    /// `clearWatchBirdDisplay` needs to be able to remove *only* its own keys.
    private var watchAppContext: [String: Any] = [:]
    /// Monotonic tag on each now-hearing push. `updateApplicationContext` de-dupes
    /// identical dictionaries, so without this a re-push of the *same* still-singing
    /// species (which keeps the watch's 60 s idle-reset armed) would be dropped and
    /// the bird would silently fall back to the placeholder. Bumped per push so
    /// every one is a distinct context that actually delivers; the watch de-dupes
    /// on it so a context re-delivered for an unrelated key change doesn't re-flash.
    ///
    /// Seeded from the wall clock rather than starting at zero. The watch keeps
    /// the last sequence it saw for as long as *its* process lives, which
    /// routinely outlasts the phone app's — and a counter that restarted at zero
    /// could hand back a number the watch had already retired, which the watch
    /// would then correctly ignore, swallowing a real now-hearing update. Launch
    /// time is monotonic across launches, so a fresh phone process always
    /// out-numbers anything it said last time.
    private var watchDisplaySeq = Int(Date().timeIntervalSince1970)
    /// Tracks the deferred audio engine start/stop task so rapid taps can
    /// cancel a pending transition before its sleep elapses.
    private var pendingTransitionTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?
    /// Lazily-created Core Haptics engine for the new-lifer tap+buzz pattern.
    /// Rebuilt on demand if the system stops it (e.g. after an interruption).
    private var hapticEngine: CHHapticEngine?

    // Watch-audio ingestion state. Samples arrive 16 kHz Float mono from the
    // watch; we upsample to 48 kHz via linear interpolation, hand them to the
    // spectrogram, and accumulate into BirdNET-sized windows.
    private var watchWindowBuffer: [Float] = []
    private var watchLastSample: Float = 0
    /// Coordinate the *watch* supplied for the current session (via the
    /// `watchLocation` handshake). The watch now sends its own GPS so a watch-first
    /// user — whose iPhone may never have been opened — still gets a nearby-species
    /// filter: the phone runs BirdNET but no longer needs its own location. When
    /// set, `refreshSpeciesFilter` builds the filter from here instead of the
    /// phone's location.
    ///
    /// Cleared at both ends of a watch session — `startFromWatch` and
    /// `stopFromWatch` — and read only through `sessionCoordinate`, which
    /// ignores it outside a session anyway. Two guards for one invariant because
    /// the failure was silent and long-lived: a coordinate that outlived its
    /// session made the phone stop consulting its own location for good.
    private var watchSuppliedCoordinate: (lat: Double, lon: Double)?
    /// Silent-audio playback used to keep the iOS app alive in the
    /// background while the watch is the audio source.
    private let watchKeepalive = BackgroundAudioKeepalive()
    /// Liveness watchdog for a watch-sourced session: confirms audio is actually
    /// arriving (not merely that the watch *thinks* it's recording). When a
    /// `watchAudioStallThreshold` window passes with no chunks while we believe a
    /// session is active, we ask the watch to tear down and restart its capture.
    private var watchHeartbeatTask: Task<Void, Never>?
    /// Sends a periodic "phone is alive and considers the session active" beat to
    /// the watch, which runs its own watchdog on it. Ticks for the whole of
    /// *either* kind of session — the watch capturing, or the watch mirroring a
    /// phone-mic one — so the watch can distinguish "phone still here" from
    /// "phone gone / session ended."
    ///
    /// It used to tick only while `watchRecording`, which left the mirror with no
    /// liveness signal at all: kill the phone app mid-session and the wrist sat
    /// on "Listening on iPhone…" indefinitely, because the `phoneStop` that
    /// clears it is something only a living app sends.
    private var phoneHeartbeatTask: Task<Void, Never>?
    /// Timestamp of the most recent audio chunk delivered by the watch.
    private var lastWatchAudioAt: Date?
    /// A stall of this length nudges the watch to restart its capture *once* — a
    /// backstop, since the watch now recovers its own engine from interruptions
    /// and re-queues dropped chunks. Deliberately generous: brief reachability
    /// dips (the wrist dropping) are normal and must not trip a restart, which is
    /// what made the old 10s / per-poll churn disconnect sessions within ~30s.
    private let watchAudioStallThreshold: TimeInterval = 20
    /// How often the liveness watchdog polls. The heartbeat sender uses the same
    /// cadence.
    ///
    /// `static`, so the two polling loops can read it without a `self?.` — which
    /// is what they used to do, each supplying its own fallback for the weak
    /// unwrap, and one of them supplied 3 rather than 5. A value with a second,
    /// different value standing behind it isn't one cadence, it's two.
    private nonisolated static let watchWatchdogInterval: TimeInterval = 5
    /// If no watch audio arrives for this long the watch is effectively gone (app
    /// killed, out of range, dead battery); we stop so the keepalive isn't left
    /// draining the phone, and notify.
    private let watchGiveUpThreshold: TimeInterval = 90
    /// True once we've asked the watch to restart capture for the *current* silent
    /// stretch, so we nudge only once per stall rather than every poll. Cleared as
    /// soon as audio resumes (`ingestWatchSamples16k`).
    private var watchStallNudged = false

    /// Watchdog that *asks* whether to end the recording once the session goes
    /// long enough without any detection — it does not stop it (see
    /// `checkIdleAndMaybePrompt`, which posts a notification carrying an "End
    /// Session" action). The threshold is the user's "Timeout After No
    /// Detections" setting (`AppSettings.noBirdTimeout`, 30 min by default;
    /// `.never` suppresses the prompt). Reset each time `merge(_:)` sees at
    /// least one result; armed in `startLocally`/`startFromWatch`; cancelled in
    /// `stop`/`stopFromWatch`.
    private var idleTerminationTask: Task<Void, Never>?
    private var lastDetectionAt: Date?
    /// True once the idle-timeout *prompt* has been sent for the current silent
    /// stretch, so the watchdog asks once (rather than re-nagging every poll)
    /// until a fresh detection resets the clock. Unlike the old behavior, the
    /// watchdog no longer stops the session on its own — it asks, via a rich
    /// notification whose "End Session" action does the stopping.
    private var idlePromptSent = false

    init() {
        registerInterruptionObserver()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// Begins loading the BirdNET classifier and the species-range model in
    /// background tasks so the first Start Recording tap is fast. Safe to call
    /// multiple times; subsequent calls are no-ops.
    /// Whether location access is currently granted (when-in-use or always).
    var locationAuthorized: Bool {
        let status = locationProvider.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// Reacts to a location authorization change: refreshes the denied flag the
    /// record button reads.
    private func handleLocationAuthorizationChange(_ status: CLAuthorizationStatus) {
        locationAccessDenied = (status == .denied || status == .restricted)
    }

    /// Re-reads the microphone permission and refreshes `micAccessDenied`. There's
    /// no system callback for mic-permission changes (unlike location), so the app
    /// calls this whenever it returns to the foreground — the user may have flipped
    /// the toggle in Settings while away.
    func refreshMicrophoneAuthorization() {
        let denied = AVAudioApplication.shared.recordPermission == .denied
        guard denied != micAccessDenied else { return }
        micAccessDenied = denied
    }

    /// Runs the first-launch permission sequence behind the welcome screen's Get
    /// Started button, then takes the screen down.
    ///
    /// Same order as `startLocally` — microphone, then location, then
    /// notifications — each awaited so only one system prompt is ever on screen.
    /// Unlike `startLocally` this doesn't stop at the first refusal: a user who
    /// declines the microphone should still get to answer the rest here, rather
    /// than being re-prompted for them piecemeal later.
    ///
    /// Only the phone's own permissions. HealthKit — which the phone *could*
    /// request on the watch's behalf, since authorization is shared across the
    /// pair — is deliberately left to the watch: it can't spare the watch its
    /// welcome screen either way (microphone and location on watchOS are
    /// per-device), so asking here would only put a Health sheet in front of a
    /// phone-only user who will never record a workout.
    func requestOnboardingPermissions() async {
        _ = await requestMicrophonePermission()
        _ = await isLocationAuthorized(prompt: true)
        await SpeciesNotifications.shared.requestAuthorizationIfNeeded()

        // The app stays *inactive* for as long as a system alert is up — and
        // for a moment after the last one is answered, while it dismisses.
        // SwiftUI applies view updates without animation in that state, so
        // clearing the flag any earlier means the welcome screen's crossfade
        // (see `RootView`) is skipped and it vanishes in a single frame.
        // Waiting also lands the fade after the alert has finished dismissing,
        // which is where it wants to be anyway.
        await waitUntilActive()

        needsOnboarding = false
    }

    /// Suspends until the app is foreground-active again, polling because
    /// there's no `await`-able form of the scene phase down here. Bounded: if
    /// the user answered the last prompt and immediately left, the caller still
    /// gets to finish rather than hanging on a state that isn't coming back.
    private func waitUntilActive(timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while UIApplication.shared.applicationState != .active, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    func preload() {
        // Track location authorization changes (button gating + watch state), and
        // seed the current value. Idempotent — re-assigning the callback is fine.
        locationProvider.onAuthorizationChange = { [weak self] status in
            self?.handleLocationAuthorizationChange(status)
        }
        locationAccessDenied = {
            let status = locationProvider.authorizationStatus
            return status == .denied || status == .restricted
        }()
        // Seed the mic-denied flag too, so the record button is grayed at launch
        // when mic access was previously denied.
        micAccessDenied = AVAudioApplication.shared.recordPermission == .denied

        // A brand-new install has answered *neither* prompt — put the welcome
        // screen up rather than letting the first Start Recording tap fire two
        // system dialogs with no explanation behind them. Deliberately `&&`, not
        // `||`: once either has been answered the app has been used, and an
        // existing user (say one who declined the mic long ago, leaving location
        // never asked) shouldn't be met by an introduction on upgrade.
        needsOnboarding =
            AVAudioApplication.shared.recordPermission == .undetermined
            && locationProvider.authorizationStatus == .notDetermined

        if classifierTask == nil {
            classifierTask = Task.detached(priority: .userInitiated) {
                try BirdNETClassifier()
            }
        }
        if rangeFilterTask == nil {
            rangeFilterTask = Task.detached(priority: .utility) {
                try SpeciesRangeFilter()
            }
        }

        // Pre-warm the audio pipeline in the background. Runs at .userInitiated
        // so it doesn't get scheduled behind the classifier load on the
        // executor; pipeline.start() awaits this task before activating the
        // session itself, so the two can't race on the shared AVAudioSession.
        pipeline.startPrewarm()

        // Warm the location/range-filter lookup once per launch, so the first
        // session starts with a nearby list already computed rather than waiting
        // on a fix. Only when location is *already* authorized — a fresh install
        // must not surface the location prompt at launch; that's deferred to the
        // first Start Recording tap.
        //
        // `preload()` runs on every session start too, hence the flag: without
        // one this would re-request on every start, on top of the request the
        // start path makes itself. It used to be gated on `locationStatus`
        // instead — a caption string that no view has read for some time — which
        // worked only by accident and made the double-request above depend on
        // which of the two got there first.
        if !didWarmSpeciesFilter, locationAuthorized {
            didWarmSpeciesFilter = true
            Task { await self.refreshSpeciesFilter() }
        }
    }

    /// Whether `preload()` has already asked for this launch's first species
    /// filter. See the note at the call site.
    @ObservationIgnored private var didWarmSpeciesFilter = false

    func toggle() async {
        if watchRecording {
            // Active session was started on / for the watch, so there's a
            // birding walk on the wrist waiting to be saved or thrown away. Ask
            // here rather than letting the watch ask afterwards — the user is
            // looking at the phone, and the prompt would otherwise be sitting
            // unanswered on a wrist they aren't looking at. `stopWatchSession`
            // then relays their answer along with the stop.
            if watchWalkIsSaveable {
                showWatchWorkoutPrompt = true
            } else {
                // Too short to be a real walk — the watch discards it without
                // asking, so neither should we.
                stopWatchSession(workout: .ask)
            }
        } else if isRecording {
            stop()
        } else {
            await start()
        }
    }

    /// Entry point for the Start Recording app intent (lock-screen widget /
    /// Shortcuts). Starts a new session only when nothing is already running,
    /// so a tap while recording is a no-op rather than a restart.
    func startFromIntent() async {
        guard !isRecording, !watchRecording else { return }
        await start()
    }

    /// Start recording on the phone. Tapping Start Recording on the phone always
    /// listens on the phone's own microphone; the watch's own Start button is
    /// what captures on the watch.
    func start() async {
        await startLocally()
    }

    /// Records whether a paired watch has the watch app installed. Called by
    /// `WatchAudioBridge` from the `WCSessionDelegate` callbacks.
    func updateWatchAppInstalled(_ installed: Bool) {
        isWatchAppInstalled = installed
    }

    /// Update the watch's "now hearing" screen with a freshly-heard species —
    /// any species, since the watch always shows the last one heard. `highlight`
    /// ("starred"/"newSpecies"/"normal") tints the pill behind the species name
    /// on the watch. No haptic:
    /// buzzing is reserved for new/starred birds and sent via `sendHapticToWatch`.
    private func sendBirdDisplayToWatch(commonName: String, scientificName: String, highlight: String) {
        // The "now hearing" bird is latest-state, not an event, so it rides the
        // application context rather than `sendToWatch`'s sendMessage/transferUserInfo
        // funnel. A backgrounded phone (the usual watch-first case) reports
        // `isReachable == false`, so a live send falls to `transferUserInfo` — an
        // opportunistic background queue iOS delivers with large, unpredictable
        // latency, which left the watch stuck on "Listening…" while the phone was
        // recognizing birds. `updateApplicationContext` delivers promptly even from
        // the background and coalesces to the latest, exactly matching a single
        // now-hearing slot. (Haptics stay on `sendToWatch` — they're events that
        // need immediacy, and application-context coalescing would drop rapid ones.)
        watchDisplaySeq &+= 1
        mergeWatchAppContext([
            "birdCommon": commonName,
            "birdSci": scientificName,
            "highlight": highlight,
            "birdSeq": watchDisplaySeq,
        ])
    }

    /// Merges `updates` into the watch application context and re-publishes it.
    /// The single owner of `updateApplicationContext` (see `watchAppContext`), so
    /// keys coexist instead of overwriting one another.
    ///
    /// The dictionary is updated whether or not there is a watch to push it to,
    /// so the context the next push carries is always the current one — the
    /// alternative bails before the merge and silently drops state whenever the
    /// watch happens to be unpaired at that moment.
    private func mergeWatchAppContext(_ updates: [String: Any]) {
        watchAppContext.merge(updates) { _, new in new }
        pushWatchAppContext()
    }

    /// The keys `sendBirdDisplayToWatch` owns — the whole now-hearing slot.
    private static let watchBirdContextKeys = ["birdCommon", "birdSci", "highlight", "birdSeq"]

    /// Drops the now-hearing bird from the mirrored context at the end of a
    /// session.
    ///
    /// The context is *latest state*, and without this the last bird of a session
    /// stayed in it forever: nothing else removes a key, and the context the watch
    /// holds is re-delivered to it on relaunch. The watch's `birdSeq` de-dupe hid
    /// that right up until the watch app *was* relaunched, which resets its
    /// last-seen sequence: from then on the first context to arrive announced a
    /// bird from a walk that had already ended, as the one the phone was hearing
    /// now.
    ///
    /// The re-publish this does is now the only thing that can carry a stale bird
    /// over. It used to be reached far more often, by every unrelated
    /// `mergeWatchAppContext` — the dead `recordingAuthState` push fired on any
    /// watch-state change and re-published the whole dictionary, that bird
    /// included.
    private func clearWatchBirdDisplay() {
        var changed = false
        for key in Self.watchBirdContextKeys where watchAppContext.removeValue(forKey: key) != nil {
            changed = true
        }
        guard changed else { return }
        pushWatchAppContext()
    }

    private func pushWatchAppContext() {
        guard let s = connectedWatch else { return }
        try? s.updateApplicationContext(watchAppContext)
    }

    /// Buzz the wrist for a fresh new/starred bird. The kind picks a distinct
    /// `WKHapticType` on the watch (sharper for starred, softer for a new
    /// species) and is independent of the display — an already-known bird
    /// updates the screen without a tap.
    private func sendHapticToWatch(reason: SpeciesNotifications.Reason) {
        let kind: String
        switch reason {
        case .starred:    kind = "starred"
        case .newSpecies: kind = "newSpecies"
        }
        sendToWatch(["haptic": kind])
    }

    /// Buzz the wrist with a single subtle tap for an ordinary (known,
    /// non-starred) bird — the "Haptic for All Birds" opt-in. Maps to the watch's
    /// lightest `WKHapticType` (see `WatchSessionManager.playHaptic`).
    private func sendSoftHapticToWatch() {
        sendToWatch(["haptic": "soft"])
    }

    /// Buzz the *phone* for a fresh new/starred bird while its app is
    /// foregrounded. Mirrors the watch's distinction: a softer `.success`
    /// notification for a starred bird, and a sharp tap followed by a buzz for a
    /// brand-new lifer (the phone analogue of the watch's `.notification`).
    private func playLocalHaptic(reason: SpeciesNotifications.Reason) {
        switch reason {
        case .starred:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .newSpecies:
            playNewLiferHaptic()
        }
    }

    /// Buzz the *phone* with a single subtle tap for an ordinary (known,
    /// non-starred) bird — the "Haptic for All Birds" opt-in, fired while the app
    /// is foregrounded. A soft impact is the gentlest of the system generators.
    private func playSoftLocalHaptic() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// A crisp transient tap immediately followed by a short continuous buzz —
    /// the phone version of the watch's brand-new-lifer alert. The canned
    /// `UINotificationFeedbackGenerator` styles can't express a tap→buzz, so
    /// this builds it with Core Haptics. Falls back to a `.warning` notification
    /// on hardware without haptics or if the engine fails to start.
    private func playNewLiferHaptic() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        do {
            let engine: CHHapticEngine
            if let existing = hapticEngine {
                engine = existing
            } else {
                engine = try CHHapticEngine()
                // Forget the engine if the system stops it (e.g. audio
                // interruption) so the next lifer lazily rebuilds it; recover
                // in place on a reset.
                engine.stoppedHandler = { [weak self] _ in
                    Task { @MainActor in self?.hapticEngine = nil }
                }
                engine.resetHandler = { [weak engine] in try? engine?.start() }
                hapticEngine = engine
            }
            try engine.start()

            // Sharp tap at t=0, then a softer, less-sharp buzz a beat later.
            let tap = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
                ],
                relativeTime: 0
            )
            let buzz = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
                ],
                relativeTime: 0.12,
                duration: 0.28
            )
            let pattern = try CHHapticPattern(events: [tap, buzz], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    /// The paired watch's session, or `nil` when there is nothing to send to.
    ///
    /// The single gate every send in this file passes through. It used to be
    /// copied inline at each one, and the copies had drifted: `stopWatchSession`
    /// and the two capture-restart / give-up sends checked nothing at all (or
    /// only `activationState`), so they were the only messages in the app that
    /// could be handed to an unpaired session or one with no watch app on it.
    /// Harmless in itself — the send simply fails — but a guard that some callers
    /// keep and others don't is the shape a real omission hides in.
    private var connectedWatch: WCSession? {
        guard WCSession.isSupported() else { return nil }
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else {
            return nil
        }
        return s
    }

    /// Shared watch delivery. Live `sendMessage` is the fast path when the watch
    /// app is reachable; `transferUserInfo` is the background-tolerant fallback
    /// — used both when unreachable and as the recovery path for a `sendMessage`
    /// that races the app backgrounding (it queues and can wake a suspended app).
    private func sendToWatch(_ payload: [String: Any]) {
        guard let s = connectedWatch else { return }
        if s.isReachable {
            s.sendMessage(payload, replyHandler: nil, errorHandler: { _ in
                WCSession.default.transferUserInfo(payload)
            })
        } else {
            s.transferUserInfo(payload)
        }
    }

    /// Sends on **both** channels at once, rather than picking one.
    ///
    /// For the handful of control messages a session's teardown depends on —
    /// `remoteStop`, `restartCapture` — where the live send's immediacy is worth
    /// having *and* a queued copy is worth having if the watch is suspended, and
    /// where the watch is idempotent about receiving both. Everything else goes
    /// through `sendToWatch`, which picks the one channel that fits.
    ///
    /// Sending on both is also exactly what makes a stale delivery certain
    /// rather than merely possible — the queued copy always exists — which is
    /// why every payload that goes this way names the session it means. See
    /// `watchSessionPayload`.
    private func sendToWatchOnBothChannels(_ payload: [String: Any]) {
        guard let s = connectedWatch else { return }
        s.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        s.transferUserInfo(payload)
    }

    /// Stamps a command aimed at the watch's *own capture session* with the
    /// token naming it, so the watch can refuse one meant for a session that has
    /// since ended (see `WatchSessionManager.captureCommandApplies`).
    ///
    /// A no-op when there is no token — an older watch build sends none, and
    /// those commands keep applying unconditionally on the far side.
    private func watchSessionPayload(_ payload: [String: Any]) -> [String: Any] {
        guard let watchSessionToken else { return payload }
        var out = payload
        out["session"] = watchSessionToken
        return out
    }

    /// What the user chose for the birding walk on the phone's stop prompt.
    /// Mirrors `WatchSessionManager.WorkoutDecision` on the watch side, which
    /// decodes the raw value off the `remoteStop` payload. `.ask` leaves the
    /// question to the watch (the pre-existing behavior).
    enum WatchWorkoutDecision: String {
        case ask, save, discard
    }

    /// Whether a stop should raise the save/resume/discard prompt: only for a
    /// watch session that has run long enough for the watch to be holding a walk
    /// worth deciding about, and only when the watch can actually write it.
    private var watchWalkIsSaveable: Bool {
        guard watchRecording, let start = watchSessionStart else { return false }
        return Self.shouldPromptForWatchWorkout(
            elapsed: Date().timeIntervalSince(start),
            watchReportsSavable: watchWorkoutSavable
        )
    }

    /// The two facts a stop prompt turns on, as a pure function so the pairing
    /// with the watch's own `canOfferSave` is pinned by a test.
    ///
    /// Duration is the half the phone can answer for itself. The other half is the
    /// watch's HealthKit authorization — per-device, grantable only from the wrist
    /// — and asking about it was the whole bug: the phone offered "Save Workout"
    /// to a user who had denied workout sharing, and the tap did nothing at all,
    /// because the watch had already refused to park the walk and discarded it.
    ///
    /// `nil` means the watch hasn't said (an older watch build, or a handshake
    /// that hasn't landed) and keeps the previous behavior of asking. Only an
    /// explicit `false` suppresses the prompt, so a missing message can't cost the
    /// user a walk they could have saved.
    nonisolated static func shouldPromptForWatchWorkout(
        elapsed: TimeInterval,
        watchReportsSavable: Bool?
    ) -> Bool {
        elapsed >= minimumWorkoutDuration && watchReportsSavable != false
    }

    /// Whether the paired watch can write a birding walk to HealthKit, as it last
    /// reported. `nil` until it says.
    ///
    /// Deliberately **not** cleared between sessions: it describes the watch's
    /// standing HealthKit authorization, not anything about one walk, so the last
    /// answer stays the best answer until a newer one arrives.
    private(set) var watchWorkoutSavable: Bool?

    /// The watch reported whether it could save a walk. See
    /// `shouldPromptForWatchWorkout`.
    func updateWatchWorkoutSavable(_ savable: Bool) {
        watchWorkoutSavable = savable
    }

    /// The user answered the phone's prompt. Relays the decision to the watch
    /// with the stop, so the walk is saved or dropped without a second prompt
    /// appearing on the wrist.
    func resolveWatchWorkout(_ decision: WatchWorkoutDecision) {
        showWatchWorkoutPrompt = false
        stopWatchSession(workout: decision)
    }

    private func stopWatchSession(workout: WatchWorkoutDecision) {
        // Named, for the reason every other cross-device stop is: this goes out
        // on both channels, and the queued copy can be delivered after the
        // session it means has ended and another has begun. Unlike the rest it
        // also carries a *decision*, so a stale copy wouldn't merely stop the
        // wrong walk — a relayed `.discard` would throw it away.
        sendToWatchOnBothChannels(
            watchSessionPayload(["cmd": "remoteStop", "workout": workout.rawValue])
        )
        // Tear our own side down immediately rather than waiting for the watch's
        // "stop" handshake to flip our state. If the watch has died (battery,
        // crash, out of range with no app left to answer) that handshake never
        // arrives — the phone would stay stuck in the watch-recording state and
        // the stop button would appear dead until the 60 s heartbeat watchdog
        // eventually fired. Stopping locally makes the button always work: a
        // live watch still gets `remoteStop` above and tears its own capture +
        // workout down, and the "stop" it echoes back is a harmless no-op here
        // (guarded by `watchRecording`, already false). Incoming audio from a
        // still-running watch is ignored once `watchRecording` is false.
        stopFromWatch()
        // Ending a watch session from the phone's own stop button still counts as
        // ending a session from the phone, so it can raise the review prompt.
        // `stopFromWatch` above has already banked the session's length.
        ReviewPrompt.requestIfDue()
    }

    func startLocally() async {
        // If a pending stop task is in its post-animation sleep, drop it before
        // we kick off a fresh start. Same applies the other direction.
        pendingTransitionTask?.cancel()
        pendingTransitionTask = nil

        guard !isRecording else { return }

        // If the engine is still running because we just cancelled a pending
        // stop task before it could fire pipeline.stop, this is a "resume" of
        // the same recording, not a fresh one. Flip the UI flag back and bail
        // — re-running pipeline.start on an already-running engine causes the
        // tap to be re-installed and audio to double-process.
        if pipeline.isRunning {
            isRecording = true
            // The stop that preceded this already banked the elapsed time (see
            // `stop`), so the resumed stretch is timed from here.
            if localSessionStart == nil { localSessionStart = Date() }
            // Everything `stop` tore down has to come back, even though the
            // audio engine never went away. It cancelled the idle watchdog and
            // told the watch the phone had stopped, both unconditionally and
            // both before it knew whether the engine would actually be stopped —
            // so a resume that skipped this left the session running with no
            // "no birds heard" timeout for the rest of the walk and a watch that
            // had gone dark. Deliberately *not* the rest of a fresh start: the
            // detections, cooldowns and spectrogram are this same session's and
            // are meant to carry over.
            announceLocalSessionStart()
            return
        }

        errorMessage = nil

        // Microphone first — it's the permission recording most fundamentally
        // needs, so it leads the sequence (mic → location → notifications). Prompt
        // if undetermined; if it's denied, surface the Settings alert and don't
        // start. (No inline error text — the grayed button + alert convey it.)
        guard await requestMicrophonePermission() else {
            showMicPermissionAlert = true
            return
        }

        // The nearby-species filter — and thus recording — needs location access.
        // Prompt if undetermined; if it's denied, surface the Settings alert and
        // don't start. One prompt at a time: this awaits the mic choice above.
        guard await isLocationAuthorized(prompt: true) else {
            showLocationPermissionAlert = true
            return
        }

        // Now (and only now, after mic + location) ask for notification permission,
        // so detected birds can notify in the background.
        await SpeciesNotifications.shared.requestAuthorizationIfNeeded()

        detections = []
        detectionMap = [:]
        flashIDs = []
        cooldowns.reset()
        lastWatchDisplaySci = nil
        lastWatchDisplayAt = nil
        spectrogram.reset()
        refreshLifeListFromStore()
        isRecording = true
        localSessionStart = Date()
        // A *fresh* session, so it gets a fresh name. The resume path above
        // deliberately doesn't bump this: it is the same session carrying on, and
        // the watch is still holding the token it was given.
        localSessionToken &+= 1

        announceLocalSessionStart()

        // Audio engine startup secretly uses main-thread time even when called
        // from a detached task (AVAudioEngine posts route-change callbacks to
        // main during first activation). Letting it run concurrently with the
        // button morph animation freezes the UI for ~200 ms. We defer the
        // engine start until just after the animation has committed.
        let pipeline = self.pipeline
        let spectrogram = self.spectrogram
        pendingTransitionTask = Task.detached(priority: .userInitiated) { [weak self] in
            await pipeline.awaitPrewarm()
            // Wait out the morph animation. Cancel-aware sleep so a rapid
            // tap that flips us back to stop can short-circuit this task.
            do {
                try await Task.sleep(for: .milliseconds(280))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            do {
                try pipeline.start(
                    onWindow: { [weak self] window in
                        Task { @MainActor in
                            await self?.process(window: window)
                        }
                    },
                    onChunk: { chunk in
                        spectrogram.ingest(chunk)
                    }
                )
            } catch {
                let message = "Failed to start audio: \(error.localizedDescription)"
                await MainActor.run { [weak self] in
                    self?.failLocalStart(message)
                }
                Log.error("Failed to start pipeline — \(error)")
            }
        }

        preload()
        Task { await self.refreshSpeciesFilter() }
    }

    /// Names the current phone-mic session, so a `stopPhone` the watch sent about
    /// an *earlier* one can be recognized and ignored.
    ///
    /// The watch sends `stopPhone` on both channels at once, and the queued copy
    /// outlives app suspension — so it can be flushed after a later session has
    /// already begun and end a recording the user never asked to stop.
    /// `localStopApplies` closes the half of this where the later session is
    /// watch-sourced; the token closes the half where it is another phone-mic one,
    /// which that guard cannot see.
    ///
    /// Seeded from the wall clock rather than zero, for the reason
    /// `watchDisplaySeq` is: the watch keeps the token for as long as *its*
    /// process lives, which routinely outlasts the phone app's, and a counter that
    /// restarted at zero could reissue one the watch is still holding from a
    /// previous launch — at which point a genuinely stale stop would look current.
    private var localSessionToken = Int(Date().timeIntervalSince1970)

    /// Whether a `stopPhone` relayed by the watch still describes the session
    /// that is running now.
    ///
    /// A `nil` token is an older watch build, which sends none; those keep the
    /// previous behavior of applying unconditionally rather than being dropped,
    /// since refusing them would leave the watch's Stop button dead.
    nonisolated static func mirrorStopApplies(requestToken: Int?, currentToken: Int) -> Bool {
        requestToken == nil || requestToken == currentToken
    }

    /// Ends the phone's own recording on behalf of the watch's Stop button, when
    /// the watch was mirroring *this* session. See `localSessionToken`.
    func stopLocalSession(fromWatchMirror token: Int?) {
        guard Self.mirrorStopApplies(
            requestToken: token, currentToken: localSessionToken
        ) else {
            Log.info("Ignoring a stopPhone for a session that has already ended")
            return
        }
        stop()
    }

    /// Everything a phone-mic session has to announce and arm once
    /// `isRecording` is true, whether this is a fresh start or a resume of one
    /// the pending-stop window caught mid-teardown.
    ///
    /// Both paths call it, and that is the point. `stop()` cancels the idle
    /// watchdog and sends `phoneStop` before it knows whether the engine will
    /// actually be stopped, so a resume has exactly as much to put back as a
    /// fresh start does — but the resume path returns early by design (the
    /// engine, the detections and the spectrogram are all still this session's)
    /// and quietly returned past both of these. One function neither path can
    /// skip is what keeps them from drifting again.
    private func announceLocalSessionStart() {
        // Mirror this phone-mic session onto the watch so its "now hearing"
        // screen shows the same birds, as though the watch were the source. The
        // token comes back on the watch's `stopPhone` so a stale one can be told
        // from a current one — see `localSessionToken`.
        sendToWatch(["cmd": "phoneStart", "session": localSessionToken])
        // The mirror needs a heartbeat as much as a watch-sourced session does —
        // see `phoneHeartbeatTask`. There is no audio-liveness watchdog to pair
        // it with here, because no audio crosses the link in this direction.
        startPhoneHeartbeat()
        startIdleWatchdog()
    }

    /// Rolls a local start back when the audio engine never came up.
    ///
    /// The start is announced optimistically — `isRecording` flips, the idle
    /// watchdog is armed, and the watch is told `phoneStart` — *before* the
    /// deferred engine bring-up, so the record button's morph isn't stuck behind
    /// it. Every one of those has to be undone when the bring-up throws, and
    /// clearing `isRecording` on its own isn't enough: `stop()` is what sends
    /// `phoneStop`, and this path deliberately doesn't go through `stop()`
    /// (there is no running engine to tear down). Without the rollback the watch
    /// sat on "Listening on iPhone…" for a session that never began, with no
    /// audio arriving and no way back except stopping it from the wrist.
    ///
    /// A no-op past the flags if the user already tapped stop while the engine
    /// was coming up — `stop()` has then done all of this — but the error itself
    /// is still worth showing, so it is set either way.
    private func failLocalStart(_ message: String) {
        errorMessage = message
        guard isRecording else { return }
        isRecording = false
        // Nothing ran, so nothing counts toward the review threshold.
        localSessionStart = nil
        cancelIdleWatchdog()
        cancelPhoneHeartbeat()
        // Named, like the `phoneStart` it undoes. `sendToWatch` picks whichever
        // channel fits *at this moment*, so a stop sent while the watch app is
        // unreachable is queued while a start moments later goes out live — and
        // the queued stop then lands on top of the newer session, dropping the
        // mirror for a recording that is still running. See
        // `WatchSessionManager.phoneStopApplies`.
        sendToWatch(["cmd": "phoneStop", "session": localSessionToken])
        clearWatchBirdDisplay()
    }

    /// Whether a *phone-side* stop is about to end something this method owns.
    ///
    /// `isRecording` alone is not that question. It is true for a watch-sourced
    /// session too, and `stop()` only knows how to tear down the phone's own half
    /// — it clears `isRecording`, cancels the idle watchdog and tells the watch
    /// the phone stopped, while leaving `watchRecording`, the silent keepalive and
    /// the audio-liveness watchdogs running. The result is a session still
    /// ingesting watch audio behind a UI that says nothing is recording, whose
    /// record button then offers to save a birding walk. Ending a watch session
    /// from the phone goes through `stopWatchSession` instead.
    ///
    /// This is reachable, not theoretical. `"stopPhone"` — the one watch command
    /// routed straight to `stop()`, where `"start"` and `"stop"` go to guarded
    /// entry points — is sent by the watch on *both* channels at once, live and
    /// via `transferUserInfo`. The queued copy outlives app suspension, so it can
    /// be flushed after a later watch session has already begun on the live
    /// channel, at which point it arrives as a stop for a session that ended long
    /// ago. Extracted as a static so that pairing is pinned by a test.
    nonisolated static func localStopApplies(isRecording: Bool, watchRecording: Bool) -> Bool {
        isRecording && !watchRecording
    }

    func stop() {
        // Before anything is torn down: a watch-sourced session's engine, idle
        // watchdog and pending transition are not this method's to cancel.
        guard Self.localStopApplies(
            isRecording: isRecording, watchRecording: watchRecording
        ) else { return }

        pendingTransitionTask?.cancel()
        pendingTransitionTask = nil
        cancelIdleWatchdog()
        cancelPhoneHeartbeat()

        isRecording = false

        // Bank the session's length, then — since a stop that reaches here came
        // from the phone (the stop button, or the idle notification's End
        // Session action) — see whether the user has earned a review prompt.
        // Order matters: recording first lets the session that crosses the
        // threshold be the one that prompts.
        if let start = localSessionStart {
            ReviewPrompt.recordSession(duration: Date().timeIntervalSince(start))
            localSessionStart = nil
        }
        ReviewPrompt.requestIfDue()

        // Tell the watch to drop its mirrored "now hearing" display, and take the
        // bird out of the mirrored context so a later push can't resurrect it.
        // Named, like the `phoneStart` it undoes. `sendToWatch` picks whichever
        // channel fits *at this moment*, so a stop sent while the watch app is
        // unreachable is queued while a start moments later goes out live — and
        // the queued stop then lands on top of the newer session, dropping the
        // mirror for a recording that is still running. See
        // `WatchSessionManager.phoneStopApplies`.
        sendToWatch(["cmd": "phoneStop", "session": localSessionToken])
        clearWatchBirdDisplay()

        // If the engine never actually started (we cancelled a pending start
        // task before its 280ms sleep elapsed), there's nothing to tear down.
        guard pipeline.isRunning else { return }

        // engine.stop() + setActive(false) tax main internally during teardown.
        // Defer until after the SwiftUI morph animation has committed so the
        // button transition feels instant.
        let pipeline = self.pipeline
        pendingTransitionTask = Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(for: .milliseconds(280))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            pipeline.stop()
        }
    }

    // MARK: - Watch audio ingestion

    /// Names the watch-capture session currently running, as the watch names it.
    /// `nil` when no watch session is up, or when the watch is an older build
    /// that sends no token.
    ///
    /// Echoed back on every command aimed at that session — `remoteStop`,
    /// `restartCapture` — so the watch can refuse one meant for a session that
    /// has since ended, exactly as `mirrorStopApplies` does in the other
    /// direction.
    private var watchSessionToken: Int?

    /// The highest watch session token this launch has seen, kept *past* the end
    /// of the session that carried it.
    ///
    /// This is what lets a stale `start` be recognized. The watch announces a
    /// session on both channels at once and the queued copy outlives app
    /// suspension, so a `start` can be delivered after its session has ended —
    /// at which point `watchRecording` is false again and nothing in the old
    /// guard could tell it from a fresh one. The phone would bring a whole
    /// session up for a watch that had stopped: the silent keepalive draining
    /// the battery, the watchdogs armed, and no audio ever arriving, until the
    /// 90-second give-up threshold tore it down and told the user the watch had
    /// disconnected.
    ///
    /// The watch's token rises monotonically and is seeded from the wall clock
    /// (see `WatchSessionManager.watchSessionToken`), so "at or below the highest
    /// we have seen" is a sound test for "already announced".
    private var lastWatchSessionToken: Int?

    /// What a watch `start` means for a phone that may already be doing
    /// something.
    nonisolated enum WatchStartOutcome: Hashable {
        /// A phone-mic session owns the microphone, or this names a session that
        /// has already been announced — a duplicate from the second channel, or
        /// a queued copy flushed after the fact.
        case ignore
        /// Nothing running — bring the session up.
        case begin
        /// A watch session is already running and this names a *newer* one.
        /// Nothing to bring up, but the token has to move: the watch re-runs the
        /// whole start handshake when a user picks Resume off its save prompt
        /// (see `WatchSessionManager.resumeBirding`), and the stop that
        /// eventually follows carries the new token. Holding the old one would
        /// make `watchStopApplies` refuse the real stop.
        case adoptToken
    }

    /// Which of those a watch `start` is.
    ///
    /// The staleness test comes first, ahead of the "is anything running"
    /// questions, because a token we have already retired is not evidence about
    /// the present state at all — it describes a session that is over, and the
    /// only correct thing to do with it is nothing.
    ///
    /// An untokened `start` is an older watch build and always applies: refusing
    /// those would leave its record button dead, which is worse than the race
    /// they'd close.
    nonisolated static func watchStartOutcome(
        watchRecording: Bool,
        phoneRecording: Bool,
        lastSeenToken: Int?,
        incomingToken: Int?
    ) -> WatchStartOutcome {
        if let incomingToken, let lastSeenToken, incomingToken <= lastSeenToken {
            return .ignore
        }
        if watchRecording { return .adoptToken }
        // The phone's own microphone owns the session; the watch only ever
        // *mirrors* one of those (see `announceLocalSessionStart`).
        if phoneRecording { return .ignore }
        return .begin
    }

    /// Whether a `stop` relayed by the watch still describes the watch session
    /// running now.
    ///
    /// The mirror of `mirrorStopApplies`, for the other kind of session. The
    /// watch sends `stop` on both channels unconditionally, so a queued copy
    /// always exists — and a user who stops and immediately restarts on the
    /// wrist gets it delivered *after* the new session's live `start`. The phone
    /// then tore the new session down while the watch went on capturing into it,
    /// dropping every chunk on `ingestWatchSamples16k`'s `watchRecording` guard;
    /// the wrist showed a live recording that reached nothing until its own
    /// watchdog gave up 90 seconds later.
    ///
    /// A `nil` on either side means there is no token to disagree about — an
    /// older watch build, or a session the phone adopted without one — and the
    /// stop applies, preserving the previous behavior.
    nonisolated static func watchStopApplies(requestToken: Int?, currentToken: Int?) -> Bool {
        guard let requestToken, let currentToken else { return true }
        return requestToken == currentToken
    }

    /// Records the token of the watch session now running, and remembers it for
    /// the staleness test above. `lastWatchSessionToken` only ever climbs.
    private func adoptWatchSession(token: Int?) {
        watchSessionToken = token
        guard let token else { return }
        lastWatchSessionToken = max(lastWatchSessionToken ?? token, token)
    }

    /// Called when the watch sends a "start" handshake. Resets per-session
    /// state the same way `start()` does but skips the local AVAudioEngine —
    /// the watch is the audio source now.
    ///
    /// `session` names the watch's session so a stale or duplicate copy of this
    /// handshake can be told from a fresh one — see `watchStartOutcome`. `nil`
    /// is an older watch build, which sends none.
    func startFromWatch(session token: Int? = nil) async {
        switch Self.watchStartOutcome(
            watchRecording: watchRecording,
            phoneRecording: isRecording && !watchRecording,
            lastSeenToken: lastWatchSessionToken,
            incomingToken: token
        ) {
        case .ignore:
            return
        case .adoptToken:
            adoptWatchSession(token: token)
            return
        case .begin:
            break
        }
        adoptWatchSession(token: token)

        // A phone-mic transition may still be sitting in its post-animation
        // sleep. **Decided after the outcome above, deliberately**: this used to
        // run first, before any guard, so a `start` the phone was about to
        // ignore still cancelled whatever was pending. The costly half of that
        // was a pending *start* — `startLocally` defers the engine bring-up 280
        // ms so the record button can morph — which left `isRecording` true with
        // an engine that was never going to come up. The phone showed a live
        // session and heard nothing at all for the rest of the walk.
        pendingTransitionTask?.cancel()
        pendingTransitionTask = nil
        // A pending *stop* is the other thing it can be, and cancelling that on
        // its own is not free either: the deferred task is what actually stops
        // the engine, so dropping it left the phone's own microphone running
        // underneath the watch session, feeding a second stream of windows into
        // the same classifier. Do the teardown the cancelled task was going to
        // do. Off the main actor, because `engine.stop()` + `setActive(false)`
        // block their caller for a moment (the reason it was deferred at all).
        if pipeline.isRunning {
            let pipeline = self.pipeline
            Task.detached(priority: .userInitiated) { pipeline.stop() }
        }

        // A watch-driven session needs *neither* of the phone's permissions: the
        // watch captures with its own microphone and sends its own coordinate (via
        // the `watchLocation` handshake) for the nearby-species filter. So we never
        // refuse here. The filter starts from the last-known / offline list and is
        // refined the moment the watch's coordinate arrives (`updateWatchLocation`).
        watchSuppliedCoordinate = nil

        errorMessage = nil
        detections = []
        detectionMap = [:]
        flashIDs = []
        cooldowns.reset()
        lastWatchDisplaySci = nil
        lastWatchDisplayAt = nil
        watchWindowBuffer.removeAll(keepingCapacity: true)
        watchLastSample = 0
        spectrogram.reset()
        refreshLifeListFromStore()

        isRecording = true
        watchRecording = true
        watchSessionStart = Date()

        // Activate the silent-audio keepalive so iOS doesn't suspend us
        // if the user puts the phone away mid-session.
        watchKeepalive.start()

        lastWatchAudioAt = Date()
        startWatchLifecycleWatchdogs()

        preload()
        Task { await self.refreshSpeciesFilter() }
        startIdleWatchdog()
    }

    /// The watch sent its own coordinate for the current session. Cache it and
    /// rebuild the nearby-species filter from where the watch is — this is what
    /// lets a watch-first user (phone never opened, so the phone has no location
    /// of its own) still get a location-focused list. No-op unless a watch session
    /// is active.
    func updateWatchLocation(lat: Double, lon: Double) {
        // Inside the guard, not before it. `stopFromWatch` clears
        // `watchSuppliedCoordinate` precisely so a finished session's fix can't
        // go on standing for "here" — but this write escaped that, and both
        // channels carry `watchLocation`, so the queued copy can land after the
        // session ended. It would then stamp the phone's cache *fresh* with a
        // coordinate from a walk that is over, which is what the map picker
        // seeds its pin from.
        guard watchRecording else { return }
        LocationCache.shared.update(latitude: lat, longitude: lon)
        watchSuppliedCoordinate = (lat, lon)
        // `force`, because this call carries something the run in flight doesn't
        // have: the watch's own coordinate. Joining that run would quietly build
        // the filter from wherever the *phone* thinks it is — which for a
        // watch-first user is nowhere at all.
        Task { await self.refreshSpeciesFilter(force: true) }
    }

    /// Called when the watch sends a "stop" handshake.
    ///
    /// `session` names the watch session the stop is about, so a queued copy
    /// flushed after a *newer* watch session has begun can be recognized and
    /// dropped — see `watchStopApplies`. The phone's own teardown paths
    /// (`stopWatchSession` and the liveness watchdog) pass none, which applies
    /// unconditionally: they are ending the session they can see, not relaying a
    /// message about one.
    func stopFromWatch(session token: Int? = nil) {
        guard watchRecording else { return }
        guard Self.watchStopApplies(
            requestToken: token, currentToken: watchSessionToken
        ) else {
            Log.info("Ignoring a watch stop for a session that has already ended")
            return
        }
        watchSessionToken = nil
        watchRecording = false
        isRecording = false
        // A watch-sourced session counts toward the review threshold like any
        // other; only the prompt itself is phone-only, and that's raised by
        // `stopWatchSession` (the phone-side stop) rather than here — this path
        // also covers stops the watch or a watchdog initiated, where there's no
        // one looking at the phone.
        if let start = watchSessionStart {
            ReviewPrompt.recordSession(duration: Date().timeIntervalSince(start))
        }
        watchSessionStart = nil
        // The session is over however we got here — a watch-side stop, a
        // watchdog, a lost link. Any prompt still up is now asking about a walk
        // whose fate is no longer ours to decide, so take it down.
        showWatchWorkoutPrompt = false
        watchWindowBuffer.removeAll(keepingCapacity: true)
        watchLastSample = 0
        // The watch's fix belongs to the session that just ended, and nothing
        // else cleared it. `refreshSpeciesFilter` prefers it over the phone's own
        // location unconditionally, so leaving it set meant the phone stopped
        // asking where *it* was: every later foreground refresh and every
        // phone-only session rebuilt the nearby-species list from wherever the
        // watch last was, indefinitely. Worse, that stale fix was written into
        // `LocationCache` and stamped fresh, so a sighting added just after a
        // foreground could be pinned at it.
        watchSuppliedCoordinate = nil
        watchKeepalive.stop()
        cancelWatchLifecycleWatchdogs()
        cancelIdleWatchdog()
        // The wrist is no longer showing this session's bird, and the phone
        // must not re-push it onto a watch that has since relaunched.
        clearWatchBirdDisplay()
    }

    // MARK: - Idle auto-termination

    private func startIdleWatchdog() {
        idleTerminationTask?.cancel()
        lastDetectionAt = Date()
        idlePromptSent = false
        idleTerminationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                let stillRunning = self.checkIdleAndMaybePrompt()
                if !stillRunning { return }
            }
        }
    }

    private func cancelIdleWatchdog() {
        idleTerminationTask?.cancel()
        idleTerminationTask = nil
        lastDetectionAt = nil
        idlePromptSent = false
    }

    /// Called by the poll loop. Returns whether the session is still running (so
    /// the loop keeps polling). When the no-detection stretch passes the user's
    /// timeout, it sends the idle-timeout *prompt* — a rich notification with an
    /// "End Session" action — rather than stopping the session itself. The prompt
    /// fires once per silent stretch (guarded by `idlePromptSent`, cleared by the
    /// next detection in `merge`), so the user isn't re-nagged every minute.
    private func checkIdleAndMaybePrompt() -> Bool {
        guard isRecording, let last = lastDetectionAt else { return false }
        // Read the timeout live so a mid-session change takes effect. `.never`
        // yields a nil threshold — keep listening and let the poll loop continue.
        let timeout = AppSettings.shared.noBirdTimeout
        guard let threshold = timeout.seconds else { return true }
        let gap = Date().timeIntervalSince(last)
        guard gap >= threshold, !idlePromptSent else { return true }

        idlePromptSent = true
        let minutes = timeout.rawValue
        Task {
            await SpeciesNotifications.shared.notifyIdleTimeoutPrompt(minutes: minutes)
        }
        return true
    }

    /// Ends whichever session is currently active — the phone's own mic session
    /// or a watch-sourced one. Invoked by the idle-timeout notification's "End
    /// Session" action (wired in `KestrelApp`). A no-op if nothing is recording.
    func endActiveSession() {
        if watchRecording {
            // Triggered from a notification action, not the stop button, so
            // there's no answer to relay — the user never saw the phone's
            // prompt. `.ask` leaves the walk parked for the watch to ask about.
            stopWatchSession(workout: .ask)
        } else if isRecording {
            stop()
        }
    }

    private func startWatchLifecycleWatchdogs() {
        watchStallNudged = false
        lastWatchAudioAt = Date()

        // Audio-liveness watchdog: verifies chunks are actually arriving.
        watchHeartbeatTask?.cancel()
        watchHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchWatchdogInterval))
                guard !Task.isCancelled, let self else { return }
                let stillAlive = self.checkWatchAudioLiveness()
                if !stillAlive { return }
            }
        }

        startPhoneHeartbeat()
    }

    /// Starts the phone-side heartbeat sender. Called by both session kinds —
    /// `startWatchLifecycleWatchdogs` for a watch-sourced session and
    /// `announceLocalSessionStart` for a mirrored phone-mic one.
    private func startPhoneHeartbeat() {
        phoneHeartbeatTask?.cancel()
        phoneHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sendPhoneHeartbeat()
                try? await Task.sleep(for: .seconds(Self.watchWatchdogInterval))
            }
        }
    }

    private func cancelPhoneHeartbeat() {
        phoneHeartbeatTask?.cancel()
        phoneHeartbeatTask = nil
    }

    private func cancelWatchLifecycleWatchdogs() {
        watchHeartbeatTask?.cancel()
        watchHeartbeatTask = nil
        cancelPhoneHeartbeat()
        lastWatchAudioAt = nil
        watchStallNudged = false
    }

    /// Beat sent only while the phone believes a watch session is live. Live
    /// `sendMessage` when reachable; a background-tolerant `transferUserInfo`
    /// otherwise so the watch still sees it (queued) when both apps are
    /// backgrounded — the case where audio tends to stall.
    private func sendPhoneHeartbeat() {
        guard Self.shouldSendPhoneHeartbeat(isRecording: isRecording) else { return }
        sendToWatch(["cmd": "phoneHeartbeat"])
    }

    /// Whether the phone owes the watch a beat right now.
    ///
    /// **Either kind of live session, not just a watch-sourced one.** The watch
    /// shows a recording screen for both — its own capture, and the mirror of a
    /// phone-mic session — and runs the same watchdog over both. Beating only
    /// while `watchRecording` left the mirror with no liveness signal at all,
    /// and `phoneStop` (the one thing that clears it) is something only a living
    /// app sends: kill the phone app mid-session and the wrist sat on
    /// "Listening on iPhone…" until the user happened to tap Stop.
    ///
    /// So the rule is `isRecording` alone, and pointedly *not* `watchRecording`
    /// — the distinction every other watch-facing guard in this file draws is
    /// the one this must not. Extracted as a static, thin as it is, so that
    /// tightening it back is a change a test objects to rather than one that
    /// silently reopens the hole. See `localStopApplies`, which is its opposite
    /// number and does need both flags.
    nonisolated static func shouldSendPhoneHeartbeat(isRecording: Bool) -> Bool {
        isRecording
    }

    /// Replies to the watch's "are you still there?" probe with an out-of-band
    /// heartbeat. The watch sends this once its heartbeat gap crosses the
    /// give-up threshold, so answering promptly is what saves a long session
    /// from being torn down after a stretch where both apps were backgrounded
    /// and the scheduled beats never landed.
    func answerWatchPing() {
        sendPhoneHeartbeat()
    }

    /// Asks the watch to tear down and restart its capture session — the remedy
    /// for a stall noticed on the phone side (no audio arriving). Logged, with no
    /// UI side effects, per spec.
    private func requestWatchCaptureRestart() {
        sendToWatchOnBothChannels(watchSessionPayload(["cmd": "restartCapture"]))
    }

    /// Returns false once it tears the session down so the caller can exit its
    /// polling loop. Returns true while the session should keep running (healthy,
    /// or stalled-but-recovering).
    private func checkWatchAudioLiveness() -> Bool {
        guard watchRecording, let last = lastWatchAudioAt else { return false }
        let gap = Date().timeIntervalSince(last)

        // A generous ceiling: audio absent this long means the watch is effectively
        // gone (app killed, out of range, dead battery). Restart requests won't
        // reach it, so stop cleanly so the keepalive isn't left draining the phone,
        // and notify.
        if gap >= watchGiveUpThreshold {
            Log.warning("No watch audio for \(Int(gap))s — giving up on watch session")
            sendToWatchOnBothChannels(watchSessionPayload(["cmd": "remoteStop"]))
            Task {
                await SpeciesNotifications.shared.notifySessionLifecycle(
                    title: "Kestrel",
                    body: "Watch disconnected. Re-tap the watch button to keep listening."
                )
            }
            stopFromWatch()
            return false
        }

        // A shorter stall: nudge the watch to restart its capture, but only once
        // per silent stretch (not every poll) so we don't churn its engine. The
        // flag clears the moment audio resumes.
        if gap >= watchAudioStallThreshold, !watchStallNudged {
            watchStallNudged = true
            Log.warning("Watch audio stalled \(Int(gap))s — requesting one capture restart")
            requestWatchCaptureRestart()
        }
        return true
    }

    /// Ingest a chunk of 16 kHz mono Float samples from the watch.
    /// Linear-interpolation 3× upsample to 48 kHz, feed the spectrogram,
    /// then slice into BirdNET windows and dispatch inference.
    func ingestWatchSamples16k(_ samples16k: [Float]) {
        guard watchRecording, !samples16k.isEmpty else { return }
        lastWatchAudioAt = Date()
        // Audio is flowing again — re-arm the one-shot stall nudge for the next
        // silent stretch.
        watchStallNudged = false

        // 3× linear upsample: between each input sample we emit two
        // interpolated samples. Carries `watchLastSample` across chunks so
        // we don't introduce a discontinuity at chunk boundaries.
        var upsampled = [Float]()
        upsampled.reserveCapacity(samples16k.count * 3)
        var prev = watchLastSample
        for s in samples16k {
            upsampled.append(prev)
            upsampled.append(prev + (s - prev) * (1.0 / 3.0))
            upsampled.append(prev + (s - prev) * (2.0 / 3.0))
            prev = s
        }
        watchLastSample = prev

        spectrogram.ingest(upsampled)

        watchWindowBuffer.append(contentsOf: upsampled)
        while watchWindowBuffer.count >= AudioPipeline.windowSamples {
            let window = Array(watchWindowBuffer.prefix(AudioPipeline.windowSamples))
            watchWindowBuffer.removeFirst(AudioPipeline.hopSamples)
            Task { await self.process(window: window) }
        }
    }

    // MARK: - Model accessors

    private func getClassifier() async -> BirdNETClassifier? {
        if classifierTask == nil { preload() }
        do {
            return try await classifierTask?.value
        } catch {
            errorMessage = "Failed to load BirdNET: \(error.localizedDescription)"
            Log.error("Classifier load — \(error)")
            return nil
        }
    }

    private func getRangeFilter() async -> SpeciesRangeFilter? {
        if rangeFilterTask == nil { preload() }
        do {
            return try await rangeFilterTask?.value
        } catch {
            Log.error("Range filter unavailable — \(error)")
            return nil
        }
    }

    // MARK: - Per-window inference

    private func process(window: [Float]) async {
        guard let classifier = await getClassifier() else { return }
        do {
            let results = try await classifier.classify(window, allowedIndices: allowedIndices)
            if !results.isEmpty {
                // Tint priority within a single window: starred > needs-add
                // > known lifer. Picks the most attention-grabbing color
                // when multiple species overlap on the same band.
                let kind: SpectrogramRenderer.TintKind
                if results.contains(where: { starredNames.contains($0.scientificName) }) {
                    kind = .starred
                } else if results.contains(where: { !lifeListSnapshot.contains($0.scientificName) }) {
                    kind = .needsAdd
                } else {
                    kind = .lifer
                }
                spectrogram.markDetection(kind: kind)
            }
            await MainActor.run { self.merge(results) }
        } catch {
            Log.error("Inference error — \(error)")
        }
    }

    /// Captures the set of life-list scientific names at the moment a new
    /// recording session starts. The UI calls this on the false → true
    /// transition of `isRecording`.
    func snapshotLifeList(_ scientificNames: Set<String>) {
        lifeListSnapshot = scientificNames
    }

    /// Freezes `lifeListSnapshot` from the store. Called at the top of every
    /// start path (local and watch-driven) so the "is this species already a
    /// lifer?" check is correct regardless of whether a SwiftUI view happens to
    /// be mounted and observing — without this, a watch-initiated background
    /// session started a stale (often empty) snapshot and notified for every bird
    /// heard.
    ///
    /// Stars need no equivalent: `starredNames` reads the store on every access.
    private func refreshLifeListFromStore() {
        guard let store = lifeListStore else { return }
        lifeListSnapshot = Set(store.entries.map(\.scientificName))
    }

    /// Whether a heard species is worth alerting about, and as what — or `nil`
    /// for one that should pass without a notification or an alert haptic.
    ///
    /// Two life-list sets go in, and the difference between them is the whole
    /// point. `snapshotAtSessionStart` is frozen when recording begins and drives
    /// the *display* — the row's purple treatment, the spectrogram band — which
    /// must not vanish the instant the user taps add, or the list would rearrange
    /// itself under their thumb. Alerting is a different question: the moment a
    /// bird is actually recorded the user has acknowledged it, and there is
    /// nothing left to tell them about it.
    ///
    /// Reading only the frozen snapshot for both is what made a bird the user had
    /// just filed go on buzzing every `DetectionCooldowns.haptic` and
    /// re-notifying every `DetectionCooldowns.notify` for the rest of the walk.
    /// A starred bird still alerts either way — a star is a standing "tell me
    /// again", not a gap in the user's records.
    nonisolated static func alertReason(
        scientificName: String,
        starred: Set<String>,
        snapshotAtSessionStart: Set<String>,
        recordedNow: Set<String>
    ) -> SpeciesNotifications.Reason? {
        if starred.contains(scientificName) { return .starred }
        let wasNewAtSessionStart = !snapshotAtSessionStart.contains(scientificName)
        let stillUnrecorded = !recordedNow.contains(scientificName)
        return wasNewAtSessionStart && stillUnrecorded ? .newSpecies : nil
    }

    private func merge(_ results: [Detection]) {
        // Flash any repeat match (regardless of confidence change), but
        // enforce a per-species cooldown so the same row doesn't strobe on
        // every overlapping inference window.
        let now = Date()
        if !results.isEmpty {
            lastDetectionAt = now
            // A bird was heard — re-arm the idle-timeout prompt so a later silent
            // stretch asks again.
            idlePromptSent = false
        }
        var repeatedIDs: [String] = []
        // Detections that should fire a notification this batch: species heard
        // with no detection in the last `DetectionCooldowns.notify` seconds.
        var notifications: [(common: String, scientific: String, reason: SpeciesNotifications.Reason)] = []
        // Detections that should buzz this batch — gated by the much shorter
        // `DetectionCooldowns.haptic`, so a repeated new/starred bird keeps
        // tapping even while its notification is still on cooldown.
        var haptics: [SpeciesNotifications.Reason] = []
        // When the "Haptic for All Birds" setting is on, a single soft haptic
        // also fires for any *known, non-starred* bird heard this batch — the
        // everyday birds that otherwise buzz nothing. Read once; collapsed to one
        // tap per batch so several ordinary species in the same window don't
        // stack buzzes.
        let hapticForAllBirds = AppSettings.shared.hapticForAllBirds
        var playSoftHaptic = false
        // The species on the life list *now*, as opposed to `lifeListSnapshot`,
        // which is frozen at session start — the difference is what stops a bird
        // the user has just filed from going on alerting (see `alertReason`).
        // Read once: it can't change inside this loop, which runs entirely on the
        // main actor with no suspension point in it.
        let recorded = lifeListStore?.speciesNames ?? lifeListSnapshot
        for d in results {
            if let existing = detectionMap[d.id] {
                if d.confidence > existing.confidence {
                    detectionMap[d.id] = d  // takes new confidence + new lastSeen
                } else {
                    var updated = existing
                    updated.lastSeen = d.lastSeen
                    detectionMap[d.id] = updated
                }
                if cooldowns.shouldFlash(d.id, at: now) {
                    repeatedIDs.append(d.id)
                }
            } else {
                detectionMap[d.id] = d
            }

            // Notify when (a) the species is worth alerting about — see
            // `alertReason`, which is where "starred, or heard before you'd
            // recorded it and still unrecorded" is decided — and (b) it hasn't
            // been heard for at least `DetectionCooldowns.notify` seconds. The
            // clock resets on every detection (`markHeard`, below), so a
            // continuously-singing bird only triggers once; a bird that goes
            // silent and returns re-fires.
            if let reason = Self.alertReason(
                scientificName: d.scientificName,
                starred: starredNames,
                snapshotAtSessionStart: lifeListSnapshot,
                recordedNow: recorded
            ) {
                if cooldowns.shouldNotify(d.scientificName, at: now) {
                    notifications.append((d.commonName, d.scientificName, reason))
                }
                // Haptic on its own, shorter clock so repeats still buzz while
                // the notification stays muted for the rest of its window.
                if cooldowns.shouldBuzz(d.scientificName, at: now) {
                    haptics.append(reason)
                }
            } else if hapticForAllBirds {
                // A known, non-starred bird — a single subtle haptic when the
                // setting is on, on the same short per-species cooldown so a
                // continuously-singing bird doesn't buzz every window. Reached
                // by anything the branch above passed over, which now includes a
                // bird added mid-session: it *is* a known bird from the moment
                // it's recorded, and the soft haptic is what known birds get.
                if cooldowns.shouldBuzz(d.scientificName, at: now) {
                    playSoftHaptic = true
                }
            }
            // Stamped for every detection, alerted-on or not — that is what
            // makes a continuously-singing bird push its next banner out rather
            // than earn one every `DetectionCooldowns.notify` seconds.
            cooldowns.markHeard(d.scientificName, at: now)
        }

        // Only surface to the user when the Identify spectrogram isn't on
        // screen — otherwise the visible rows already convey it.
        if !spectrogramVisible {
            for item in notifications {
                Task {
                    await SpeciesNotifications.shared.notifyNewSpecies(
                        commonName: item.common,
                        scientificName: item.scientific,
                        reason: item.reason
                    )
                }
            }
        }
        // Haptics fire for new/starred birds — including repeats, on the short
        // `DetectionCooldowns.haptic` — since a tap signals something worth looking up,
        // regardless of which microphone is the audio source. When the phone's
        // app is foregrounded the phone buzzes itself (the device in hand);
        // otherwise the wrist gets it.
        for reason in haptics {
            if appForegrounded {
                playLocalHaptic(reason: reason)
            } else {
                sendHapticToWatch(reason: reason)
            }
        }
        // The opt-in soft haptic for an ordinary (known, non-starred) bird uses
        // the same destination as the alerts above: the phone when its app is in
        // hand, otherwise the wrist.
        if playSoftHaptic {
            if appForegrounded {
                playSoftLocalHaptic()
            } else {
                sendSoftHapticToWatch()
            }
        }

        // The watch's "now hearing" screen always shows the *last* species
        // heard, interesting or not. Push the most-confident detection of this
        // window when it differs from what the watch is already showing — but
        // also re-push the same species once it's been unsent for
        // `watchDisplayRefreshInterval`, so a continuously-singing bird keeps the
        // watch's idle-reset timer armed instead of silently dropping to the
        // placeholder while the phone still shows a fresh observation.
        if let top = results.max(by: { $0.confidence < $1.confidence }) {
            let speciesChanged = top.scientificName != lastWatchDisplaySci
            let staleRefresh = lastWatchDisplayAt.map {
                now.timeIntervalSince($0) >= watchDisplayRefreshInterval
            } ?? true
            if speciesChanged || staleRefresh {
                sendWatchDisplay(for: top)
            }
        }

        for id in repeatedIDs {
            flashIDs.insert(id)
        }

        // Sort by lastSeen so the most recently heard species is always at
        // the top. Reorder is animated so rows visibly slide into place.
        //
        // Filming this on the *simulator* shows the list's top going blank for
        // the length of the animation, on every merge. It does not reproduce on
        // device, so it's a simulator rendering artifact — don't "fix" it by
        // dropping the animation, which only trades a real behavior for a fake
        // bug.
        withAnimation(.easeInOut(duration: 0.3)) {
            detections = detectionMap.values.sorted { $0.lastSeen > $1.lastSeen }
        }

        for id in repeatedIDs {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                await MainActor.run { _ = self?.flashIDs.remove(id) }
            }
        }
    }

    /// Pushes a freshly-heard species to the watch's "now hearing" screen and
    /// records the send so the refresh throttle above can re-push an unchanged
    /// species before the watch's idle-reset timer would drop it.
    private func sendWatchDisplay(for top: Detection) {
        lastWatchDisplaySci = top.scientificName
        lastWatchDisplayAt = Date()
        let highlight: String
        if starredNames.contains(top.scientificName) {
            highlight = "starred"
        } else if !lifeListSnapshot.contains(top.scientificName) {
            highlight = "newSpecies"
        } else {
            highlight = "normal"
        }
        sendBirdDisplayToWatch(
            commonName: top.commonName,
            scientificName: top.scientificName,
            highlight: highlight
        )
    }

    // MARK: - Location + species filter

    /// Whether recording may proceed: the nearby-species filter requires location
    /// access, so we refuse to record without it. When `prompt` is set (the phone
    /// user is interacting), an undetermined status prompts once and awaits the
    /// choice; otherwise (the watch path — the phone owns location, not the watch)
    /// the current status is read without surfacing a system dialog. Returns
    /// whether access was granted.
    private func isLocationAuthorized(prompt: Bool) async -> Bool {
        let status = prompt
            ? await locationProvider.requestAuthorization()
            : locationProvider.authorizationStatus
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        default:
            return false
        }
    }

    /// Recomputes the nearby-species filter (and prefetches that region's photos)
    /// when the app foregrounds, so opening it in a new area picks up the new
    /// region right away rather than waiting for the next recording session.
    ///
    /// This is the closest approximation to "prefetch as you travel" available
    /// without Always-location: the app can only get a fresh fix while in the
    /// foreground. Deliberately conservative — it never prompts (only runs if
    /// location is *already* authorized) and never fights an active session,
    /// which owns the filter and uses the watch-supplied coordinate.
    func refreshRegionOnForeground() {
        guard !isRecording, !watchRecording else { return }
        switch locationProvider.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            Task { await self.refreshSpeciesFilter() }
        default:
            break
        }
    }

    /// Which coordinate the nearby-species filter should be built from: the
    /// watch's, but **only while a watch session is actually running**.
    ///
    /// The `watchRecording` half is what makes this a rule rather than a
    /// coincidence of when the field happens to be nil. `refreshSpeciesFilter`
    /// runs on every foreground and at the start of every phone-only session,
    /// long after any watch session has ended, and a watch coordinate consulted
    /// then is a fix from another walk — possibly another day, possibly another
    /// state. It also gets written into `LocationCache` and stamped fresh, so it
    /// stops being merely a stale filter and starts being the default pin under
    /// a new sighting.
    nonisolated static func sessionCoordinate(
        watchSupplied: (lat: Double, lon: Double)?,
        watchRecording: Bool
    ) -> (lat: Double, lon: Double)? {
        guard watchRecording else { return nil }
        return watchSupplied
    }

    /// Serializes the species-filter refresh — see `refreshSpeciesFilter(force:)`.
    @ObservationIgnored private lazy var speciesFilterJob = CoalescedJob { [weak self] in
        await self?.performSpeciesFilterRefresh()
    }

    /// Recomputes the nearby-species filter, coalescing concurrent requests.
    ///
    /// **This has to coalesce, because the app asks for it from four places and
    /// the answer is one shared value.** A session start asks, `preload()` asks
    /// for the launch warm-up, an app foreground asks, and the watch asks when
    /// its coordinate lands — and the first two fire together on the first
    /// session after location is granted. Run in parallel they each resolve a
    /// location, each build a list, and each assign `allowedIndices`, so the
    /// filter the session ran under was whichever finished last rather than
    /// whichever knew the most.
    ///
    /// The losing runs are the ones that come back *without* a location, which
    /// is what made this more than wasted work: `LocationProvider` answered a
    /// second concurrent caller `nil` outright (it now joins the fix instead),
    /// and a run told there is no fix falls all the way through to
    /// `allowedIndices = nil` — which hands BirdNET all 6,522 labels at the
    /// in-range threshold for the rest of the walk.
    ///
    /// `force` is for a caller whose inputs differ from the run in flight —
    /// today only `updateWatchLocation`, which arrives holding a coordinate that
    /// run was started without.
    private func refreshSpeciesFilter(force: Bool = false) async {
        await speciesFilterJob.request(force: force)
    }

    private func performSpeciesFilterRefresh() async {
        guard let rangeFilter = await getRangeFilter() else {
            allowedIndices = nil
            return
        }
        // Prefer a coordinate the watch supplied for this session — it's the only
        // location a watch-first user has — falling back to the phone's own fix.
        let location: CLLocation?
        if let coord = Self.sessionCoordinate(
            watchSupplied: watchSuppliedCoordinate,
            watchRecording: watchRecording
        ) {
            location = CLLocation(latitude: coord.lat, longitude: coord.lon)
        } else {
            location = await locationProvider.currentLocation()
        }
        let week = SpeciesRangeFilter.birdnetWeek()
        if let location {
            LocationCache.shared.update(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            do {
                let allowed = try await rangeFilter.computeAndCache(
                    lat: location.coordinate.latitude,
                    lon: location.coordinate.longitude,
                    week: week
                )
                allowedIndices = allowed
                prefetchRegionImages(allowed)
                return
            } catch {
                Log.error("Geo inference failed — \(error)")
            }
        }
        if let cached = await rangeFilter.loadCached(week: week) {
            allowedIndices = cached
            prefetchRegionImages(cached)
            return
        }
        // Offline fallback: the precomputed grid (birds by location + week),
        // bundled from `build_offline_species_filter.py` (outside this repo —
        // see `OfflineSpeciesFilter`). Inert unless that data file ships in the
        // bundle. Needs only a coordinate — the live
        // model couldn't run, but we can still snap to the nearest grid sample —
        // so use a fresh fix if we just got one, else the last-known location.
        let lat = location?.coordinate.latitude ?? LocationCache.shared.lastLatitude
        let lon = location?.coordinate.longitude ?? LocationCache.shared.lastLongitude
        if let lat, let lon,
           let offline = OfflineSpeciesFilter.shared.allowedIndices(lat: lat, lon: lon, week: week) {
            allowedIndices = offline
            prefetchRegionImages(offline)
        } else {
            allowedIndices = nil
        }
    }

    /// Kicks off a background download of the embed photos for the just-computed
    /// region species so they're cached and available offline. Thumbnails for
    /// nearby species land first, then the rest of the life list, then the
    /// medium images (see `prefetchWake`).
    private func prefetchRegionImages(_ allowed: Set<Int>) {
        let all = SpeciesCatalog.shared.all
        let names = allowed.compactMap { all.indices.contains($0) ? all[$0].scientificName : nil }
        // The region just changed — refresh the set the image-cache cap
        // protects from eviction (life list + nearby) before prefetching.
        let lifeNames = lifeListStore?.entries.map(\.scientificName) ?? []
        RemoteSpeciesImageStore.shared.setProtectedSpecies(lifeNames + names)
        RemoteSpeciesImageStore.shared.prefetchWake(lifeList: lifeNames, nearby: names)
    }

    // MARK: - System plumbing

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            // The prompt just resolved — refresh the grayed-button flag in case
            // the user denied it.
            refreshMicrophoneAuthorization()
            return granted
        @unknown default:
            return false
        }
    }

    private func registerInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // The notification is delivered on the main queue; decode the
            // interruption type here and hop to the actor with a Sendable enum
            // rather than capturing the non-Sendable `Notification` itself.
            guard
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            Task { @MainActor [weak self] in
                self?.handleInterruption(type, options: options)
            }
        }
    }

    private func handleInterruption(
        _ type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions
    ) {
        switch type {
        case .began:
            // The system has paused our audio engine (a call, alarm, Siri, another
            // app taking audio, a video recording). We deliberately do NOT stop the
            // session — when the interruption ends we resume automatically below.
            // `isRecording` stays true so the UI keeps showing the session, and the
            // watch keepalive stays "active" so `.ended` re-arms it.
            break
        case .ended:
            // Resume only when the system says the interruption ended cleanly and
            // the interrupted audio should resume. A user who deliberately started
            // another audio app gets no `.shouldResume`, so we leave things be.
            guard options.contains(.shouldResume) else { return }
            if watchRecording {
                // Watch is the audio source; the phone only runs the silent
                // keepalive — re-arm it so the app stays alive + reachable for the
                // watch stream.
                watchKeepalive.resumeAfterInterruption()
            } else if isRecording {
                pipeline.resumeAfterInterruption()
            }
        @unknown default:
            break
        }
    }
}
