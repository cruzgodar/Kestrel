import Foundation
import Observation
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

    private let streamer = WatchAudioStreamer()
    private let delegate = SessionDelegate()
    private let extendedDelegate = ExtendedSessionDelegate()
    private var activated = false

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
        if isRecording { stop() } else { start() }
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

    /// Phone fires this on a fresh detection that crossed the notify
    /// threshold. The kind picks a distinct WKHapticType so a starred bird
    /// feels different on the wrist from a brand-new species.
    func playHaptic(kind: String) {
        let type: WKHapticType
        switch kind {
        case "starred": type = .notification  // sharper double-tap
        case "newSpecies": type = .success    // softer rising chime
        default: type = .click
        }
        WKInterfaceDevice.current().play(type)
    }

    private func start() {
        guard !isRecording else { return }

        // Kick off the extended runtime session first so the audio capture
        // survives the user lowering their wrist a second later.
        startExtendedSession()

        let session = WCSession.default
        // Tell the phone we're starting before audio chunks begin to arrive.
        // sendMessage is the fast path when both apps are foreground;
        // transferUserInfo is the background-tolerant fallback that can
        // wake the iOS app from suspension. Both fire — duplicates are
        // no-ops on the iOS side.
        session.sendMessage(["cmd": "start"], replyHandler: nil, errorHandler: nil)
        session.transferUserInfo(["cmd": "start"])
        do {
            try streamer.start { [weak self] data in
                self?.deliver(data)
            }
            isRecording = true
            scheduleAutoRestart()
        } catch {
            print("Kestrel Watch: streamer start error \(error)")
            stopExtendedSession()
        }
    }

    private func stop() {
        guard isRecording else { return }
        autoRestartTask?.cancel()
        autoRestartTask = nil
        streamer.stop()
        isRecording = false
        // Flush any background-queued audio before sending stop so the phone
        // processes the final samples before tearing down its keepalive.
        flushBackgroundBuffer()
        let session = WCSession.default
        session.sendMessage(["cmd": "stop"], replyHandler: nil, errorHandler: nil)
        session.transferUserInfo(["cmd": "stop"])
        stopExtendedSession()
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
    private func performAutoRestart() {
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
            try streamer.start { [weak self] data in
                self?.deliver(data)
            }
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
        extendedSession?.invalidate()
        extendedSession = nil
    }
}

/// Logs lifecycle for the extended runtime session. Nothing reactive — the
/// streamer + WCSession are the source of truth for whether we're still
/// recording. If the system expires our hour, audio simply stops.
private final class ExtendedSessionDelegate: NSObject, WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}
    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}
    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?) {
        if let error { print("Kestrel Watch: extended session invalidated — \(reason.rawValue) \(error)") }
    }
}

/// Routes incoming WCSession callbacks (which fire on a background queue)
/// back to the main-actor `WatchSessionManager`.
private final class SessionDelegate: NSObject, WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error { print("Kestrel Watch: WCSession activation error \(error)") }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        route(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        route(userInfo)
    }

    private func route(_ payload: [String: Any]) {
        if let cmd = payload["cmd"] as? String {
            Task { @MainActor in
                switch cmd {
                case "remoteStart": WatchSessionManager.shared.handleRemoteStart()
                case "remoteStop":  WatchSessionManager.shared.handleRemoteStop()
                default: break
                }
            }
        }
        if let haptic = payload["haptic"] as? String {
            Task { @MainActor in
                WatchSessionManager.shared.playHaptic(kind: haptic)
            }
        }
    }
}
