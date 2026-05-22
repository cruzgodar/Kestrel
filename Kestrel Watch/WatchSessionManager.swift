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
        session.sendMessage(["cmd": "start"], replyHandler: nil) { err in
            print("Kestrel Watch: start handshake error \(err)")
        }
        do {
            try streamer.start { data in
                let s = WCSession.default
                guard s.isReachable else { return }
                s.sendMessageData(data, replyHandler: nil, errorHandler: nil)
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
        WCSession.default.sendMessage(["cmd": "stop"], replyHandler: nil, errorHandler: nil)
        stopExtendedSession()
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
