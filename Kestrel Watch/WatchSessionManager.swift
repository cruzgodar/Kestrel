import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit
import WatchConnectivity
import WatchKit

/// Owns the watch-side `WCSession` and the audio streamer. The UI just calls
/// `toggle()`. The session sends a "start"/"stop" control message before/after
/// the stream so the phone knows when to disable its own record button.
@MainActor
@Observable
final class WatchSessionManager: NSObject {
    static let shared = WatchSessionManager()

    private(set) var isRecording = false
    /// True from the moment the button is tapped until audio capture is
    /// actually running (microphone-permission prompt + audio engine spin-up —
    /// 2–3 s on a cold first launch). The UI shows a non-interactive loading
    /// state during this window so the tap gets immediate feedback instead of
    /// appearing dead.
    private(set) var isStarting = false

    /// Whether the *watch's own* microphone or location permission is denied. The
    /// watch now records with its own mic and supplies its own coordinate to the
    /// phone (which runs BirdNET but no longer needs its own permissions), so the
    /// watch's own permissions gate the record button — a gray lock the user fixes
    /// in the watch's Settings. Undetermined does *not* lock: the first start
    /// prompts for whatever's missing. Refreshed at launch, on foreground, and
    /// after each permission prompt. Observable so the UI reacts.
    private(set) var micDenied = false
    private(set) var locationDenied = false
    /// True only when a permission recording needs is *explicitly denied* (not
    /// merely undetermined). Drives the gray lock.
    var permissionDenied: Bool { micDenied || locationDenied }

    /// True while neither permission the watch needs has been answered yet,
    /// which puts `WatchWelcomeView` up over the record screen. Derived from the
    /// permissions themselves rather than a "has launched before" flag, so it
    /// clears the moment either is answered — whichever way.
    ///
    /// The watch needs its own screen even when the phone has already been
    /// through onboarding: watchOS microphone and location authorization are
    /// per-device and can only be granted from the wrist.
    private(set) var needsOnboarding = false

    /// Re-reads the watch's own mic + location authorization into the observable
    /// flags. There's no push callback for mic changes, so the view calls this on
    /// appear / foreground as well as after prompts.
    func refreshPermissionState() {
        micDenied = AVAudioApplication.shared.recordPermission == .denied
        locationDenied = WatchLocationProvider.shared.isDenied
        // `&&`, not `||`: see the phone's matching seed in `RecordingManager` —
        // once either prompt has been answered the watch app has been used, and
        // an existing user shouldn't be met by an introduction on upgrade.
        needsOnboarding =
            AVAudioApplication.shared.recordPermission == .undetermined
            && WatchLocationProvider.shared.authorizationStatus == .notDetermined
    }

    /// Runs the first-launch permission sequence behind the welcome screen's Get
    /// Started button, then takes the screen down.
    ///
    /// Same order the first Start Recording tap uses — microphone, then
    /// location, then notifications — each awaited so only one prompt is on the
    /// tiny screen at a time, with the workout request last. Nothing here stops
    /// at a refusal: a user who declines one should still get to answer the rest
    /// now rather than meeting them piecemeal later.
    ///
    /// The workout request belongs here rather than on the phone. HealthKit
    /// authorization is shared across the pair, so the phone could ask for it —
    /// but doing so wouldn't spare the watch this screen (mic and location on
    /// watchOS are per-device), and it would put a Health sheet in front of
    /// phone-only users who never record a walk.
    func requestOnboardingPermissions() async {
        _ = await Self.ensureMicrophonePermission()
        await WatchLocationProvider.shared.requestAuthorization()
        await WatchNotifications.requestAuthorizationIfNeeded()
        await WatchWorkoutManager.shared.requestAuthorization()
        refreshPermissionState()
        // The workout sheet has just been answered, so the phone's stop prompt
        // can be told what it means before the first session even starts.
        sendWorkoutSavable()
        needsOnboarding = false
    }

    /// How a heard bird is highlighted — picks the color the species name is
    /// drawn in on the now-hearing screen (see `ContentView.nameColor`).
    /// The raw values match the strings the phone sends in the `highlight` key.
    enum BirdHighlight: String, Equatable {
        case newSpecies  // not yet on the life list (purple)
        case starred     // on the user's alert list (blue)
        case normal      // already known + not starred (no tint)
    }

    /// The most recent bird the phone reported hearing. Drives the "now
    /// hearing" screen shown while recording.
    struct HeardBird: Equatable {
        let commonName: String
        let scientificName: String
        let highlight: BirdHighlight
    }

    /// Last bird the phone told us about this session (nil until the first one
    /// is heard, and reset at the start of each session).
    private(set) var lastBird: HeardBird?

    /// The `birdSeq` of the most recently applied now-hearing push, so a
    /// re-delivered application context (fired when any other key in it changes)
    /// doesn't re-apply and re-flash the same bird. Not reset per session — the
    /// phone's tag rises monotonically and equality alone gates re-application.
    @ObservationIgnored private var lastBirdSeq: Int = -1

    /// Clears the "now hearing" display back to the placeholder once a bird has
    /// gone unheard for `idleDisplayReset`. Restarted on every detection;
    /// cancelled when the session ends.
    private var idleDisplayResetTask: Task<Void, Never>?
    private let idleDisplayReset: TimeInterval = 60

    /// Cached/transferred image for `lastBird`, or nil while it's still being
    /// fetched from the phone (or if none is available).
    private(set) var lastBirdImage: UIImage?

    private let streamer = WatchAudioStreamer()
    /// Serializes the blocking audio-engine start/stop so they never overlap
    /// (a deferred stop and a fresh start can otherwise race the engine).
    private let audioQueue = DispatchQueue(label: "com.kestrel.watch.audio", qos: .userInitiated)
    private let delegate = SessionDelegate()
    private var activated = false

    // Phone-liveness watchdog. While the watch is capturing, the phone sends a
    // periodic `phoneHeartbeat` (only while it considers the session active). The
    // watch keeps capturing through *transient* gaps — the wrist dropping flips
    // `isReachable` constantly, and heartbeats that fall back to the background
    // `transferUserInfo` queue arrive late — so a short silence must NOT tear the
    // session down (the old 10s / 3-strike version disconnected within ~30s of
    // normal use). Only a *long* silence means the phone is genuinely gone (app
    // killed, out of range with nothing left to receive audio); then we stop so
    // the workout + battery aren't left running. Audio-engine health is handled
    // separately by the interruption/media-reset observers, so this watchdog no
    // longer restarts capture on its own.
    private var phoneHeartbeatWatchdog: Task<Void, Never>?
    private var lastPhoneHeartbeatAt: Date?
    private let watchdogInterval: TimeInterval = 5
    private let phoneGoneThreshold: TimeInterval = 60
    /// Wall-clock time of the watchdog's previous tick. The loop is a chain of
    /// `Task.sleep`s, which the system freezes outright while the app is
    /// suspended — so a tick arriving far later than `watchdogInterval` means
    /// *we* were frozen, not that the phone went quiet. See `checkPhoneHeartbeat`.
    private var lastWatchdogTickAt: Date?
    /// A tick gap beyond this means the app was suspended rather than merely
    /// scheduled late; the heartbeat clock is then reset instead of judged.
    private let suspensionTickGap: TimeInterval = 15
    /// Set when a heartbeat gap first crosses `phoneGoneThreshold`. We probe the
    /// phone and give it one grace window to answer before giving up, so a phone
    /// that was itself suspended (and is about to flush a queued heartbeat) isn't
    /// mistaken for a phone that's gone.
    private var phoneProbedAt: Date?
    private let phoneProbeGrace: TimeInterval = 30
    /// Set when the phone link is lost for good; drives a one-shot alert on the
    /// watch (the device that noticed). Observable; the view clears it.
    var connectionAlert: String?

