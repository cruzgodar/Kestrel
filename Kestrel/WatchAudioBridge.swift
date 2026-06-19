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
        // Mirror the watch-facing settings to the watch whenever they change.
        Task { @MainActor in
            AppSettings.shared.watchSyncHook = { [weak self] in
                self?.pushWatchSettings()
            }
        }
    }

    /// Pushes the latest watch-facing preferences to the watch as the WCSession
    /// application context — the watch reads them before it configures its
    /// capture session. `updateApplicationContext` always delivers the most
    /// recent value, even if the watch app is asleep. (The mic-preference is
    /// phone-only — it gates the phone's own Start — so it isn't sent.)
    @MainActor
    func pushWatchSettings() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        try? session.updateApplicationContext([
            "watchBgAudioEntitlement": AppSettings.shared.watchUsesBackgroundAudioEntitlement,
        ])
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
            pushWatchSettings()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        // iOS lets the user re-pair / switch watches at runtime. Re-activate
        // so a fresh session is ready for the new watch.
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleControl(message)
        if let scientificName = message["needImage"] as? String {
            sendWatchImage(for: scientificName)
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
        handleControl(userInfo)
        if let scientificName = userInfo["needImage"] as? String {
            sendWatchImage(for: scientificName)
        }
        if let audio = userInfo["audio"] as? Data {
            ingest(audio)
        }
    }

    /// Dispatches a `cmd` control message — shared by the live `sendMessage` and
    /// background `transferUserInfo` paths, which carry the same payloads.
    private func handleControl(_ payload: [String: Any]) {
        guard let cmd = payload["cmd"] as? String else { return }
        switch cmd {
        case "start":
            Task { @MainActor in await manager.startFromWatch() }
        case "stopPhone":
            // User tapped Stop on the watch while it was mirroring a phone-mic
            // session — stop the phone's local recording.
            Task { @MainActor in manager.stop() }
        case "stop":
            Task { @MainActor in manager.stopFromWatch() }
        case "stopUnexpected":
            Task { @MainActor in manager.stopFromWatchUnexpectedly() }
        case "addToLifeList":
            if let common = payload["lifeListCommon"] as? String,
               let sci = payload["lifeListSci"] as? String {
                Task { @MainActor in
                    manager.addBirdToLifeListFromWatch(commonName: common, scientificName: sci)
                }
            }
        case "removeFromLifeList":
            if let sci = payload["lifeListSci"] as? String {
                Task { @MainActor in
                    manager.removeBirdFromLifeListFromWatch(scientificName: sci)
                }
            }
        default:
            break
        }
    }

    /// Produces (or reuses) the downscaled species image and ships it to the
    /// watch. `transferUserInfo` is the right channel: it's reliable and
    /// background-tolerant, and the payloads are only a few KB. The watch
    /// caches what it receives, so each species is normally sent only once.
    private func sendWatchImage(for scientificName: String) {
        Task.detached(priority: .utility) {
            guard let data = await WatchImageProvider.shared.jpegData(for: scientificName) else {
                return
            }
            let session = WCSession.default
            guard session.activationState == .activated else { return }
            session.transferUserInfo(["imageFor": scientificName, "image": data])
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
