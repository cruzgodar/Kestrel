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
    /// actually running (microphone-permission prompt + extended-runtime
    /// session + audio engine spin-up — 2–3 s on a cold first launch). The UI
    /// shows a non-interactive loading state during this window so the tap
    /// gets immediate feedback instead of appearing dead.
    private(set) var isStarting = false

    /// How a heard bird is highlighted — picks the watch's background color.
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

    /// Scientific names the user has added to the life list (via the watch's add
    /// button) during the current listening session. Tracked here so the add
    /// button's checkmark state survives the bird being re-heard later in the
    /// same session, and undone with a second tap. Reset at the start of each
    /// session.
    private(set) var addedThisSession: Set<String> = []

    /// Whether the currently-displayed bird has been added to the life list this
    /// session — drives the add button's plus ↔ checkmark state.
    var isCurrentBirdAdded: Bool {
        guard let sci = lastBird?.scientificName else { return false }
        return addedThisSession.contains(sci)
    }

    /// Toggles the displayed bird's life-list membership. Optimistically updates
    /// `addedThisSession` (so the button flips immediately) and tells the phone
    /// to add/remove it from the persisted life list. No-op unless a new-species
    /// bird is showing.
    func toggleCurrentBirdLifeList() {
        guard let bird = lastBird, bird.highlight == .newSpecies else { return }
        let sci = bird.scientificName
        if addedThisSession.contains(sci) {
            withAnimation { _ = addedThisSession.remove(sci) }
            sendLifeListCommand("removeFromLifeList", bird: bird)
        } else {
            withAnimation { _ = addedThisSession.insert(sci) }
            sendLifeListCommand("addToLifeList", bird: bird)
        }
    }

    /// Sends an add/remove life-list command to the phone, carrying the species
    /// identity so the phone can persist it. Live `sendMessage` when reachable,
    /// background-tolerant `transferUserInfo` otherwise.
    private func sendLifeListCommand(_ cmd: String, bird: HeardBird) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        let payload: [String: Any] = [
            "cmd": cmd,
            "lifeListCommon": bird.commonName,
            "lifeListSci": bird.scientificName,
        ]
        if s.isReachable {
            s.sendMessage(payload, replyHandler: nil, errorHandler: { _ in
                WCSession.default.transferUserInfo(payload)
            })
        } else {
            s.transferUserInfo(payload)
        }
    }
    /// Cached/transferred image for `lastBird`, or nil while it's still being
    /// fetched from the phone (or if none is available).
    private(set) var lastBirdImage: UIImage?

    private let streamer = WatchAudioStreamer()
    /// Serializes the blocking audio-engine start/stop so they never overlap
    /// (a deferred stop and a fresh start can otherwise race the engine).
    private let audioQueue = DispatchQueue(label: "com.kestrel.watch.audio", qos: .userInitiated)
    private let delegate = SessionDelegate()
    private let extendedDelegate = ExtendedSessionDelegate()
    private var activated = false
    /// Set just before we invalidate the extended runtime session ourselves
    /// (normal stop or the 30-minute auto-restart cycle) so the delegate's
    /// invalidation callback can tell a deliberate teardown apart from the
    /// system killing the session out from under us.
    private var expectedERSInvalidation = false

    private override init() {
        super.init()
        // The system can invalidate our extended runtime session at any time
        // — most commonly `.resignedFrontmost` when the wrist drops without
        // the background-audio entitlement. Route that back here so we can
        // tear down and tell the phone to notify the user.
        extendedDelegate.onInvalidate = { reason in
            Task { @MainActor [weak self] in
                self?.handleExtendedSessionInvalidation(reason)
            }
        }
    }

    /// Mirrored from the phone's Settings tab via the WCSession application
    /// context. When true the streamer requests a background-capable audio
    /// session (see `WatchAudioStreamer.start(useBackgroundEntitlement:)`).
    /// Takes effect on the next `start()`; an in-flight recording isn't
    /// reconfigured mid-session.
    private(set) var useBackgroundAudioEntitlement = false

    /// Applies a preference pushed from the phone. Stored for the next capture.
    func setBackgroundAudioEntitlement(_ enabled: Bool) {
        useBackgroundAudioEntitlement = enabled
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
    nonisolated(unsafe) private let bgLock = NSLock()
    nonisolated(unsafe) private var bgBuffer = Data()
    /// 32 KB ≈ 1 s of 16 kHz Int16 mono. Comfortably under the ~64 KB
    /// per-message limit transferUserInfo enforces.
    nonisolated private let bgFlushBytes = 32_000

    /// Keeps the watch app running when the wrist drops or the screen
    /// sleeps. The system caps a single session at ~1 hour, so we cycle
    /// it (along with the audio engine) every 30 minutes — see
    /// `scheduleAutoRestart()`. The phone never sees a stop; chunks just
    /// pause for the sub-second tear-down + relaunch.
    private var extendedSession: WKExtendedRuntimeSession?

    /// Fires every 30 minutes while we're recording. Tears down + restarts
    /// the audio capture + extended runtime session so we never bump into
    /// the 1-hour ERS cap. State on the phone is preserved (no "stop"
    /// handshake is sent), so the detection list and life-list stay intact.
    private var autoRestartTask: Task<Void, Never>?
    private let autoRestartInterval: Duration = .seconds(30 * 60)

    func activate() {
        guard !activated, WCSession.isSupported() else { return }
        activated = true
        let session = WCSession.default
        session.delegate = delegate
        session.activate()
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

    /// Called when the phone asks the watch to stop streaming. Idempotent.
    func handleRemoteStop() {
        guard isRecording else { return }
        stop()
    }

    /// Phone started recording with its own mic — mirror its now-hearing screen
    /// without capturing any audio here. No-op if a real watch recording is in
    /// progress (the watch's own capture wins).
    func handlePhoneRecordingStarted() {
        guard !isRecording, !isStarting else { return }
        lastBird = nil
        lastBirdImage = nil
        addedThisSession = []
        mirroringPhone = true
        withAnimation(.easeInOut(duration: 0.3)) {
            isRecording = true
        }
    }

    /// Phone stopped its mic recording — drop the mirrored display.
    func handlePhoneRecordingStopped() {
        guard mirroringPhone else { return }
        endMirrorDisplay()
    }

    /// Tells the phone to stop its mic recording, then drops the mirror locally.
    private func stopMirroring() {
        let session = WCSession.default
        session.sendMessage(["cmd": "stopPhone"], replyHandler: nil, errorHandler: nil)
        session.transferUserInfo(["cmd": "stopPhone"])
        endMirrorDisplay()
    }

    /// Shared mirror teardown: fade the now-hearing screen out, then clear the
    /// retained bird once it's hidden so the next session doesn't flash it.
    private func endMirrorDisplay() {
        mirroringPhone = false
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
        lastBird = nil
        lastBirdImage = nil
        addedThisSession = []
    }

    /// Phone fires this on a fresh detection that crossed the notify
    /// threshold. The kind picks a distinct WKHapticType so a starred bird
    /// feels different on the wrist from a brand-new species.
    func playHaptic(kind: String) {
        let type: WKHapticType
        switch kind {
        case "starred": type = .success       // softer rising chime
        case "newSpecies": type = .notification  // sharper double-tap
        default: type = .click
        }
        WKInterfaceDevice.current().play(type)
    }

    /// Phone reported a freshly-heard interesting bird. Updates the "now
    /// hearing" display and resolves its image — from the local cache if we've
    /// seen this species before, otherwise by asking the phone to send it.
    func handleBirdHeard(commonName: String, scientificName: String, highlight: BirdHighlight) {
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
    }

    /// Phone delivered image bytes for a species. Cache them, and if it's still
    /// the bird we're showing, update the display.
    func handleImageReceived(scientificName: String, data: Data) {
        let image = WatchSpeciesImageCache.shared.store(data, for: scientificName)
        if lastBird?.scientificName == scientificName {
            lastBirdImage = image
        }
    }

    /// Asks the phone for a species image we don't have cached. Live path when
    /// reachable, queued fallback otherwise.
    private func requestImage(scientificName: String) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        if s.isReachable {
            s.sendMessage(["needImage": scientificName], replyHandler: nil, errorHandler: nil)
        } else {
            s.transferUserInfo(["needImage": scientificName])
        }
    }

    private func start() {
        guard !isRecording, !isStarting else { return }

        // Fresh session — drop any bird left over from the previous one so the
        // "now hearing" screen starts on "Listening…", and clear the per-session
        // add-to-life-list tracking.
        lastBird = nil
        lastBirdImage = nil
        addedThisSession = []
        // Flip to recording inside an animated transaction, then touch audio
        // only after the morph has played (the timed sleep below). Nothing
        // audio-related runs on the tap itself, so the first tap is never
        // blocked by audio-subsystem warm-up. A plain `withAnimation` is used
        // deliberately — the `completion:` variant stalled the first render by
        // ~1 s on watchOS. `isStarting` marks the bring-up window so a stop
        // tapped during it cancels cleanly.
        isStarting = true
        withAnimation(.easeInOut(duration: 0.3)) {
            isRecording = true
        }
        // Tell the phone immediately — optimistically, before the seconds-long
        // audio-engine bring-up below — so its UI flips to the watch-recording
        // state without waiting. The failure paths in `startWithPermission`
        // roll this back with a matching "stop".
        notifyPhoneStarted()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            await self?.startWithPermission()
        }
    }

    /// Optimistic "we're recording" handshake. sendMessage is the fast path when
    /// both apps are foreground; transferUserInfo is the background-tolerant
    /// fallback that can wake the iOS app from suspension. Both fire — duplicates
    /// are no-ops on the iOS side.
    private func notifyPhoneStarted() {
        let session = WCSession.default
        session.sendMessage(["cmd": "start"], replyHandler: nil, errorHandler: nil)
        session.transferUserInfo(["cmd": "start"])
    }

    /// Rollback handshake for when an optimistically-announced start fails to
    /// bring audio up (permission denied, engine error).
    private func notifyPhoneStopped() {
        let session = WCSession.default
        session.sendMessage(["cmd": "stop"], replyHandler: nil, errorHandler: nil)
        session.transferUserInfo(["cmd": "stop"])
    }

    private func startWithPermission() async {
        // Whatever happens below, we're out of the bring-up window by the time
        // we return.
        defer { isStarting = false }

        // Runs only after the morph played out (see `start()`), so the audio
        // bring-up — which taxes the main thread even off it — can't stutter it.
        guard isRecording else { return }  // stopped during the morph

        guard await Self.ensureMicrophonePermission() else {
            print("Kestrel Watch: microphone permission denied")
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
            print("Kestrel Watch: streamer start error \(error)")
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

        // Extended runtime session keeps capture alive once the wrist drops;
        // start it now that audio is flowing.
        startExtendedSession()

        // The phone was already told we're recording (optimistically, in
        // `start()`), so audio it receives lines up with its UI state.

        scheduleAutoRestart()
    }

    /// Starts the audio engine on a background queue. `AVAudioSession.setActive`
    /// + `AVAudioEngine.start()` block their caller for seconds on a cold first
    /// launch; running them on the main actor froze the UI so the loading state
    /// never rendered and the start → recording transition never animated.
    private func startStreamerOffMain() async throws {
        let streamer = self.streamer
        let useBackgroundEntitlement = self.useBackgroundAudioEntitlement
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioQueue.async {
                do {
                    try streamer.start(useBackgroundEntitlement: useBackgroundEntitlement) { [weak self] data in
                        self?.deliver(data)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func stop() {
        guard isRecording else { return }
        autoRestartTask?.cancel()
        autoRestartTask = nil

        // Tell the phone right away (both cheap + non-blocking) so it tears
        // down too, after flushing any background-queued audio.
        flushBackgroundBuffer()
        let session = WCSession.default
        session.sendMessage(["cmd": "stop"], replyHandler: nil, errorHandler: nil)
        session.transferUserInfo(["cmd": "stop"])
        stopExtendedSession()

        // Animate the morph; tear the audio engine down only once it has played
        // out (the timed sleep below). `engine.stop()` + `setActive(false)`
        // block their caller for seconds on a cold first stop and post
        // route-change callbacks to the main actor, which would freeze the morph
        // if run during it. A plain `withAnimation` is used deliberately — the
        // `completion:` variant stalled the first render by ~1 s on watchOS. If
        // the user re-taps record before the sleep elapses (`isRecording` flips
        // back true), the teardown is skipped so the fresh session keeps its
        // engine.
        let streamer = self.streamer
        let audioQueue = self.audioQueue
        withAnimation(.easeInOut(duration: 0.3)) {
            isRecording = false
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard self?.isRecording == false else { return }
            audioQueue.async { streamer.stop() }
            // Now-hearing screen is hidden — drop the retained bird so the next
            // session doesn't briefly flash this one.
            self?.clearHeardBird()
        }
    }

    /// Schedules the next 30-minute audio + ERS cycle. Idempotent — calling
    /// it again cancels any prior timer.
    private func scheduleAutoRestart() {
        autoRestartTask?.cancel()
        autoRestartTask = Task { [weak self, interval = autoRestartInterval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.performAutoRestart()
        }
    }

    /// Transparently cycles the audio engine + extended runtime session.
    /// Phone-side state (detections, life list, location filter) is
    /// preserved because we don't send "stop"/"start" handshakes — chunks
    /// simply pause for the sub-second restart window, well under the
    /// phone's 60-second disconnect threshold.
    private func performAutoRestart() async {
        guard isRecording else { return }

        // Tear down audio first so the audio session is released before
        // we ask for a new ERS to take its place.
        streamer.stop()
        flushBackgroundBuffer()
        stopExtendedSession()

        // Bring the new ERS + streamer up. If anything fails, do a hard
        // stop so the user (and phone) aren't left in a confused state.
        startExtendedSession()
        do {
            try await startStreamerOffMain()
            scheduleAutoRestart()
        } catch {
            print("Kestrel Watch: auto-restart failed \(error)")
            // Force a clean stop, which will send "stop" to the phone.
            isRecording = true  // ensure stop() runs its full path
            stop()
        }
    }

    /// Audio-thread callback from the streamer. Picks live messaging when
    /// the phone is reachable, otherwise accumulates into a buffer and
    /// flushes via `transferUserInfo` once we have ~1 s queued up.
    nonisolated private func deliver(_ data: Data) {
        let s = WCSession.default
        if s.isReachable {
            s.sendMessageData(data, replyHandler: nil, errorHandler: nil)
            return
        }
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
            s.transferUserInfo(["audio": payload])
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

    private func startExtendedSession() {
        guard extendedSession == nil else { return }
        let s = WKExtendedRuntimeSession()
        s.delegate = extendedDelegate
        s.start()
        extendedSession = s
    }

    private func stopExtendedSession() {
        guard let session = extendedSession else { return }
        // Mark this as our own teardown so the invalidation callback doesn't
        // mistake it for a system kill and fire a spurious "stopped" alert.
        expectedERSInvalidation = true
        session.invalidate()
        extendedSession = nil
    }

    /// Invoked when the extended runtime session is invalidated. Distinguishes
    /// our own teardown (normal stop / auto-restart cycle) from a system kill
    /// — the latter means audio capture is dead and the user should be told.
    private func handleExtendedSessionInvalidation(_ reason: WKExtendedRuntimeSessionInvalidationReason) {
        if expectedERSInvalidation {
            expectedERSInvalidation = false
            return
        }
        // The system tore the session down on us (wrist lowered without the
        // background-audio entitlement, the 1-hour cap, an error...). Nothing
        // is capturing audio anymore. Drop our reference — it's already
        // invalid — tear the rest down, and tell the phone to notify.
        extendedSession = nil
        guard isRecording || isStarting else { return }
        print("Kestrel Watch: extended session killed by system — \(reason.rawValue)")
        endRecordingUnexpectedly()
    }

    /// Hard-stops a recording that the system killed and signals the phone with
    /// a distinct command so it surfaces a notification, rather than tearing
    /// down silently the way a user-initiated stop does. The phone's 60-second
    /// audio-gap watchdog is only a backstop — it frequently never fires
    /// because iOS has also suspended the phone app by then.
    private func endRecordingUnexpectedly() {
        autoRestartTask?.cancel()
        autoRestartTask = nil
        streamer.stop()
        isRecording = false
        isStarting = false
        clearHeardBird()
        flushBackgroundBuffer()
        let session = WCSession.default
        session.sendMessage(["cmd": "stopUnexpected"], replyHandler: nil, errorHandler: nil)
        session.transferUserInfo(["cmd": "stopUnexpected"])
    }
}

/// Bridges the extended runtime session's lifecycle callbacks back to the
/// manager. `onInvalidate` lets the manager react when the session ends —
/// crucially, when the *system* ends it (which otherwise left the recording
/// silently dead with no notification).
private final class ExtendedSessionDelegate: NSObject, WKExtendedRuntimeSessionDelegate {
    var onInvalidate: ((WKExtendedRuntimeSessionInvalidationReason) -> Void)?

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}
    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}
    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?) {
        if let error { print("Kestrel Watch: extended session invalidated — \(reason.rawValue) \(error)") }
        onInvalidate?(reason)
    }
}

/// Routes incoming WCSession callbacks (which fire on a background queue)
/// back to the main-actor `WatchSessionManager`.
private final class SessionDelegate: NSObject, WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error { print("Kestrel Watch: WCSession activation error \(error)") }
        // Pick up the last preference the phone pushed before we activated.
        applyContext(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        route(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        route(userInfo)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        applyContext(applicationContext)
    }

    private func applyContext(_ context: [String: Any]) {
        if let enabled = context["watchBgAudioEntitlement"] as? Bool {
            Task { @MainActor in
                WatchSessionManager.shared.setBackgroundAudioEntitlement(enabled)
            }
        }
    }

    private func route(_ payload: [String: Any]) {
        if let cmd = payload["cmd"] as? String {
            Task { @MainActor in
                switch cmd {
                case "remoteStart": WatchSessionManager.shared.handleRemoteStart()
                case "remoteStop":  WatchSessionManager.shared.handleRemoteStop()
                case "phoneStart":  WatchSessionManager.shared.handlePhoneRecordingStarted()
                case "phoneStop":   WatchSessionManager.shared.handlePhoneRecordingStopped()
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
            Task { @MainActor in
                WatchSessionManager.shared.handleBirdHeard(
                    commonName: common,
                    scientificName: scientific,
                    highlight: highlight
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