    private override init() {
        super.init()
        // Seed the permission flags — in particular `needsOnboarding`, which the
        // app's root reads on its very first render, before anything has had a
        // chance to call `activate()` or the view's on-appear refresh.
        refreshPermissionState()
    }

    /// True while the watch is mirroring a recording the *phone* started with
    /// its own mic: the now-hearing screen shows the phone's birds (driven by
    /// the same bird/haptic messages), but the watch captures no audio. Tapping
    /// Stop in this mode tells the phone to end its recording.
    private(set) var mirroringPhone = false

    /// When `WCSession.isReachable` flips to false (watch backgrounded,
    /// phone backgrounded, etc.) `sendMessageData` silently drops chunks.
    /// We accumulate ~1 s of audio here and ship it via `transferUserInfo`,
    /// which queues + delivers in background. The phone ingests it via a
    /// separate delegate callback. Access is serialized by `bgLock`.
    nonisolated private let bgLock = NSLock()
    // `@ObservationIgnored` so the `@Observable` macro leaves this a plain
    // stored property — `nonisolated(unsafe)` can then apply directly, giving
    // the background audio queue mutable access without observation tracking.
    @ObservationIgnored nonisolated(unsafe) private var bgBuffer = Data()
    /// 32 KB ≈ 1 s of 16 kHz Int16 mono. Comfortably under the ~64 KB
    /// per-message limit transferUserInfo enforces.
    nonisolated private let bgFlushBytes = 32_000

    func activate() {
        refreshPermissionState()
        registerAudioObservers()
        guard !activated, WCSession.isSupported() else { return }
        activated = true
        let session = WCSession.default
        session.delegate = delegate
        session.activate()
    }

