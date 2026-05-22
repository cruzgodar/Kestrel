import Foundation
import WatchConnectivity

/// iOS-side endpoint of the watch → phone audio link.
///
/// Activates a `WCSession`, forwards "start"/"stop" control messages to
/// `RecordingManager`, and decodes incoming Int16 PCM chunks into Float
/// samples that the manager feeds through its existing spectrogram +
/// BirdNET windowing path.
final class WatchAudioBridge: NSObject, WCSessionDelegate {
    private let manager: RecordingManager

    init(manager: RecordingManager) {
        self.manager = manager
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error { print("Kestrel: WCSession activation error \(error)") }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        // iOS lets the user re-pair / switch watches at runtime. Re-activate
        // so a fresh session is ready for the new watch.
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let cmd = message["cmd"] as? String else { return }
        Task { @MainActor in
            switch cmd {
            case "start": await manager.startFromWatch()
            case "stop": manager.stopFromWatch()
            default: break
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        ingest(messageData)
    }

    /// Background-tolerant delivery path. When either side is suspended /
    /// out of reachability, the watch falls back to `transferUserInfo`,
    /// which queues + delivers when possible (and can wake the iOS app
    /// from suspension). Carries either a `cmd:` control message or an
    /// `audio:` Data payload of accumulated Int16 PCM.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let cmd = userInfo["cmd"] as? String {
            Task { @MainActor in
                switch cmd {
                case "start": await manager.startFromWatch()
                case "stop": manager.stopFromWatch()
                default: break
                }
            }
        }
        if let audio = userInfo["audio"] as? Data {
            ingest(audio)
        }
    }

    private func ingest(_ data: Data) {
        // Decode Int16 little-endian → Float32 in [-1, 1].
        let count = data.count / MemoryLayout<Int16>.size
        let floats: [Float] = data.withUnsafeBytes { raw in
            let int16s = raw.bindMemory(to: Int16.self)
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count {
                out[i] = Float(int16s[i]) / 32768.0
            }
            return out
        }
        Task { @MainActor in
            manager.ingestWatchSamples16k(floats)
        }
    }
}
