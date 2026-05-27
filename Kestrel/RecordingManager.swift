import AVFoundation
import CoreLocation
import Foundation
import Observation
import SwiftUI
import WatchConnectivity

@Observable
@MainActor
final class RecordingManager {
    private(set) var isRecording = false
    /// True while audio is being streamed in from the Apple Watch companion.
    /// The Identify view disables its own record button while this is true.
    private(set) var watchRecording = false
    private(set) var detections: [Detection] = []
    private(set) var errorMessage: String?
    private(set) var locationStatus: String?
    /// IDs (scientific names) of detections whose confidence was just upgraded;
    /// the UI flashes their row yellow while they're in this set.
    private(set) var flashIDs: Set<String> = []
    /// Scientific names already in the life list when this recording session
    /// began. Used both by the UI (to decide which rows get the purple tint)
    /// and by `process(window:)` (to color the spectrogram detection band
    /// purple instead of goldenrod). Captured by the view via
    /// `snapshotLifeList(_:)` on the false → true transition of `isRecording`.
    private(set) var lifeListSnapshot: Set<String> = []
    /// Live set of scientific names the user has starred. The Identify UI
    /// pushes this in via `updateStarred(_:)` whenever the life list changes,
    /// so notifications/highlighting react to mid-session star toggles instead
    /// of being frozen to a snapshot.
    private(set) var starredNames: Set<String> = []

    /// Pushed from `KestrelApp`'s tab + scene-phase observers. When false,
    /// new-species events fire a local notification instead of relying on
    /// the in-app UI.
    var spectrogramVisible: Bool = true

    let spectrogram = SpectrogramRenderer()

    private let pipeline = AudioPipeline()
    private let locationProvider = LocationProvider()
    private var classifierTask: Task<BirdNETClassifier, Error>?
    private var rangeFilterTask: Task<SpeciesRangeFilter, Error>?
    private var allowedIndices: Set<Int>?
    private var detectionMap: [String: Detection] = [:]
    /// Per-species timestamp of the last visual flash; used to enforce a
    /// 5-second cooldown so a species doesn't strobe on every overlapping
    /// 1.5 s window of inference.
    private var lastFlashAt: [String: Date] = [:]
    /// Last time each species was heard. A species becomes eligible for a
    /// fresh notification + haptic once it's been silent for the cooldown
    /// window (30 s), letting a bird that comes back later re-fire instead
    /// of staying muted for the rest of the session.
    private var lastHeardAt: [String: Date] = [:]
    private let notifyCooldown: TimeInterval = 30
    /// Tracks the deferred audio engine start/stop task so rapid taps can
    /// cancel a pending transition before its sleep elapses.
    private var pendingTransitionTask: Task<Void, Never>?
    private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?

    // Watch-audio ingestion state. Samples arrive 16 kHz Float mono from the
    // watch; we upsample to 48 kHz via linear interpolation, hand them to the
    // spectrogram, and accumulate into BirdNET-sized windows.
    private var watchWindowBuffer: [Float] = []
    private var watchLastSample: Float = 0
    /// Silent-audio playback used to keep the iOS app alive in the
    /// background while the watch is the audio source.
    private let watchKeepalive = BackgroundAudioKeepalive()
    /// Periodically checks whether audio is still flowing from the watch.
    /// If a generous gap elapses with no chunks, we assume the link
    /// dropped (out of range, watch crashed) and notify the user.
    private var watchHeartbeatTask: Task<Void, Never>?
    /// Timestamp of the most recent audio chunk delivered by the watch.
    private var lastWatchAudioAt: Date?
    private let watchDisconnectThreshold: TimeInterval = 60

    /// Watchdog that auto-stops the recording once the session goes 30 min
    /// without any detection. Reset each time `merge(_:)` sees at least one
    /// result; armed in `startLocally`/`startFromWatch`; cancelled in `stop`/
    /// `stopFromWatch`.
    private var idleTerminationTask: Task<Void, Never>?
    private var lastDetectionAt: Date?
    private let idleTerminationThreshold: TimeInterval = 30 * 60

