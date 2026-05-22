import Foundation
import Observation
import WatchConnectivity

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
    private var activated = false

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
        }
    }

    private func stop() {
        guard isRecording else { return }
        streamer.stop()
        isRecording = false
        WCSession.default.sendMessage(["cmd": "stop"], replyHandler: nil, errorHandler: nil)
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
