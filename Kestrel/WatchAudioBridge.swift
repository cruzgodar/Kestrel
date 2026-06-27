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
        refreshWatchAppInstalled(session)
        pushLocationAuthorized()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        // iOS lets the user re-pair / switch watches at runtime. Re-activate
        // so a fresh session is ready for the new watch.
        WCSession.default.activate()
    }

    /// Fires when the user pairs/unpairs a watch or installs/removes the watch
    /// app — keep the manager's `isWatchAppInstalled` flag (and the UI it
    /// drives) in sync, and (re)push the location state to the fresh watch.
    func sessionWatchStateDidChange(_ session: WCSession) {
        refreshWatchAppInstalled(session)
        pushLocationAuthorized()
    }

    /// Pushes the phone's current location-authorization state to the watch via the
    /// persisted application context, so the watch shows its "Open Kestrel on
    /// iPhone" screen instead of a dead record button until access is granted.
    /// `updateApplicationContext` only re-delivers on a changed payload, so this is
    /// cheap to call on every authorization change and session/watch-state event.
    func pushLocationAuthorized() {
        Task { @MainActor in
            guard WCSession.isSupported() else { return }
            let session = WCSession.default
            guard session.activationState == .activated else { return }
            let authorized = manager.locationAuthorized
            try? session.updateApplicationContext(["locationAuthorized": authorized])
        }
    }

    /// Pushes the current watch-app-installed state into the manager. Both
    /// `isPaired` and `isWatchAppInstalled` are only meaningful once the
    /// session has activated, which is the only place this is called from.
    private func refreshWatchAppInstalled(_ session: WCSession) {
        let installed = session.isPaired && session.isWatchAppInstalled
        Task { @MainActor in manager.updateWatchAppInstalled(installed) }
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