    init() {
        registerInterruptionObserver()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// Begins loading the BirdNET classifier and the species-range model in
    /// background tasks so the first Start Recording tap is fast. Safe to call
    /// multiple times; subsequent calls are no-ops.
    func preload() {
        if classifierTask == nil {
            classifierTask = Task.detached(priority: .userInitiated) {
                try BirdNETClassifier()
            }
        }
        if rangeFilterTask == nil {
            rangeFilterTask = Task.detached(priority: .utility) {
                try SpeciesRangeFilter()
            }
        }

        // Pre-warm the audio pipeline in the background. Runs at .userInitiated
        // so it doesn't get scheduled behind the classifier load on the
        // executor; pipeline.start() awaits this task before activating the
        // session itself, so the two can't race on the shared AVAudioSession.
        pipeline.startPrewarm()

        // Kick off the location/range-filter lookup at launch so the
        // "Filtered to N species" caption is ready to fade in before the
        // user taps Start Recording, instead of appearing mid-session and
        // shoving the record button down.
        if locationStatus == nil {
            Task { await self.refreshSpeciesFilter() }
        }
    }

    func toggle() async {
        if watchRecording {
            // Active session was started on / for the watch — ask the watch
            // to stop. It'll tear down its streamer + ERS and send back a
            // "stop" handshake that flips our state.
            stopWatchSession()
        } else if isRecording {
            stop()
        } else {
            await start()
        }
    }

    /// Try to start the recording on the paired Apple Watch. If the watch
    /// isn't paired / installed / currently reachable, fall back to the
    /// local mic so the user always gets *something* on tap.
    func start() async {
        if let watch = preferredWatchSession {
            // Optimistic — we don't wait for the watch's handshake before
            // returning. The watch will echo "start" back via its normal
            // path, which flips `watchRecording = true` and updates the UI.
            watch.sendMessage(["cmd": "remoteStart"], replyHandler: nil) { [weak self] _ in
                // sendMessage failed mid-flight (watch slipped out of
                // reachability). Recover by starting locally.
                Task { @MainActor [weak self] in
                    await self?.startLocally()
                }
            }
            return
        }
        await startLocally()
    }

    /// `WCSession.default` only if a watch companion is currently available
    /// for live messaging. We don't bother trying to wake the watch from
    /// suspension via transferUserInfo here — the local mic is a fine
    /// fallback and tapping the watch button later still works.
    private var preferredWatchSession: WCSession? {
        guard WCSession.isSupported() else { return nil }
        let s = WCSession.default
        guard s.activationState == .activated,
              s.isPaired,
              s.isWatchAppInstalled,
              s.isReachable else { return nil }
        return s
    }

    /// Send a haptic kind to the watch. Live `sendMessage` is the fast
    /// path when the watch app is foreground; `transferUserInfo` is the
    /// background fallback — it queues and can wake a suspended watch app
    /// to deliver the haptic. There's modest latency (1–5 s) over that
    /// path, but a slightly-late wrist tap is better than none.
    private func sendHapticToWatch(reason: SpeciesNotifications.Reason) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated,
              s.isPaired,
              s.isWatchAppInstalled else { return }
        let kind: String
        switch reason {
        case .starred:    kind = "starred"
        case .newSpecies: kind = "newSpecies"
        }
        if s.isReachable {
            s.sendMessage(["haptic": kind], replyHandler: nil, errorHandler: nil)
        } else {
            s.transferUserInfo(["haptic": kind])
        }
    }

    private func stopWatchSession() {
        let s = WCSession.default
        s.sendMessage(["cmd": "remoteStop"], replyHandler: nil, errorHandler: nil)
        s.transferUserInfo(["cmd": "remoteStop"])
        // Don't flip `watchRecording` here — the watch sends "stop" back
        // through its normal channel and we let that update our state, so
        // the UI matches reality even if the remote tear-down is slow.
    }

