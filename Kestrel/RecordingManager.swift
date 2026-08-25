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
    private(set) var locationStatus: String?
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
    private static let minimumWorkoutDuration: TimeInterval = 15
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
    /// state) on both phone and watch while this holds.
    var recordingBlocked: Bool { locationAccessDenied || micAccessDenied }
    /// Whether both permissions recording needs are actually granted. Pushed to
    /// the watch (which can't prompt for either) so it knows when its own record
    /// button is usable. `notDetermined`/`undetermined` counts as not-yet-granted,
    /// since the phone must grant first.
    var recordingAuthorized: Bool {
        locationAuthorized && AVAudioApplication.shared.recordPermission == .granted
    }
    /// Tri-state recording authorization pushed to the watch. The watch can't
    /// prompt for the phone's permissions, so it needs to tell a genuine *denial*
    /// (a gray lock — the user must fix it in the phone's Settings) apart from
    /// permissions that simply haven't been requested yet (they're deferred to the
    /// first Start Recording). In the undetermined case the watch keeps a normal
    /// record button rather than a confusing lock — tapping it lets the phone
    /// prompt (if it's in hand) or falls back to the "open Kestrel on iPhone"
    /// message. Raw values are the strings sent over the WCSession context.
    enum WatchAuthState: String {
        case authorized
        case denied
        case undetermined
    }
    /// Resolves the tri-state for the watch from the phone's current permissions:
    /// a *denied* permission (mic or location) wins, then fully-granted, else
    /// undetermined (nothing denied but not yet granted).
    var recordingAuthorizationStateForWatch: WatchAuthState {
        if recordingBlocked { return .denied }
        if recordingAuthorized { return .authorized }
        return .undetermined
    }
    /// Invoked whenever the phone's recording authorization (mic or location)
    /// changes, so the app can push the new state to the watch (set in `KestrelApp`).
    var onRecordingAuthorizationChanged: (() -> Void)?
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
    /// Live set of scientific names the user has starred. The Identify UI
    /// pushes this in via `updateStarred(_:)` whenever the life list changes,
    /// so notifications/highlighting react to mid-session star toggles instead
    /// of being frozen to a snapshot.
    private(set) var starredNames: Set<String> = []

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
    /// Per-species timestamp of the last visual flash; used to enforce a
    /// 5-second cooldown so a species doesn't strobe on every overlapping
    /// 1.5 s window of inference.
    private var lastFlashAt: [String: Date] = [:]
    /// Last time each species fired a *notification*. A species becomes
    /// eligible for a fresh notification once it's been silent for the cooldown
    /// window (30 s), letting a bird that comes back later re-fire instead
    /// of staying muted for the rest of the session.
    private var lastHeardAt: [String: Date] = [:]
    /// Per-species timestamp of the last *haptic*. Haptics use a much shorter
    /// cooldown than notifications so a still-singing new/starred bird keeps
    /// buzzing on repeat detections instead of going quiet for the rest of the
    /// notification window.
    private var lastHapticAt: [String: Date] = [:]
    private let hapticCooldown: TimeInterval = 5
    private let notifyCooldown: TimeInterval = 30
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
    /// *replaces* the whole dictionary each call, so every key (the now-hearing
    /// bird, plus the recording-auth state) is merged through this single owner
    /// rather than clobbering one another. Unlike a live `sendMessage`, the
    /// application context is delivered even from a backgrounded phone — the case
    /// where a watch-first session runs with the phone in a pocket.
    private var watchAppContext: [String: Any] = [:]
    /// Monotonic tag on each now-hearing push. `updateApplicationContext` de-dupes
    /// identical dictionaries, so without this a re-push of the *same* still-singing
    /// species (which keeps the watch's 60 s idle-reset armed) would be dropped and
    /// the bird would silently fall back to the placeholder. Bumped per push so
    /// every one is a distinct context that actually delivers; the watch de-dupes
    /// on it so a context re-delivered for an unrelated key change doesn't re-flash.
    private var watchDisplaySeq = 0
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
    /// phone's location. Reset at the start of each watch session.
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
    /// the watch, which runs its own watchdog on it. Only ticks while
    /// `watchRecording` is true — so the watch can distinguish "phone still here"
    /// from "phone gone / session ended."
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
    private let watchWatchdogInterval: TimeInterval = 5
    /// If no watch audio arrives for this long the watch is effectively gone (app
    /// killed, out of range, dead battery); we stop so the keepalive isn't left
    /// draining the phone, and notify.
    private let watchGiveUpThreshold: TimeInterval = 90
    /// True once we've asked the watch to restart capture for the *current* silent
    /// stretch, so we nudge only once per stall rather than every poll. Cleared as
    /// soon as audio resumes (`ingestWatchSamples16k`).
    private var watchStallNudged = false

    /// Watchdog that auto-stops the recording once the session goes long enough
    /// without any detection. The threshold is the user's "Timeout After No
    /// Birds" setting (`AppSettings.noBirdTimeout`, 30 min by default; `.never`
    /// disables the auto-stop). Reset each time `merge(_:)` sees at least one
    /// result; armed in `startLocally`/`startFromWatch`; cancelled in `stop`/
    /// `stopFromWatch`.
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
    /// record button reads, and lets the app push the new state to the watch.
    private func handleLocationAuthorizationChange(_ status: CLAuthorizationStatus) {
        locationAccessDenied = (status == .denied || status == .restricted)
        onRecordingAuthorizationChanged?()
    }

    /// Re-reads the microphone permission and refreshes `micAccessDenied`. There's
    /// no system callback for mic-permission changes (unlike location), so the app
    /// calls this whenever it returns to the foreground — the user may have flipped
    /// the toggle in Settings while away. Pushes the new state to the watch when it
    /// actually changed.
    func refreshMicrophoneAuthorization() {
        let denied = AVAudioApplication.shared.recordPermission == .denied
        guard denied != micAccessDenied else { return }
        micAccessDenied = denied
        onRecordingAuthorizationChanged?()
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

        // Kick off the location/range-filter lookup at launch so the
        // "Filtered to N species" caption is ready to fade in before the
        // user taps Start Recording, instead of appearing mid-session and
        // shoving the record button down. Only when location is *already*
        // authorized — a fresh install must not surface the location prompt at
        // launch; that's deferred to the first Start Recording tap.
        if locationStatus == nil, locationAuthorized {
            Task { await self.refreshSpeciesFilter() }
        }
    }

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
    /// the now-hearing bird and the auth state coexist instead of overwriting.
    func mergeWatchAppContext(_ updates: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        watchAppContext.merge(updates) { _, new in new }
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

    /// Shared watch delivery. Live `sendMessage` is the fast path when the watch
    /// app is reachable; `transferUserInfo` is the background-tolerant fallback
    /// — used both when unreachable and as the recovery path for a `sendMessage`
    /// that races the app backgrounding (it queues and can wake a suspended app).
    private func sendToWatch(_ payload: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated,
              s.isPaired,
              s.isWatchAppInstalled else { return }
        if s.isReachable {
            s.sendMessage(payload, replyHandler: nil, errorHandler: { _ in
                WCSession.default.transferUserInfo(payload)
            })
        } else {
            s.transferUserInfo(payload)
        }
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
    /// worth deciding about.
    private var watchWalkIsSaveable: Bool {
        guard watchRecording, let start = watchSessionStart else { return false }
        return Date().timeIntervalSince(start) >= Self.minimumWorkoutDuration
    }

    /// The user answered the phone's prompt. Relays the decision to the watch
    /// with the stop, so the walk is saved or dropped without a second prompt
    /// appearing on the wrist.
    func resolveWatchWorkout(_ decision: WatchWorkoutDecision) {
        showWatchWorkoutPrompt = false
        stopWatchSession(workout: decision)
    }

    private func stopWatchSession(workout: WatchWorkoutDecision) {
        let s = WCSession.default
        let payload: [String: Any] = ["cmd": "remoteStop", "workout": workout.rawValue]
        s.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        s.transferUserInfo(payload)
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
        lastFlashAt = [:]
        lastHapticAt = [:]
        lastWatchDisplaySci = nil
        lastWatchDisplayAt = nil
        spectrogram.reset()
        refreshLifeListFromStore()
        // Don't clear locationStatus — leave the previous filter visible until
        // refreshSpeciesFilter overwrites it, otherwise the text flickers.
        isRecording = true
        localSessionStart = Date()

        // Mirror this phone-mic session onto the watch so its "now hearing"
        // screen shows the same birds, as though the watch were the source.
        sendToWatch(["cmd": "phoneStart"])

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
                    self?.errorMessage = message
                    self?.isRecording = false
                }
                Log.error("Failed to start pipeline — \(error)")
            }
        }

        preload()
        Task { await self.refreshSpeciesFilter() }
        startIdleWatchdog()
    }

    func stop() {
        pendingTransitionTask?.cancel()
        pendingTransitionTask = nil
        cancelIdleWatchdog()

        guard isRecording else { return }
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

        // Tell the watch to drop its mirrored "now hearing" display.
        sendToWatch(["cmd": "phoneStop"])

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

    /// Called when the watch sends a "start" handshake. Resets per-session
    /// state the same way `start()` does but skips the local AVAudioEngine —
    /// the watch is the audio source now.
    func startFromWatch() async {
        pendingTransitionTask?.cancel()
        pendingTransitionTask = nil

        // If a phone-driven recording is already running, don't clobber it.
        if isRecording && !watchRecording { return }
        guard !watchRecording else { return }

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
        lastFlashAt = [:]
        lastHapticAt = [:]
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
        LocationCache.shared.update(latitude: lat, longitude: lon)
        guard watchRecording else { return }
        watchSuppliedCoordinate = (lat, lon)
        Task { await self.refreshSpeciesFilter() }
    }

    /// Called when the watch sends a "stop" handshake.
    func stopFromWatch() {
        guard watchRecording else { return }
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
        watchKeepalive.stop()
        cancelWatchLifecycleWatchdogs()
        cancelIdleWatchdog()
    }

    /// Called when the watch reports that the *system* killed its recording
    /// session (e.g. the wrist dropped without the background-audio
    /// entitlement, or the runtime budget expired). Unlike a user-initiated
    /// stop, the user didn't ask for this, so we surface a notification before
    /// tearing down. Guarded by `stopFromWatch`'s own `watchRecording` check so
    /// it's a no-op (and fires no duplicate alert) if the heartbeat watchdog
    /// already tore the session down.
    func stopFromWatchUnexpectedly() {
        guard watchRecording else { return }
        Task {
            await SpeciesNotifications.shared.notifySessionLifecycle(
                title: "Kestrel",
                body: "Watch recording stopped. Re-tap the watch button to keep listening."
            )
        }
        stopFromWatch()
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
                try? await Task.sleep(for: .seconds(self?.watchWatchdogInterval ?? 3))
                guard !Task.isCancelled, let self else { return }
                let stillAlive = self.checkWatchAudioLiveness()
                if !stillAlive { return }
            }
        }

        // Phone-side heartbeat sender: tells the watch the phone is alive and
        // still considers this session active, so the watch's own watchdog can
        // tell "phone here" from "phone gone."
        phoneHeartbeatTask?.cancel()
        phoneHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sendPhoneHeartbeat()
                try? await Task.sleep(for: .seconds(self.watchWatchdogInterval))
            }
        }
    }

    private func cancelWatchLifecycleWatchdogs() {
        watchHeartbeatTask?.cancel()
        watchHeartbeatTask = nil
        phoneHeartbeatTask?.cancel()
        phoneHeartbeatTask = nil
        lastWatchAudioAt = nil
        watchStallNudged = false
    }

    /// Beat sent only while the phone believes a watch session is live. Live
    /// `sendMessage` when reachable; a background-tolerant `transferUserInfo`
    /// otherwise so the watch still sees it (queued) when both apps are
    /// backgrounded — the case where audio tends to stall.
    private func sendPhoneHeartbeat() {
        guard watchRecording, WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        let payload: [String: Any] = ["cmd": "phoneHeartbeat"]
        if s.isReachable {
            s.sendMessage(payload, replyHandler: nil, errorHandler: { _ in
                WCSession.default.transferUserInfo(payload)
            })
        } else {
            s.transferUserInfo(payload)
        }
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
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        s.sendMessage(["cmd": "restartCapture"], replyHandler: nil, errorHandler: nil)
        s.transferUserInfo(["cmd": "restartCapture"])
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
            let s = WCSession.default
            if s.activationState == .activated {
                s.sendMessage(["cmd": "remoteStop"], replyHandler: nil, errorHandler: nil)
                s.transferUserInfo(["cmd": "remoteStop"])
            }
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

    /// Populates `lifeListSnapshot` + `starredNames` straight from the store.
    /// Called at the top of every start path (local and watch-driven) so the
    /// "is this species already a lifer?" check is correct regardless of
    /// whether a SwiftUI view happens to be mounted and observing — without
    /// this, a watch-initiated background session started a stale (often
    /// empty) snapshot and notified for every bird heard.
    private func refreshLifeListFromStore() {
        guard let store = lifeListStore else { return }
        lifeListSnapshot = Set(store.entries.map(\.scientificName))
        starredNames = store.starredNames
    }

    /// Live mirror of the user's starred species. Unlike `lifeListSnapshot`
    /// this is *not* frozen at session start — toggling a star mid-session
    /// should immediately change which detections fire notifications and
    /// which spectrogram bands get the blue tint.
    func updateStarred(_ scientificNames: Set<String>) {
        starredNames = scientificNames
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
    /// just filed go on buzzing every `hapticCooldown` and re-notifying every
    /// `notifyCooldown` for the rest of the walk. A starred bird still alerts
    /// either way — a star is a standing "tell me again", not a gap in the user's
    /// records.
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
        let cooldown: TimeInterval = 5
        var repeatedIDs: [String] = []
        // Detections that should fire a notification this batch: species heard
        // with no detection in the last `notifyCooldown` s.
        var notifications: [(common: String, scientific: String, reason: SpeciesNotifications.Reason)] = []
        // Detections that should buzz this batch — gated by the much shorter
        // `hapticCooldown`, so a repeated new/starred bird keeps tapping even
        // while its notification is still on cooldown.
        var haptics: [SpeciesNotifications.Reason] = []
        // When the "Haptic for All Birds" setting is on, a single soft haptic
        // also fires for any *known, non-starred* bird heard this batch — the
        // everyday birds that otherwise buzz nothing. Read once; collapsed to one
        // tap per batch so several ordinary species in the same window don't
        // stack buzzes.
        let hapticForAllBirds = AppSettings.shared.hapticForAllBirds
        var playSoftHaptic = false
        for d in results {
            if let existing = detectionMap[d.id] {
                if d.confidence > existing.confidence {
                    detectionMap[d.id] = d  // takes new confidence + new lastSeen
                } else {
                    var updated = existing
                    updated.lastSeen = d.lastSeen
                    detectionMap[d.id] = updated
                }
                let lastFlash = lastFlashAt[d.id]
                if lastFlash == nil || now.timeIntervalSince(lastFlash!) >= cooldown {
                    repeatedIDs.append(d.id)
                    lastFlashAt[d.id] = now
                }
            } else {
                detectionMap[d.id] = d
            }

            // Notify when (a) the species is worth alerting about — see
            // `alertReason`, which is where "starred, or heard before you'd
            // recorded it and still unrecorded" is decided — and (b) it hasn't
            // been heard for at least `notifyCooldown` seconds. The clock resets
            // on every detection, so a continuously-singing bird only triggers
            // once; a bird that goes silent and returns re-fires.
            let recorded = lifeListStore?.speciesNames ?? lifeListSnapshot
            if let reason = Self.alertReason(
                scientificName: d.scientificName,
                starred: starredNames,
                snapshotAtSessionStart: lifeListSnapshot,
                recordedNow: recorded
            ) {
                let last = lastHeardAt[d.scientificName]
                if last == nil || now.timeIntervalSince(last!) >= notifyCooldown {
                    notifications.append((d.commonName, d.scientificName, reason))
                }
                // Haptic on its own, shorter clock so repeats still buzz while
                // the notification stays muted for the rest of its window.
                let lastBuzz = lastHapticAt[d.scientificName]
                if lastBuzz == nil || now.timeIntervalSince(lastBuzz!) >= hapticCooldown {
                    haptics.append(reason)
                    lastHapticAt[d.scientificName] = now
                }
            } else if hapticForAllBirds {
                // A known, non-starred bird — a single subtle haptic when the
                // setting is on, on the same short per-species cooldown so a
                // continuously-singing bird doesn't buzz every window. Reached
                // by anything the branch above passed over, which now includes a
                // bird added mid-session: it *is* a known bird from the moment
                // it's recorded, and the soft haptic is what known birds get.
                let lastBuzz = lastHapticAt[d.scientificName]
                if lastBuzz == nil || now.timeIntervalSince(lastBuzz!) >= hapticCooldown {
                    playSoftHaptic = true
                    lastHapticAt[d.scientificName] = now
                }
            }
            lastHeardAt[d.scientificName] = now
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
        // `hapticCooldown` — since a tap signals something worth looking up,
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

    private func refreshSpeciesFilter() async {
        guard let rangeFilter = await getRangeFilter() else {
            allowedIndices = nil
            locationStatus = "Showing all species"
            return
        }
        // Prefer a coordinate the watch supplied for this session — it's the only
        // location a watch-first user has — falling back to the phone's own fix.
        let location: CLLocation?
        if let coord = watchSuppliedCoordinate {
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
                locationStatus = "Filtered to \(allowed.count) nearby species"
                return
            } catch {
                Log.error("Geo inference failed — \(error)")
            }
        }
        if let cached = await rangeFilter.loadCached() {
            allowedIndices = cached
            prefetchRegionImages(cached)
            locationStatus = "Using last-known list (\(cached.count) species)"
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
            locationStatus = "Using offline list (\(offline.count) species)"
        } else {
            allowedIndices = nil
            locationStatus = "Showing all species (no location yet)"
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
            // The prompt just resolved — refresh the grayed-button flag in case the
            // user denied it. Also push the combined authorization to the watch
            // unconditionally: an undetermined→granted transition doesn't flip
            // `micAccessDenied` (it was already false), so `refreshMicrophoneAuthorization`
            // wouldn't push on its own, leaving the watch blocked until some later
            // event. (`updateApplicationContext` de-dupes, so a redundant push is free.)
            refreshMicrophoneAuthorization()
            onRecordingAuthorizationChanged?()
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
