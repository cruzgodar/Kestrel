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
    /// sleeps. Capped at ~1 hour by the system; we let it expire and the
    /// user can re-tap the button to start a fresh session.
    private var extendedSession: WKExtendedRuntimeSession?

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
        } catch {
            print("Kestrel Watch: streamer start error \(error)")
            stopExtendedSession()
        }
    }

    private func stop() {
        guard isRecording else { return }
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

/// Plain NSObject delegate — the activation callbacks fire on a background
/// queue, so keeping the delegate off the main actor avoids extra hops.
private final class SessionDelegate: NSObject, WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error { print("Kestrel Watch: WCSession activation error \(error)") }
    }
}