    func startLocally() async {
        // If a pending stop task is in its post-animation sleep, drop it before
        // we kick off a fresh start. Same applies the other direction.
        pendingTransitionTask?.cancel()
        pendingTransitionTask = nil

        guard !isRecording else { return }

        // If the engine is still running because we just cancelled a pending
        // stop task before it could fire pipeline.stop, this is a "resume" of
        // the same recording, not a fresh one. Flip the UI flag back and bail
        // — re-running pipeline.start on an already-running engine causes the
        // tap to be re-installed and audio to double-process.
        if pipeline.isRunning {
            isRecording = true
            return
        }

        errorMessage = nil

        guard await requestMicrophonePermission() else {
            errorMessage = "Microphone permission denied."
            return
        }

        detections = []
        detectionMap = [:]
        flashIDs = []
        lastFlashAt = [:]
        spectrogram.reset()
        // Don't clear locationStatus — leave the previous filter visible until
        // refreshSpeciesFilter overwrites it, otherwise the text flickers.
        isRecording = true

        // Audio engine startup secretly uses main-thread time even when called
        // from a detached task (AVAudioEngine posts route-change callbacks to
        // main during first activation). Letting it run concurrently with the
        // button morph animation freezes the UI for ~200 ms. We defer the
        // engine start until just after the animation has committed.
        let pipeline = self.pipeline
        let spectrogram = self.spectrogram
        pendingTransitionTask = Task.detached(priority: .userInitiated) { [weak self] in
            await pipeline.awaitPrewarm()
            // Wait out the morph animation. Cancel-aware sleep so a rapid
            // tap that flips us back to stop can short-circuit this task.
            do {
                try await Task.sleep(for: .milliseconds(280))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                try pipeline.start(
                    onWindow: { window in
                        Task { @MainActor [weak self] in
                            await self?.process(window: window)
                        }
                    },
                    onChunk: { chunk in
                        spectrogram.ingest(chunk)
                    }
                )
            } catch {
                await MainActor.run {
                    self?.errorMessage = "Failed to start audio: \(error.localizedDescription)"
                    self?.isRecording = false
                }
                print("Kestrel: failed to start pipeline — \(error)")
            }
        }

        preload()
        Task { await self.refreshSpeciesFilter() }
        startIdleWatchdog()
    }

