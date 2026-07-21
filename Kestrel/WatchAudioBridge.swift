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
        if let error { Log.error("WCSession activation error: \(error)") }
        refreshWatchAppInstalled(session)
        pushRecordingAuthorized()
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
        pushRecordingAuthorized()
    }

    /// Pushes the phone's current recording-authorization state to the watch via
    /// the persisted application context. Sent as a tri-state (authorized / denied
    /// / undetermined) so the watch can tell a genuine denial — which it shows as a
    /// gray lock the user must fix on the phone — apart from permissions that simply
    /// haven't been requested yet, where it keeps a normal record button rather than
    /// a confusing lock. `updateApplicationContext` only re-delivers on a changed
    /// payload, so this is cheap to call on every authorization change and
    /// session/watch-state event.
    func pushRecordingAuthorized() {
        Task { @MainActor in
            let state = manager.recordingAuthorizationStateForWatch
            // Merge through the manager's single application-context owner so this
            // doesn't clobber the now-hearing bird the manager also publishes there
            // (`updateApplicationContext` replaces the whole dictionary).
            manager.mergeWatchAppContext(["recordingAuthState": state.rawValue])
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
        case "watchLocation":
            // The watch supplied its own GPS for this session so the phone can
            // build the nearby-species filter from where the watch is.
            if let lat = payload["lat"] as? Double, let lon = payload["lon"] as? Double {
                Task { @MainActor in manager.updateWatchLocation(lat: lat, lon: lon) }
            }
        case "watchPing":
            // The watch's heartbeat has been quiet long enough to worry it and
            // it's asking us to prove we're still here before it tears the
            // session down. Answer immediately rather than waiting for the next
            // scheduled beat.
            Task { @MainActor in manager.answerWatchPing() }
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

    /// Ships the species' 320px thumbnail (already a JPEG on the CDN/disk) to the
    /// watch. Payloads are only a few KB, and the watch caches what it receives,
    /// so each species is normally sent only once.
    ///
    /// Prefers a live `sendMessage` when the watch is reachable, falling back to
    /// the background-tolerant `transferUserInfo` otherwise (or if the live send
    /// errors). This ordering matters in the watchOS **simulator**, where the
    /// background `transferUserInfo` queue is silently dropped and never
    /// delivered — the live message is the only channel that works there. On a
    /// real, possibly-backgrounded watch, `transferUserInfo` remains the
    /// reliable path. The watch handles the image identically from either
    /// channel (see `WatchSessionManager.route`).
    private func sendWatchImage(for scientificName: String) {
        Task.detached(priority: .utility) {
            // The 320px thumbnail bytes, straight from the store (disk, else
            // fetched jumping the prefetch queue) — no downscaling or re-encoding
            // on the phone. The watch caches and decodes them itself.
            guard let data = await RemoteSpeciesImageStore.shared.thumbnailData(for: scientificName) else {
                return
            }
            let session = WCSession.default
            guard session.activationState == .activated else { return }
            let payload: [String: Any] = ["imageFor": scientificName, "image": data]
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil, errorHandler: { _ in
                    WCSession.default.transferUserInfo(payload)
                })
            } else {
                session.transferUserInfo(payload)
            }
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