    /// Observers that keep the watch's own capture alive across audio
    /// interruptions and a media-services reset. On an interruption the system
    /// stops our engine; rather than letting the session silently go dead (the
    /// old failure where "audio never reached the phone for minutes"), we bring
    /// capture straight back up when the interruption ends — the watch analogue of
    /// the phone's auto-resume. Registered once.
    private var audioObserversRegistered = false
    private func registerAudioObservers() {
        guard !audioObserversRegistered else { return }
        audioObserversRegistered = true
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            Task { @MainActor [weak self] in self?.handleAudioInterruption(type) }
        }
        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartCapture(reason: "media services were reset")
            }
        }
    }

    /// Auto-resume for the watch's own capture. `.began` is a no-op — the system
    /// has paused our engine; `.ended` brings it back so the stream continues
    /// without the user re-tapping. Only acts while we're the audio source.
    private func handleAudioInterruption(_ type: AVAudioSession.InterruptionType) {
        guard isRecording, !mirroringPhone else { return }
        switch type {
        case .began:
            break
        case .ended:
            restartCapture(reason: "audio interruption ended")
        @unknown default:
            break
        }
    }

    func toggle() {
        // A stop is always honored (including mid bring-up, since we flip to
        // recording optimistically); a fresh start is ignored while one is
        // already in flight.
        if mirroringPhone {
            // Mirroring a phone-mic session — stop the phone, not a local engine.
            stopMirroring()
        } else if isRecording {
            stop()
        } else if !isStarting {
            start()
        }
    }

    /// Resolves the watch's microphone permission, prompting once if it's
    /// still undetermined. Returns whether capture is allowed to proceed.
    private static func ensureMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    /// Called when the phone asks the watch to begin streaming. Idempotent.
    func handleRemoteStart() {
        guard !isRecording else { return }
        start()
    }

    /// What to do with the birding walk when a stop comes in from the phone.
    /// The phone puts up its own save/resume/discard prompt when the user stops
    /// a watch-started session there, so it sends the answer along with the stop
    /// — otherwise the same question would be waiting on the wrist afterwards.
    /// `.ask` is the watch's own behavior: park the walk and prompt here.
    enum WorkoutDecision: String {
        case ask, save, discard
    }

    /// Called when the phone asks the watch to stop streaming. Idempotent.
    ///
    /// `session` names the capture session the phone means. It sends this on
    /// both channels, so a queued copy always exists and can be delivered after
    /// the session it was about has ended — and this one carries a *decision*,
    /// so a stale `.discard` would throw away the walk of whatever session is
    /// running now. See `captureCommandApplies`.
    func handleRemoteStop(decision: WorkoutDecision = .ask, session token: Int? = nil) {
        guard isRecording else { return }
        guard Self.captureCommandApplies(
            requestToken: token, currentToken: watchSessionToken
        ) else {
            Log.warning("Ignoring a remoteStop for a capture session that has already ended")
            return
        }
        stop(decision: decision)
    }

    /// The phone's name for the session being mirrored, echoed back on
    /// `stopPhone` so the phone can tell a stop meant for *that* session from one
    /// its background queue delivered late — see
    /// `RecordingManager.localSessionToken`. `nil` when the phone sent none.
    private var mirroredPhoneSession: Int?

    /// This watch's name for the capture session it is running, carried on the
    /// `start` and `stop` handshakes and echoed back by the phone on every
    /// command aimed at that session (`remoteStop`, `restartCapture`).
    ///
    /// The exact counterpart of `RecordingManager.localSessionToken`, and for
    /// the same reason: both handshakes go out on *both* channels at once, so a
    /// queued copy of one always exists and can be flushed long after the
    /// session it describes has ended. A user who stops and immediately
    /// restarts on the wrist got the old session's queued `stop` delivered after
    /// the new one's live `start`, and the phone — whose only guard was "is a
    /// watch session running" — tore the new session down while this watch went
    /// on capturing into it. Every chunk was then dropped on the phone's
    /// `watchRecording` guard, and the wrist showed a live recording that
    /// reached nothing until the 90-second give-up watchdog noticed.
    ///
    /// Seeded from the wall clock rather than zero, for the reason
    /// `RecordingManager.localSessionToken` is: the phone process routinely
    /// outlives this one, and a counter that restarted at zero could reissue a
    /// token the phone had already retired.
    private var watchSessionToken = Int(Date().timeIntervalSince1970)

    /// The instant the record button was last tapped, stamped by `beginSession`
    /// and handed to `WatchWorkoutManager.start(walkStartedAt:)` once the
    /// bring-up gets that far. See `WatchWorkoutManager.isLongEnough` for why the
    /// tap, and not the bring-up, is the moment a walk is dated from.
    ///
    /// Not cleared when a session ends: every start overwrites it before anything
    /// reads it, and the workout manager holds the copy that actually matters
    /// (`startDate`, which it clears itself).
    private var walkStartedAt: Date?

    /// Whether a phone command aimed at this watch's capture session still
    /// describes the session running now.
    ///
    /// A `nil` request token is an older phone build, which sends none; those
    /// keep applying unconditionally rather than being dropped, since refusing
    /// them would leave the phone's Stop button unable to end a watch session.
    nonisolated static func captureCommandApplies(requestToken: Int?, currentToken: Int) -> Bool {
        requestToken == nil || requestToken == currentToken
    }

    /// Whether a `phoneStop` still describes the phone session being mirrored.
    ///
    /// The other half of the pair `phoneStartOutcome` opens. `phoneStop` travels
    /// on whichever channel `RecordingManager.sendToWatch` picks *at that
    /// moment*, so a stop sent while this app was unreachable is queued while
    /// the phone's next start goes out live — and the queued stop then lands on
    /// top of the newer session, dropping the mirror for a recording that is
    /// still running, with nothing to bring it back.
    ///
    /// A `nil` on either side means there is no token to disagree about (an
    /// older phone build, or a mirror adopted without one) and the stop applies.
    nonisolated static func phoneStopApplies(requestToken: Int?, mirroredToken: Int?) -> Bool {
        guard let requestToken, let mirroredToken else { return true }
        return requestToken == mirroredToken
    }

    /// What a `phoneStart` means for a watch that may already be doing something.
    ///
    /// `nonisolated` for the reason the phone's `MapPoint` is: the watch target
    /// defaults to MainActor isolation, which would otherwise pin this plain enum
    /// — and its synthesized `==` — to the main actor, out of reach of the tests
    /// that check `phoneStartOutcome`.
    nonisolated enum PhoneStartOutcome: Hashable {
        /// The watch's own capture (or a bring-up on its way to one) owns the
        /// session; the mirror never takes it away.
        case ignore
        /// Nothing running — begin mirroring.
        case beginMirroring
        /// Already mirroring the session this names. Both channels can carry one
        /// start (`sendToWatch` falls back to `transferUserInfo` when a live send
        /// errors), so a duplicate is ordinary and must change nothing —
        /// re-running the setup would blank the now-hearing bird mid-session.
        case alreadyMirroring
        /// Already mirroring, but this names a *different* phone session: the
        /// previous one's `phoneStop` never arrived. Re-target the mirror.
        case retargetMirror
    }

    /// Which of those a `phoneStart` is.
    ///
    /// **`retargetMirror` is the case worth having.** `phoneStop` is sent on the
    /// background-tolerant channel as well as the live one, and either can be
    /// dropped or delivered late; the phone meanwhile is free to start a fresh
    /// mic session. Simply bailing on "already recording" left the mirror holding
    /// the *old* `mirroredPhoneSession`, so the watch's Stop echoed a token that
    /// `RecordingManager.mirrorStopApplies` correctly rejected — the phone kept
    /// recording and the Stop button on the wrist did nothing at all, with the
    /// screen still claiming to be listening.
    ///
    /// A `nil` token is an older phone build, which sends none: two nils compare
    /// as the same session, since there is nothing to tell them apart and
    /// re-targeting on every duplicate would flash the display for no reason.
    nonisolated static func phoneStartOutcome(
        isRecording: Bool,
        isStarting: Bool,
        mirroringPhone: Bool,
        mirroredSession: Int?,
        incomingSession: Int?
    ) -> PhoneStartOutcome {
        guard !isStarting else { return .ignore }
        if mirroringPhone {
            return mirroredSession == incomingSession ? .alreadyMirroring : .retargetMirror
        }
        return isRecording ? .ignore : .beginMirroring
    }

    /// Phone started recording with its own mic — mirror its now-hearing screen
    /// without capturing any audio here. A real watch recording wins; a mirror
    /// already running is re-pointed at the new session (see
    /// `phoneStartOutcome`).
    func handlePhoneRecordingStarted(session token: Int? = nil) {
        switch Self.phoneStartOutcome(
            isRecording: isRecording,
            isStarting: isStarting,
            mirroringPhone: mirroringPhone,
            mirroredSession: mirroredPhoneSession,
            incomingSession: token
        ) {
        case .ignore, .alreadyMirroring:
            return
        case .retargetMirror:
            // A session we never saw end has been replaced by a new one. Adopt
            // its token — that is what the watch's Stop echoes back — and clear
            // the bird, which belonged to the walk that quietly finished.
            mirroredPhoneSession = token
            clearHeardBird()
            startHeartbeatWatchdog()
        case .beginMirroring:
            lastBird = nil
            lastBirdImage = nil
            mirroringPhone = true
            mirroredPhoneSession = token
            withAnimation(.easeInOut(duration: 0.3)) {
                isRecording = true
            }
            // The mirror needs the same liveness check a capture does.
            // `phoneStop` is the only thing that clears this state, and a phone
            // that has been killed sends none — so without a watchdog the wrist
            // showed "Listening on iPhone…" for a session that had already
            // ended, until the user happened to tap Stop.
            startHeartbeatWatchdog()
        }
    }

    /// Phone stopped its mic recording — drop the mirrored display, unless the
    /// stop names a session this is no longer mirroring (see `phoneStopApplies`).
    func handlePhoneRecordingStopped(session token: Int? = nil) {
        guard mirroringPhone else { return }
        guard Self.phoneStopApplies(
            requestToken: token, mirroredToken: mirroredPhoneSession
        ) else {
            Log.warning("Ignoring a phoneStop for a session we are no longer mirroring")
            return
        }
        endMirrorDisplay()
    }

    /// Tells the phone to stop its mic recording, then drops the mirror locally.
    ///
    /// The payload names the session it means. Both channels fire, and the queued
    /// copy can be delivered long after the live one — by which time the phone may
    /// have started a different recording, which this must not end.
    private func stopMirroring() {
        var payload: [String: Any] = ["cmd": "stopPhone"]
        if let mirroredPhoneSession { payload["session"] = mirroredPhoneSession }
        sendToPhoneOnBothChannels(payload)
        endMirrorDisplay()
    }

    /// Shared mirror teardown: fade the now-hearing screen out, then clear the
    /// retained bird once it's hidden so the next session doesn't flash it.
    private func endMirrorDisplay() {
        cancelHeartbeatWatchdog()
        mirroringPhone = false
        mirroredPhoneSession = nil
        withAnimation(.easeInOut(duration: 0.3)) {
            isRecording = false
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard self?.isRecording == false else { return }
            self?.clearHeardBird()
        }
    }

    /// Drops the last-heard species + its photo so a hidden now-hearing screen
    /// holds no stale content into the next session.
    private func clearHeardBird() {
        idleDisplayResetTask?.cancel()
        idleDisplayResetTask = nil
        lastBird = nil
        lastBirdImage = nil
    }

    /// Phone fires this on a fresh detection that crossed the notify
    /// threshold. The kind picks a distinct WKHapticType so a starred bird
    /// feels different on the wrist from a brand-new species.
    func playHaptic(kind: String) {
        let type: WKHapticType
        switch kind {
        case "starred": type = .success       // softer rising chime
        case "newSpecies": type = .notification  // sharper double-tap
        // Single soft tap for the all-birds opt-in. Deliberately *not* one of the
        // multi-beat patterns: `.directionUp` reads on-wrist as the same rising
        // double as `.success` (the starred alert), which defeats the point of a
        // distinct subtle buzz, and `.click` is imperceptible. `.start` is the
        // gentlest single-impulse type that's still reliably felt.
        case "soft": type = .start
        default: type = .click
        }
        WKInterfaceDevice.current().play(type)
    }

    /// Phone reported a freshly-heard interesting bird. Updates the "now
    /// hearing" display and resolves its image — from the local cache if we've
    /// seen this species before, otherwise by asking the phone to send it.
    func handleBirdHeard(commonName: String, scientificName: String, highlight: BirdHighlight, seq: Int? = nil) {
        // The bird arrives via the application context, which re-delivers the
        // *whole* context whenever any key changes. The phone tags each genuine
        // now-hearing push with a rising `birdSeq`; anything at or below the last
        // one applied is a re-delivery, not news. Untagged calls always apply.
        guard Self.shouldApplyBirdPush(seq: seq, lastApplied: lastBirdSeq) else { return }
        if let seq { lastBirdSeq = seq }
        lastBird = HeardBird(
            commonName: commonName,
            scientificName: scientificName,
            highlight: highlight
        )
        if let cached = WatchSpeciesImageCache.shared.image(for: scientificName) {
            lastBirdImage = cached
        } else {
            lastBirdImage = nil
            requestImage(scientificName: scientificName)
        }
        scheduleIdleDisplayReset()
    }

    /// Whether a now-hearing push is newer than the last one applied.
    ///
    /// **Strictly greater, not merely different.** The phone's `birdSeq` only ever
    /// rises within a launch, and is seeded from the wall clock so a fresh phone
    /// process out-numbers whatever it said last time — which is what makes "at or
    /// below" a safe test for "already seen". Comparing for *equality* alone,
    /// which this used to do, let a re-delivered older context through: the
    /// context carries a single now-hearing slot, so an out-of-order replay
    /// announced a bird the phone had already moved on from as the one it was
    /// hearing right now.
    ///
    /// An untagged push (no `seq`) always applies — nothing in the app sends one
    /// today, and dropping an unidentifiable update would be worse than repeating
    /// one.
    nonisolated static func shouldApplyBirdPush(seq: Int?, lastApplied: Int) -> Bool {
        guard let seq else { return true }
        return seq > lastApplied
    }

    /// (Re)arms the idle-display timer so the now-hearing screen falls back to
    /// the placeholder once a bird has gone unheard for a minute, rather than
    /// holding the last bird indefinitely. Re-heard birds cancel + re-arm it.
    private func scheduleIdleDisplayReset() {
        idleDisplayResetTask?.cancel()
        idleDisplayResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.idleDisplayReset ?? 60))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            // Fade back to "Listening…" + the placeholder image, matching the
            // view's `lastBird` cross-fade. The add-button state hides with it.
            withAnimation(.easeInOut(duration: 0.3)) {
                self.lastBird = nil
            }
            self.lastBirdImage = nil
        }
    }

    /// Phone delivered image bytes for a species. Cache them, and if it's still
    /// the bird we're showing, update the display.
    func handleImageReceived(scientificName: String, data: Data) {
        let image = WatchSpeciesImageCache.shared.store(data, for: scientificName)
        if lastBird?.scientificName == scientificName {
            lastBirdImage = image
        }
    }

    /// The phone's debug "Clear Image Cache" control fired. Drop ours too, and
    /// re-fetch whatever we're showing right now so the screen doesn't sit on a
    /// bird whose photo we just deleted.
    func handleClearImageCache() {
        WatchSpeciesImageCache.shared.clearAll()
        guard let scientificName = lastBird?.scientificName else { return }
        lastBirdImage = nil
        requestImage(scientificName: scientificName)
    }

    /// The phone's session, or `nil` when there is nothing to send to.
    ///
    /// The single gate every send on this side passes through. Unlike the phone,
    /// watchOS has no `isPaired` / `isWatchAppInstalled` to add — activation is
    /// the whole check — but it used to be written out at some call sites and
    /// simply omitted at others (`stopMirroring`, both start/stop handshakes, the
    /// teardown's `stop`), which is the shape a real omission hides in.
    private var activePhoneSession: WCSession? {
        guard WCSession.isSupported() else { return nil }
        let s = WCSession.default
        guard s.activationState == .activated else { return nil }
        return s
    }

    /// Sends on **both** channels at once: the live message for immediacy, and
    /// the queued transfer so a suspended phone still gets it. The handshakes a
    /// session's lifecycle turns on go this way, and the phone is idempotent
    /// about receiving both.
    private func sendToPhoneOnBothChannels(_ payload: [String: Any]) {
        guard let s = activePhoneSession else { return }
        s.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        s.transferUserInfo(payload)
    }

    /// Asks the phone for a species image we don't have cached. Live path when
    /// reachable, queued fallback otherwise.
    private func requestImage(scientificName: String) {
        guard let s = activePhoneSession else { return }
        if s.isReachable {
            s.sendMessage(["needImage": scientificName], replyHandler: nil, errorHandler: nil)
        } else {
            s.transferUserInfo(["needImage": scientificName])
        }
    }

    private func start() {
        guard !isRecording, !isStarting else { return }
        // A finished walk still waiting on save / discard / resume owns the
        // screen, and starting over the top of it would strand it: the prompt
        // would go on describing the *previous* walk while a new session ran
        // underneath, and the next stop would overwrite `pendingSave`,
        // `pendingSpan` and `pendingBuilder` with the new walk — quietly throwing
        // away the one the user hadn't answered about yet.
        //
        // The record button can't reach here in that state (it is the prompt's
        // Resume button, or absent when the walk can't be resumed), but
        // `handleRemoteStart` can: `StartRecordingIntent` runs from Shortcuts
        // whatever is on screen. (The complication deliberately only opens the
        // app — see `StartRecordingComplicationView`.) Refuse, and let the user
        // answer the question that is already in front of them.
        guard WatchWorkoutManager.shared.pendingSave == nil else {
            Log.warning("Ignoring a start request while a finished walk is awaiting an answer")
            return
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            beginSession()
        }
    }

    /// Flips into the recording state and schedules the bring-up that follows the
    /// morph. **Call this inside an animated transaction** — the animation belongs
    /// to the caller so a resume can clear the prompt and start recording in one
    /// beat, sending the Resume button back up into the stop button rather than
    /// having it blink out and a fresh one blink in.
    private func beginSession() {
        // Name the session before anything announces it. Monotonic, so the phone
        // can tell a fresh start from a queued duplicate of an old one — see
        // `watchSessionToken` and `RecordingManager.watchStartOutcome`. A Resume
        // off the save prompt reaches here too and takes a new token: it re-runs
        // the whole start handshake, so the phone has to be told which name the
        // stop that eventually follows will carry.
        watchSessionToken &+= 1
        // The walk begins *here*, on the tap — not seconds later when the audio
        // engine and HealthKit are finally up. Everything that follows in this
        // method is deferred by design (the morph, then the microphone prompt,
        // then the engine), and the phone starts its own copy of the same
        // 15-second threshold from the `start` handshake sent at the front of
        // that. Stamping the walk from the tap is what keeps the two clocks in
        // the safe order. See `WatchWorkoutManager.isLongEnough`.
        //
        // Written on a resume too, and ignored there: `WatchWorkoutManager.start`
        // no-ops while a session is live, so a resumed walk keeps the start it
        // already had rather than being restarted from the Resume tap.
        walkStartedAt = Date()
        // Fresh session — drop any bird left over from the previous one so the
        // "now hearing" screen starts on "Listening…" rather than briefly
        // flashing the last bird of the previous walk.
        lastBird = nil
        lastBirdImage = nil
        // Nothing but state flips happen on the tap: audio and the phone
        // handshake are both deferred until the morph has played (the timed
        // sleep below), so the tap is never the frame that stalls. A plain
        // `withAnimation` is used deliberately — the `completion:` variant
        // stalled the first render by ~1 s on watchOS. `isStarting` marks the
        // bring-up window so a stop tapped during it cancels cleanly.
        isStarting = true
        isRecording = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self else { return }
            // Stopped again before the morph even finished — abandon the
            // bring-up, and close the window ourselves since
            // `startWithPermission` (which normally does) never runs.
            guard self.isRecording else {
                self.isStarting = false
                return
            }
            // Tell the phone optimistically, before the seconds-long audio-engine
            // bring-up below, so its UI flips to the watch-recording state without
            // waiting. The failure paths in `startWithPermission` roll this back
            // with a matching "stop".
            self.notifyPhoneStarted()
            await self.startWithPermission()
        }
    }

    /// Optimistic "we're recording" handshake. sendMessage is the fast path when
    /// both apps are foreground; transferUserInfo is the background-tolerant
    /// fallback that can wake the iOS app from suspension. Both fire — duplicates
    /// are no-ops on the iOS side.
    ///
    /// Deliberately carries **no** `workoutSavable`. That would be the obvious
    /// place for it — it is the one payload guaranteed to precede any stop — but
    /// it is sent before HealthKit's authorization sheet has been answered, and
    /// both channels fire at once. The queued copy can be delivered *after* the
    /// standalone `sendWorkoutSavable` that follows the sheet, at which point it
    /// would overwrite a settled `false` with the optimistic `true` it was built
    /// from. Every send of that flag now happens after authorization has resolved,
    /// so all copies agree and out-of-order delivery is harmless.
    private func notifyPhoneStarted() {
        sendToPhoneOnBothChannels(["cmd": "start", "session": watchSessionToken])
    }

    /// Tells the phone whether a birding walk on this watch could be written to
    /// HealthKit at all.
    ///
    /// The phone raises the save/discard prompt when the user stops a watch
    /// session there, and it was gating that on duration alone — the only half of
    /// the question it can answer by itself. The other half is the watch's
    /// HealthKit authorization, which is per-device and can only be granted from
    /// the wrist, so a user who had declined workout sharing was offered "Save
    /// Workout" and got nothing: the watch refuses to park an unsavable walk,
    /// discards it, and the relayed `.save` then has neither a builder nor a span
    /// to write.
    ///
    /// **Only ever sent once the authorization it describes has settled** — after
    /// `WatchWorkoutManager.start()`, which is where the sheet goes up, and after
    /// the onboarding sequence's own request. That is what makes it safe to send
    /// on both channels: every copy carries the same answer, so a queued one
    /// arriving late can't undo a live one. See `notifyPhoneStarted`, which is
    /// pointedly not the carrier for it.
    ///
    /// Until the first of these lands the phone has no answer, and treats that as
    /// "ask" — the behavior it had before. A walk has to run 15 seconds to be
    /// worth prompting about at all, so the gap is not one a user can fall into.
    private func sendWorkoutSavable() {
        sendToPhoneOnBothChannels([
            "cmd": "watchWorkoutSavable",
            "workoutSavable": WatchWorkoutManager.shared.canSaveWorkouts,
        ])
    }

    /// Rollback handshake for when an optimistically-announced start fails to
    /// bring audio up (permission denied, engine error).
    private func notifyPhoneStopped() {
        sendToPhoneOnBothChannels(["cmd": "stop", "session": watchSessionToken])
    }

    private func startWithPermission() async {
        // Whatever happens below, we're out of the bring-up window by the time
        // we return.
        defer { isStarting = false }

        // Runs only after the morph played out (see `start()`), so the audio
        // bring-up — which taxes the main thread even off it — can't stutter it.
        guard isRecording else { return }  // stopped during the morph

        guard await Self.ensureMicrophonePermission() else {
            Log.warning("Microphone permission denied")
            refreshPermissionState()  // reflect the just-made denial in the lock
            isRecording = false  // undo the optimistic flip
            notifyPhoneStopped()  // roll back the optimistic start on the phone
            return
        }
        // The user may have tapped stop while permission resolved.
        guard isRecording else { return }

        // Bring the audio engine up off the main actor (the heaviest, blocking
        // step).
        do {
            try await startStreamerOffMain()
        } catch {
            Log.error("Streamer start error: \(error)")
            isRecording = false
            notifyPhoneStopped()  // roll back the optimistic start on the phone
            return
        }

        // A stop during the off-main bring-up wins — tear the just-started
        // engine back down rather than leaving it running under an idle UI.
        guard isRecording else {
            let streamer = self.streamer
            let audioQueue = self.audioQueue
            audioQueue.async { streamer.stop() }
            return
        }

        // Recording is truly underway now — begin the birding walk workout.
        // The active workout session (with the workout-processing background
        // mode) keeps the app and microphone alive when the wrist drops, and is
        // saved to HealthKit when the user stops. Started here, after the audio
        // engine is up, so the rollback paths above never have a workout to undo.
        // The phone was already told we're recording (optimistically, in
        // `start()`), so audio it receives lines up with its UI state.
        //
        // The walk itself is dated from the *tap*, not from this moment —
        // everything between the two is bring-up, and the phone's copy of the
        // 15-second threshold has been counting since the handshake went out.
        // See `WatchWorkoutManager.isLongEnough`.
        await WatchWorkoutManager.shared.start(walkStartedAt: walkStartedAt ?? Date())
        // `start()` is where HealthKit's authorization sheet goes up, so the
        // answer the handshake carried a moment ago may be out of date. Re-state
        // it now, well before any stop can raise the phone's prompt.
        sendWorkoutSavable()

        // Capture is truly live now — start watching for the phone's heartbeat.
        startHeartbeatWatchdog()

        // Resolve the rest of what a watch-first session needs — the watch's own
        // location (handed to the phone so it can build the nearby-species filter
        // without ever having been opened) and notification permission — off the
        // critical path, so audio is already flowing while these settle. The mic
        // prompt has already resolved above; these come after so prompts never
        // stack.
        Task { [weak self] in await self?.resolveLocationAndNotifications() }
    }

    /// Requests the watch's own location + notification permissions and, once a
    /// fix arrives, sends the coordinate to the phone so it can build (or refine)
    /// the nearby-species filter from where the *watch* is. Best-effort: a denied
    /// or slow fix just leaves the phone on its cached / offline list.
    private func resolveLocationAndNotifications() async {
        await WatchLocationProvider.shared.requestAuthorization()
        refreshPermissionState()
        await WatchNotifications.requestAuthorizationIfNeeded()
        guard let loc = await WatchLocationProvider.shared.currentLocation() else { return }
        sendWatchLocation(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
    }

    /// Ships the watch's coordinate to the phone. Live `sendMessage` when
    /// reachable, background-tolerant `transferUserInfo` otherwise.
    private func sendWatchLocation(lat: Double, lon: Double) {
        guard let s = activePhoneSession else { return }
        let payload: [String: Any] = ["cmd": "watchLocation", "lat": lat, "lon": lon]
        if s.isReachable {
            s.sendMessage(payload, replyHandler: nil, errorHandler: { _ in
                WCSession.default.transferUserInfo(payload)
            })
        } else {
            s.transferUserInfo(payload)
        }
    }

    /// Starts the audio engine on a background queue. `AVAudioSession.setActive`
    /// + `AVAudioEngine.start()` block their caller for seconds on a cold first
    /// launch; running them on the main actor froze the UI so the loading state
    /// never rendered and the start → recording transition never animated.
    private func startStreamerOffMain() async throws {
        let streamer = self.streamer
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioQueue.async {
                do {
                    try streamer.start { [weak self] data in
                        self?.deliver(data)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// `resumable` distinguishes the user tapping stop — where the workout is
    /// paused so "Resume" on the save prompt can continue the same walk — from an
    /// unattended teardown (a watchdog giving up, the system ending the workout),
    /// where the session is genuinely over and must be ended outright.
    ///
    /// `decision` carries an answer the user already gave on the phone, so the
    /// walk is saved or discarded outright instead of parking a duplicate prompt
    /// on the wrist. It's applied in the same task that winds the workout down,
    /// so it can't race the pause/end that has to precede it.
    private func stop(resumable: Bool = true, decision: WorkoutDecision = .ask) {
        guard isRecording else { return }

        // End the phone-liveness watchdog before tearing down.
        cancelHeartbeatWatchdog()

        // The tap does nothing but decide and animate. Parking the birding walk
        // is the decision — a long-enough walk lands in
        // `WatchWorkoutManager.pendingSave` and the user confirms before it's
        // logged, so an unattended teardown can't quietly post a workout to
        // their activity-sharing friends — and it has to land synchronously,
        // inside the same transaction as the flip, so the view knows in one step
        // that the stop button is sliding down into the prompt's Resume button
        // rather than flying back to center. A false return means there was
        // nothing worth asking about (no workout running, or too short a walk);
        // the session is ended outright below instead, which discards it.
        let parked = withAnimation(.easeInOut(duration: 0.3)) { () -> Bool in
            let parked = resumable && WatchWorkoutManager.shared.pause()
            isRecording = false
            return parked
        }

        // Everything with a real cost — the phone handshake, HealthKit, the
        // audio engine — waits out the morph. `engine.stop()` + `setActive(false)`
        // block their caller for seconds on a cold first stop and post
        // route-change callbacks to the main actor, which would freeze the morph
        // if run during it. If the user picks Resume before the sleep elapses
        // (`isRecording` flips back true), the whole teardown is skipped so the
        // continuing session keeps its engine, its phone link and its workout.
        let streamer = self.streamer
        let audioQueue = self.audioQueue
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self, !self.isRecording else { return }

            // Tell the phone so it tears down too, after flushing any
            // background-queued audio.
            self.flushBackgroundBuffer()
            self.notifyPhoneStopped()

            audioQueue.async { streamer.stop() }
            // Now-hearing screen is hidden — drop the retained bird so the next
            // session doesn't briefly flash this one.
            self.clearHeardBird()

            // Wind the workout down: apply the deferred pause behind the prompt,
            // or end the session outright when there was nothing to prompt about.
            if parked {
                WatchWorkoutManager.shared.applyPause()
            } else {
                await WatchWorkoutManager.shared.end()
            }
            switch decision {
            case .ask:     break  // leave it in `pendingSave` and prompt here
            case .save:    await WatchWorkoutManager.shared.save()
            case .discard: await WatchWorkoutManager.shared.discard()
            }
        }
    }

    /// Audio-thread callback from the streamer. Picks live messaging when
    /// the phone is reachable, otherwise accumulates into a buffer and
    /// flushes via `transferUserInfo` once we have ~1 s queued up.
    nonisolated private func deliver(_ data: Data) {
        let s = WCSession.default
        if s.isReachable {
            // Live path. If it fails despite reachability — common right after the
            // watch resumes from suspension, where `sendMessageData` errors with
            // WCErrorCode 7014 ("Payload could not be delivered") — don't drop the
            // audio. Re-queue it for background delivery so a momentary hiccup
            // doesn't punch a hole in the stream (the failure that used to leave
            // the phone hearing nothing for stretches).
            s.sendMessageData(data, replyHandler: nil, errorHandler: { [weak self] _ in
                self?.bufferForBackground(data)
            })
            return
        }
        bufferForBackground(data)
    }

    /// Accumulates audio and ships ~1 s at a time via `transferUserInfo`, which
    /// queues + delivers even while unreachable (and can wake a suspended iOS
    /// app). Used both when unreachable and as the recovery path for a failed
    /// live send. Serialized by `bgLock`.
    nonisolated private func bufferForBackground(_ data: Data) {
        bgLock.lock()
        bgBuffer.append(data)
        let payload: Data?
        if bgBuffer.count >= bgFlushBytes {
            payload = bgBuffer
            bgBuffer.removeAll(keepingCapacity: true)
        } else {
            payload = nil
        }
        bgLock.unlock()
        if let payload {
            WCSession.default.transferUserInfo(["audio": payload])
        }
    }

    private func flushBackgroundBuffer() {
        bgLock.lock()
        let payload = bgBuffer
        bgBuffer.removeAll(keepingCapacity: true)
        bgLock.unlock()
        guard !payload.isEmpty else { return }
        WCSession.default.transferUserInfo(["audio": payload])
    }

    // MARK: - Phone-liveness watchdog

    /// Phone reported it's alive and still considers the session active.
    func handlePhoneHeartbeat() {
        lastPhoneHeartbeatAt = Date()
    }

    /// Phone (its own audio-liveness watchdog) asked us to restart capture.
    /// Tokened like the stop beside it: this also rides both channels, and a
    /// queued copy landing on a later session would tear a healthy audio engine
    /// down and build it back up for nothing.
    func handleRestartCapture(session token: Int? = nil) {
        guard Self.captureCommandApplies(
            requestToken: token, currentToken: watchSessionToken
        ) else {
            Log.warning("Ignoring a restartCapture for a capture session that has already ended")
            return
        }
        restartCapture(reason: "phone requested capture restart")
    }

    /// Begins (or restarts) the watchdog that confirms the phone's heartbeat is
    /// still arriving. Called once real capture is underway.
    private func startHeartbeatWatchdog() {
        connectionAlert = nil
        lastPhoneHeartbeatAt = Date()
        lastWatchdogTickAt = Date()
        phoneProbedAt = nil
        phoneHeartbeatWatchdog?.cancel()
        phoneHeartbeatWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.watchdogInterval ?? 5))
                guard !Task.isCancelled, let self else { return }
                let keepGoing = self.checkPhoneHeartbeat()
                if !keepGoing { return }
            }
        }
    }

    private func cancelHeartbeatWatchdog() {
        phoneHeartbeatWatchdog?.cancel()
        phoneHeartbeatWatchdog = nil
        lastPhoneHeartbeatAt = nil
        lastWatchdogTickAt = nil
        phoneProbedAt = nil
    }

    /// Returns false once it stops the session so the polling loop exits. Only a
    /// prolonged silence (`phoneGoneThreshold`) counts — transient gaps are
    /// tolerated so the session survives normal reachability churn.
    private func checkPhoneHeartbeat() -> Bool {
        // Deliberately *not* gated on `!mirroringPhone`: a mirrored phone-mic
        // session is the case this was most needed for, since nothing else on
        // the watch can notice the phone going away. The two cases differ only
        // in the teardown at the bottom.
        guard isRecording, let last = lastPhoneHeartbeatAt else { return false }
        let now = Date()

        // Were *we* asleep? The watchdog is a `Task.sleep` chain, so it stops
        // advancing entirely while watchOS has the app suspended. On resume the
        // very first tick would otherwise measure the whole suspension as phone
        // silence and kill a perfectly healthy long session — the failure this
        // guard exists to prevent. Treat an impossibly long tick gap as our own
        // downtime: reset the clock and re-judge on the next real interval.
        if let tick = lastWatchdogTickAt, now.timeIntervalSince(tick) >= suspensionTickGap {
            Log.warning("Watchdog resumed after \(Int(now.timeIntervalSince(tick)))s suspended — not counting it as phone silence")
            lastWatchdogTickAt = now
            lastPhoneHeartbeatAt = now
            phoneProbedAt = nil
            return true
        }
        lastWatchdogTickAt = now

        let gap = now.timeIntervalSince(last)
        guard gap >= phoneGoneThreshold else {
            phoneProbedAt = nil  // healthy again; clear any in-flight probe
            return true
        }

        // Silent long enough to be suspicious — but a backgrounded phone can go
        // quiet for a stretch and then flush its queued heartbeats. Poke it once
        // and wait out `phoneProbeGrace` before concluding anything.
        guard let probed = phoneProbedAt else {
            Log.warning("No phone heartbeat for \(Int(gap))s — probing before giving up")
            phoneProbedAt = now
            probePhone()
            return true
        }
        guard now.timeIntervalSince(probed) >= phoneProbeGrace else { return true }

        // The phone ignored a direct probe too — consider it genuinely gone.
        Log.warning("No phone heartbeat for \(Int(gap))s and no answer to a probe — ending watch session")
        if mirroringPhone {
            // Nothing of *ours* was running — no capture, no workout — so there
            // is nothing to tear down but the display, and `endMirrorDisplay`
            // cancels this watchdog, which is what stops the polling loop.
            //
            // The wording matters here and is not the wording below. All that is
            // established is that we can no longer see the phone; it may well
            // still be recording on its own microphone, which is what a mirrored
            // session *is*. Claiming its recording stopped would be a guess, and
            // usually a wrong one. No notification either: a phone-mic session is
            // one the user is most likely holding, and a buzz about a link they
            // can't act on from the wrist is noise.
            connectionAlert = "Lost the connection to your iPhone."
            endMirrorDisplay()
        } else {
            // Our own capture, whose audio has nowhere to go. Restarting it
            // wouldn't reach the phone either, so stop cleanly and say why — and
            // not resumable, since with the phone gone there is nothing to
            // resume *into*.
            connectionAlert = "Lost the connection to your iPhone. Recording stopped."
            WatchNotifications.notifySessionEnded(
                body: "Lost the connection to your iPhone. Re-tap to keep listening."
            )
            stop(resumable: false)
        }
        return false
    }

    /// The workout session — and with it our background runtime — was ended by
    /// the system rather than by the user. The mic won't survive it, so stop the
    /// recording properly and say so, instead of leaving a session that looks
    /// live on the wrist but has gone deaf.
    func handleWorkoutEndedBySystem() {
        guard isRecording, !mirroringPhone else { return }
        Log.warning("Workout ended by the system — stopping watch session")
        connectionAlert = "Apple Watch ended the session. Re-tap to keep listening."
        WatchNotifications.notifySessionEnded(
            body: "Apple Watch ended the session. Re-tap to keep listening."
        )
        // The workout session is already gone — there's nothing left to pause.
        stop(resumable: false)
    }

    /// User picked "Resume" on the save prompt. Un-pauses the workout so the walk
    /// stays one continuous session, then brings audio and the phone link back up
    /// through the normal start path (whose `WatchWorkoutManager.start()` is a
    /// no-op while a session is already live, so it won't open a second workout).
    ///
    /// Clearing the prompt and flipping into recording share one transaction, so
    /// the Resume button animates back up into the stop button it came from. As
    /// everywhere else, the tap itself only animates: the HealthKit un-pause
    /// (`applyResume`) and the audio bring-up both wait out the morph.
    ///
    /// **Nothing starts if the resume didn't take.** `WatchWorkoutManager.resume()`
    /// returns false when the session was closed out from under the button
    /// between the frame that drew it and the tap, which the ten-minute abandon
    /// timeout does routinely: `endPausedSession()` clears the session and only
    /// re-parks `pendingSave` as non-resumable *after* an `await` on HealthKit's
    /// `endCollection`, so the Resume row stays drawn and tappable for the whole
    /// of that call. Starting anyway is exactly what `start()` refuses to do, for
    /// the same reason — the walk is parked and unanswered, and the next stop
    /// would overwrite `pendingSave`, `pendingSpan` and `pendingBuilder` with the
    /// new one, silently throwing away the walk the user hadn't decided about.
    /// Refusing leaves the prompt standing (minus the Resume row, which the
    /// re-park drops a moment later), so the user answers the question instead.
    func resumeBirding() {
        guard !isRecording, !isStarting else { return }
        let resumed = withAnimation(.easeInOut(duration: 0.3)) { () -> Bool in
            let resumed = WatchWorkoutManager.shared.resume()
            // Only flip into recording once the walk has actually come back —
            // `resume()` clears `pendingSave` in this same transaction, which is
            // what lets the Resume button morph up into the stop button.
            if resumed { beginSession() }
            return resumed
        }
        guard resumed else {
            Log.warning(
                "Resume requested but the workout was no longer resumable — "
                + "leaving the walk awaiting an answer"
            )
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self, self.isRecording else { return }
            WatchWorkoutManager.shared.applyResume()
        }
    }

    /// Asks the phone to prove it's still there, used once a heartbeat gap turns
    /// suspicious. The phone answers with an immediate `phoneHeartbeat` (see
    /// `RecordingManager`), which resets our clock. Sent both live and via the
    /// queued channel so a backgrounded phone still gets it.
    private func probePhone() {
        sendToPhoneOnBothChannels(["cmd": "watchPing"])
    }

    /// Tears the audio engine down and brings it straight back up, without
    /// touching `isRecording`/the UI — the remedy when audio has stalled or a
    /// system interruption stopped the engine. Resets the heartbeat clock so the
    /// restart gets a fresh window.
    private func restartCapture(reason: String) {
        guard isRecording, !mirroringPhone else { return }
        Log.warning("\(reason) — restarting capture")
        lastPhoneHeartbeatAt = Date()
        let streamer = self.streamer
        let audioQueue = self.audioQueue
        audioQueue.async {
            streamer.stop()
            do {
                try streamer.start { [weak self] data in self?.deliver(data) }
            } catch {
                Log.error("Capture restart error: \(error)")
            }
        }
    }
}