    func stop() {
        pendingTransitionTask?.cancel()
        pendingTransitionTask = nil
        cancelIdleWatchdog()

        guard isRecording else { return }
        isRecording = false

        // If the engine never actually started (we cancelled a pending start
        // task before its 280ms sleep elapsed), there's nothing to tear down.
        guard pipeline.isRunning else { return }

        // engine.stop() + setActive(false) tax main internally during teardown.
        // Defer until after the SwiftUI morph animation has committed so the
        // button transition feels instant.
        let pipeline = self.pipeline
        pendingTransitionTask = Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(for: .milliseconds(280))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            pipeline.stop()
        }
    }

    // MARK: - Watch audio ingestion

    /// Called when the watch sends a "start" handshake. Resets per-session
    /// state the same way `start()` does but skips the local AVAudioEngine —
    /// the watch is the audio source now.
    func startFromWatch() async {
        pendingTransitionTask?.cancel()
        pendingTransitionTask = nil

        // If a phone-driven recording is already running, don't clobber it.
        if isRecording && !watchRecording { return }
        guard !watchRecording else { return }

        errorMessage = nil
        detections = []
        detectionMap = [:]
        flashIDs = []
        lastFlashAt = [:]
        watchWindowBuffer.removeAll(keepingCapacity: true)
        watchLastSample = 0
        spectrogram.reset()

        isRecording = true
        watchRecording = true

        // Activate the silent-audio keepalive so iOS doesn't suspend us
        // if the user puts the phone away mid-session.
        watchKeepalive.start()

        lastWatchAudioAt = Date()
        startWatchLifecycleWatchdogs()

        preload()
        Task { await self.refreshSpeciesFilter() }
        startIdleWatchdog()
    }

    /// Called when the watch sends a "stop" handshake.
    func stopFromWatch() {
        guard watchRecording else { return }
        watchRecording = false
        isRecording = false
        watchWindowBuffer.removeAll(keepingCapacity: true)
        watchKeepalive.stop()
        cancelWatchLifecycleWatchdogs()
        cancelIdleWatchdog()
    }

    // MARK: - Idle auto-termination

    private func startIdleWatchdog() {
        idleTerminationTask?.cancel()
        lastDetectionAt = Date()
        idleTerminationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                let shouldStop = await self.checkIdleAndMaybeStop()
                if shouldStop { return }
            }
        }
    }

    private func cancelIdleWatchdog() {
        idleTerminationTask?.cancel()
        idleTerminationTask = nil
        lastDetectionAt = nil
    }

    /// Returns true if the watchdog tore the session down and the polling
    /// loop should exit.
    private func checkIdleAndMaybeStop() -> Bool {
        guard isRecording, let last = lastDetectionAt else { return true }
        let gap = Date().timeIntervalSince(last)
        guard gap >= idleTerminationThreshold else { return false }

        Task {
            await SpeciesNotifications.shared.notifySessionLifecycle(
                title: "Kestrel",
                body: "No birds heard for 30 minutes — recording stopped."
            )
        }
        if watchRecording {
            stopWatchSession()
        } else {
            stop()
        }
        return true
    }

    private func startWatchLifecycleWatchdogs() {
        watchHeartbeatTask?.cancel()
        watchHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                let stillAlive = await self.checkWatchHeartbeat()
                if !stillAlive { return }
            }
        }
    }

    private func cancelWatchLifecycleWatchdogs() {
        watchHeartbeatTask?.cancel()
        watchHeartbeatTask = nil
        lastWatchAudioAt = nil
    }

    /// Returns false once it tears the session down so the caller can exit
    /// its polling loop. Returns true while everything looks healthy.
    private func checkWatchHeartbeat() -> Bool {
        guard watchRecording, let last = lastWatchAudioAt else { return false }
        let gap = Date().timeIntervalSince(last)
        guard gap >= watchDisconnectThreshold else { return true }
        // Sync watch state so it stops claiming "recording" while we've
        // already given up on it. sendMessage covers the live path;
        // transferUserInfo queues for delivery if the watch is currently
        // unreachable, which is exactly the case that tripped this branch.
        let s = WCSession.default
        if s.activationState == .activated {
            s.sendMessage(["cmd": "remoteStop"], replyHandler: nil, errorHandler: nil)
            s.transferUserInfo(["cmd": "remoteStop"])
        }
        Task {
            await SpeciesNotifications.shared.notifySessionLifecycle(
                title: "Kestrel",
                body: "Watch disconnected. Re-tap the watch button to keep listening."
            )
        }
        stopFromWatch()
        return false
    }

    /// Ingest a chunk of 16 kHz mono Float samples from the watch.
    /// Linear-interpolation 3× upsample to 48 kHz, feed the spectrogram,
    /// then slice into BirdNET windows and dispatch inference.
    func ingestWatchSamples16k(_ samples16k: [Float]) {
        guard watchRecording, !samples16k.isEmpty else { return }
        lastWatchAudioAt = Date()

        // 3× linear upsample: between each input sample we emit two
        // interpolated samples. Carries `watchLastSample` across chunks so
        // we don't introduce a discontinuity at chunk boundaries.
        var upsampled = [Float]()
        upsampled.reserveCapacity(samples16k.count * 3)
        var prev = watchLastSample
        for s in samples16k {
            upsampled.append(prev)
            upsampled.append(prev + (s - prev) * (1.0 / 3.0))
            upsampled.append(prev + (s - prev) * (2.0 / 3.0))
            prev = s
        }
        watchLastSample = prev

        spectrogram.ingest(upsampled)

        watchWindowBuffer.append(contentsOf: upsampled)
        while watchWindowBuffer.count >= AudioPipeline.windowSamples {
            let window = Array(watchWindowBuffer.prefix(AudioPipeline.windowSamples))
            watchWindowBuffer.removeFirst(AudioPipeline.hopSamples)
            Task { await self.process(window: window) }
        }
    }

    // MARK: - Model accessors

    private func getClassifier() async -> BirdNETClassifier? {
        if classifierTask == nil { preload() }
        do {
            return try await classifierTask?.value
        } catch {
            errorMessage = "Failed to load BirdNET: \(error.localizedDescription)"
            print("Kestrel: classifier load — \(error)")
            return nil
        }
    }

    private func getRangeFilter() async -> SpeciesRangeFilter? {
        if rangeFilterTask == nil { preload() }
        do {
            return try await rangeFilterTask?.value
        } catch {
            print("Kestrel: range filter unavailable — \(error)")
            return nil
        }
    }

    // MARK: - Per-window inference

    private func process(window: [Float]) async {
        guard let classifier = await getClassifier() else { return }
        do {
            let results = try await classifier.classify(window, allowedIndices: allowedIndices)
            if !results.isEmpty {
                // Tint priority within a single window: starred > needs-add
                // > known lifer. Picks the most attention-grabbing color
                // when multiple species overlap on the same band.
                let kind: SpectrogramRenderer.TintKind
                if results.contains(where: { starredNames.contains($0.scientificName) }) {
                    kind = .starred
                } else if results.contains(where: { !lifeListSnapshot.contains($0.scientificName) }) {
                    kind = .needsAdd
                } else {
                    kind = .lifer
                }
                spectrogram.markDetection(kind: kind)
            }
            await MainActor.run { self.merge(results) }
        } catch {
            print("Kestrel: inference error — \(error)")
        }
    }

    /// Captures the set of life-list scientific names at the moment a new
    /// recording session starts. The UI calls this on the false → true
    /// transition of `isRecording`.
    func snapshotLifeList(_ scientificNames: Set<String>) {
        lifeListSnapshot = scientificNames
    }

    /// Live mirror of the user's starred species. Unlike `lifeListSnapshot`
    /// this is *not* frozen at session start — toggling a star mid-session
    /// should immediately change which detections fire notifications and
    /// which spectrogram bands get the blue tint.
    func updateStarred(_ scientificNames: Set<String>) {
        starredNames = scientificNames
    }

    private func merge(_ results: [Detection]) {
        // Flash any repeat match (regardless of confidence change), but
        // enforce a per-species cooldown so the same row doesn't strobe on
        // every overlapping inference window.
        let now = Date()
        if !results.isEmpty { lastDetectionAt = now }
        let cooldown: TimeInterval = 5
        var repeatedIDs: [String] = []
        // Detections that should fire a notification + haptic this batch:
        // species heard with no detection in the last `notifyCooldown` s.
        var notifications: [(common: String, scientific: String, reason: SpeciesNotifications.Reason)] = []
        for d in results {
            if let existing = detectionMap[d.id] {
                if d.confidence > existing.confidence {
                    detectionMap[d.id] = d  // takes new confidence + new lastSeen
                } else {
                    var updated = existing
                    updated.lastSeen = d.lastSeen
                    detectionMap[d.id] = updated
                }
                let lastFlash = lastFlashAt[d.id]
                if lastFlash == nil || now.timeIntervalSince(lastFlash!) >= cooldown {
                    repeatedIDs.append(d.id)
                    lastFlashAt[d.id] = now
                }
            } else {
                detectionMap[d.id] = d
            }

            // Notify when (a) the species is interesting (starred or
            // not-yet-in-life-list), and (b) it hasn't been heard for at
            // least `notifyCooldown` seconds. The clock resets on every
            // detection, so a continuously-singing bird only triggers
            // once; a bird that goes silent and returns re-fires.
            let isStarred = starredNames.contains(d.scientificName)
            let isNew = !lifeListSnapshot.contains(d.scientificName)
            if isStarred || isNew {
                let last = lastHeardAt[d.scientificName]
                if last == nil || now.timeIntervalSince(last!) >= notifyCooldown {
                    let reason: SpeciesNotifications.Reason = isStarred ? .starred : .newSpecies
                    notifications.append((d.commonName, d.scientificName, reason))
                }
            }
            lastHeardAt[d.scientificName] = now
        }

        // Only surface to the user when the Identify spectrogram isn't on
        // screen — otherwise the visible rows already convey it.
        if !spectrogramVisible {
            for item in notifications {
                Task {
                    await SpeciesNotifications.shared.notifyNewSpecies(
                        commonName: item.common,
                        scientificName: item.scientific,
                        reason: item.reason
                    )
                }
            }
        }
        // Haptics fire regardless of which device the user is currently
        // looking at — the wrist tap is the whole point of the watch app.
        for item in notifications {
            sendHapticToWatch(reason: item.reason)
        }

        for id in repeatedIDs {
            flashIDs.insert(id)
        }

        // Sort by lastSeen so the most recently heard species is always at
        // the top. Reorder is animated so rows visibly slide into place.
        withAnimation(.easeInOut(duration: 0.3)) {
            detections = detectionMap.values.sorted { $0.lastSeen > $1.lastSeen }
        }

        for id in repeatedIDs {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                await MainActor.run { _ = self?.flashIDs.remove(id) }
            }
        }
    }

    // MARK: - Location + species filter

    private func refreshSpeciesFilter() async {
        guard let rangeFilter = await getRangeFilter() else {
            allowedIndices = nil
            locationStatus = "Showing all species"
            return
        }
        let location = await locationProvider.currentLocation()
        let week = SpeciesRangeFilter.birdnetWeek()
        if let location {
            do {
                let allowed = try await rangeFilter.computeAndCache(
                    lat: location.coordinate.latitude,
                    lon: location.coordinate.longitude,
                    week: week
                )
                allowedIndices = allowed
                locationStatus = "Filtered to \(allowed.count) nearby species"
                return
            } catch {
                print("Kestrel: geo inference failed — \(error)")
            }
        }
        if let cached = await rangeFilter.loadCached() {
            allowedIndices = cached
            locationStatus = "Using last-known list (\(cached.count) species)"
        } else {
            allowedIndices = nil
            locationStatus = "Showing all species (no location yet)"
        }
    }

    // MARK: - System plumbing

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    private func registerInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                self.handleInterruption(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            if isRecording { pipeline.stop(); isRecording = false }
        case .ended:
            break
        @unknown default:
            break
        }
    }
}
