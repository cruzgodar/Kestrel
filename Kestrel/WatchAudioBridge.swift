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
        // Mirror the background-audio setting to the watch whenever it changes.
        Task { @MainActor in
            AppSettings.shared.watchSyncHook = { [weak self] enabled in
                self?.pushWatchBackgroundAudioSetting(enabled)
            }
        }
    }

    /// Pushes the latest background-audio entitlement preference to the watch
    /// as the WCSession application context — the watch reads it before it
    /// configures its capture session. `updateApplicationContext` always
    /// delivers the most recent value, even if the watch app is asleep.
    func pushWatchBackgroundAudioSetting(_ enabled: Bool) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        try? session.updateApplicationContext(["watchBgAudioEntitlement": enabled])
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error { print("Kestrel: WCSession activation error \(error)") }
        // Send the current preference as soon as the session is up so a freshly
        // launched watch app starts from the right configuration.
        guard activationState == .activated else { return }
        Task { @MainActor in
            pushWatchBackgroundAudioSetting(AppSettings.shared.watchUsesBackgroundAudioEntitlement)
        }
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