/// Routes incoming WCSession callbacks (which fire on a background queue)
/// back to the main-actor `WatchSessionManager`.
private final class SessionDelegate: NSObject, WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error { Log.error("WCSession activation error: \(error)") }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        route(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        route(userInfo)
    }

    /// The phone mirrors the "now hearing" bird here (see `RecordingManager`),
    /// because the application context is delivered even when the phone is
    /// backgrounded — unlike a live `sendMessage`, which a pocketed phone can't
    /// send. Routed the same way as a live bird message; `birdSeq` de-dupes a
    /// context re-delivered for an unrelated key change.
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        route(applicationContext)
    }

    private func route(_ payload: [String: Any]) {
        if let cmd = payload["cmd"] as? String {
            // Deliberately no `remoteStart`: the phone never asks the watch to
            // begin capturing. Its own Start Birding button records on the phone's
            // microphone and only *mirrors* the result here (`phoneStart`), and a
            // watch capture is started from the wrist — the record button, or the
            // start intent via `ContentView.startRecordingIfRequested`, both of
            // which call `handleRemoteStart` directly.
            Task { @MainActor in
                switch cmd {
                case "remoteStop":
                    // The phone answers the save/resume/discard question itself
                    // when the user stops there, and rides the answer along on
                    // `workout`. An older phone build (or a stop from anywhere
                    // else) sends none, which decodes to `.ask` — the watch then
                    // puts the question up on the wrist as before.
                    let raw = payload["workout"] as? String
                    let decision = raw.flatMap(WatchSessionManager.WorkoutDecision.init(rawValue:))
                        ?? WatchSessionManager.WorkoutDecision.ask
                    // The token names the capture session this stop is about, so
                    // a queued copy can't end (or discard the walk of) a later
                    // one. Absent from an older phone build.
                    WatchSessionManager.shared.handleRemoteStop(
                        decision: decision,
                        session: payload["session"] as? Int
                    )
                case "phoneStart":
                    // The token names the phone session being mirrored; it rides
                    // back on `stopPhone`. Absent from an older phone build.
                    WatchSessionManager.shared.handlePhoneRecordingStarted(
                        session: payload["session"] as? Int
                    )
                case "phoneStop":
                    // Names the phone session being ended, so a queued copy
                    // can't drop the mirror of a *later* one.
                    WatchSessionManager.shared.handlePhoneRecordingStopped(
                        session: payload["session"] as? Int
                    )
                case "phoneHeartbeat":  WatchSessionManager.shared.handlePhoneHeartbeat()
                case "restartCapture":
                    WatchSessionManager.shared.handleRestartCapture(
                        session: payload["session"] as? Int
                    )
                case "clearImageCache": WatchSessionManager.shared.handleClearImageCache()
                default: break
                }
            }
        }
        // A bird event carries the species identity plus a `highlight` that
        // picks the background tint (new = purple, starred = blue, normal =
        // none). The display fires for every heard bird; the haptic (below) is
        // sent separately and only for new/starred ones.
        if let common = payload["birdCommon"] as? String,
           let scientific = payload["birdSci"] as? String {
            let highlight = WatchSessionManager.BirdHighlight(
                rawValue: payload["highlight"] as? String ?? ""
            ) ?? .normal
            let seq = payload["birdSeq"] as? Int
            Task { @MainActor in
                WatchSessionManager.shared.handleBirdHeard(
                    commonName: common,
                    scientificName: scientific,
                    highlight: highlight,
                    seq: seq
                )
            }
        }
        if let scientific = payload["imageFor"] as? String,
           let data = payload["image"] as? Data {
            Task { @MainActor in
                WatchSessionManager.shared.handleImageReceived(scientificName: scientific, data: data)
            }
        }
        if let haptic = payload["haptic"] as? String {
            Task { @MainActor in
                WatchSessionManager.shared.playHaptic(kind: haptic)
            }
        }
    }
}
