import AVFoundation
import CoreLocation
import Foundation
import Observation
import SwiftUI

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
    /// Tracks the deferred audio engine start/stop task so rapid taps can
    /// cancel a pending transition before its sleep elapses.
    private var pendingTransitionTask: Task<Void, Never>?
    private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?

    // Watch-audio ingestion state. Samples arrive 16 kHz Float mono from the
    // watch; we upsample to 48 kHz via linear interpolation, hand them to the
    // spectrogram, and accumulate into BirdNET-sized windows.
    private var watchWindowBuffer: [Float] = []
    private var watchLastSample: Float = 0

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
        if isRecording {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
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
    }

    func stop() {
        pendingTransitionTask?.cancel()
        pendingTransitionTask = nil

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

        preload()
        Task { await self.refreshSpeciesFilter() }
    }

    /// Called when the watch sends a "stop" handshake.
    func stopFromWatch() {
        guard watchRecording else { return }
        watchRecording = false
        isRecording = false
        watchWindowBuffer.removeAll(keepingCapacity: true)
    }

    /// Ingest a chunk of 16 kHz mono Float samples from the watch.
    /// Linear-interpolation 3× upsample to 48 kHz, feed the spectrogram,
    /// then slice into BirdNET windows and dispatch inference.
    func ingestWatchSamples16k(_ samples16k: [Float]) {
        guard watchRecording, !samples16k.isEmpty else { return }

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
        let cooldown: TimeInterval = 5
        var repeatedIDs: [String] = []
        // Species heard for the first time this session — used to fire local
        // notifications when the spectrogram isn't visible.
        var newlyDetected: [(scientific: String, common: String)] = []
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
                newlyDetected.append((d.scientificName, d.commonName))
            }
        }

        // If the user isn't currently looking at the Identify spectrogram,
        // surface notifications for two cases: starred species (always
        // interesting) and species not yet on the life list (a potential
        // lifer). Starred wins when both apply.
        if !spectrogramVisible {
            for species in newlyDetected {
                let isStarred = starredNames.contains(species.scientific)
                let isNew = !lifeListSnapshot.contains(species.scientific)
                guard isStarred || isNew else { continue }
                let reason: SpeciesNotifications.Reason = isStarred ? .starred : .newSpecies
                Task {
                    await SpeciesNotifications.shared.notifyNewSpecies(
                        commonName: species.common,
                        scientificName: species.scientific,
                        reason: reason
                    )
                }
            }
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
