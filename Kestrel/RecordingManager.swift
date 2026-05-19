import AVFoundation
import CoreLocation
import Foundation
import Observation

@Observable
@MainActor
final class RecordingManager {
    private(set) var isRecording = false
    private(set) var detections: [Detection] = []
    private(set) var errorMessage: String?
    private(set) var locationStatus: String?

    let spectrogram = SpectrogramRenderer()

    private let pipeline = AudioPipeline()
    private let locationProvider = LocationProvider()
    private var classifierTask: Task<BirdNETClassifier, Error>?
    private var rangeFilterTask: Task<SpeciesRangeFilter, Error>?
    private var allowedIndices: Set<Int>?
    private var detectionMap: [String: Detection] = [:]
    private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?

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
    }

    func toggle() async {
        PerfLog.log("toggle() entry")
        if isRecording {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        PerfLog.log("start() entry")
        guard !isRecording else { return }
        errorMessage = nil

        PerfLog.log("requesting mic permission")
        guard await requestMicrophonePermission() else {
            errorMessage = "Microphone permission denied."
            return
        }
        PerfLog.log("mic permission granted")

        detections = []
        detectionMap = [:]
        spectrogram.reset()
        locationStatus = nil
        isRecording = true
        PerfLog.log("isRecording = true SET")

        // Spin up the audio engine off the main actor. AVAudioSession.setActive
        // and AVAudioEngine.start collectively take ~100–300 ms; blocking main
        // for that long would freeze the button morph animation. Also wait
        // for any prewarm in flight so we don't contend for the audio session.
        let pipeline = self.pipeline
        let spectrogram = self.spectrogram
        Task.detached(priority: .userInitiated) { [weak self] in
            PerfLog.log("detached task running")
            await pipeline.awaitPrewarm()
            PerfLog.log("prewarm awaited")
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
                PerfLog.log("pipeline.start returned")
            } catch {
                await MainActor.run {
                    self?.errorMessage = "Failed to start audio: \(error.localizedDescription)"
                    self?.isRecording = false
                }
                print("Kestrel: failed to start pipeline — \(error)")
            }
        }
        PerfLog.log("start() returning to caller")

        preload()
        Task { await self.refreshSpeciesFilter() }
    }

    func stop() {
        guard isRecording else { return }
        // Flip UI state synchronously; tear down audio engine off-main so the
        // 100+ ms engine.stop / setActive(false) calls don't block the morph.
        isRecording = false
        let pipeline = self.pipeline
        Task.detached(priority: .userInitiated) {
            pipeline.stop()
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
                spectrogram.markDetection()
            }
            await MainActor.run { self.merge(results) }
        } catch {
            print("Kestrel: inference error — \(error)")
        }
    }

    private func merge(_ results: [Detection]) {
        var changed = false
        for d in results {
            if let existing = detectionMap[d.id] {
                if d.confidence > existing.confidence {
                    detectionMap[d.id] = d
                    changed = true
                } else {
                    var updated = existing
                    updated.lastSeen = d.lastSeen
                    detectionMap[d.id] = updated
                }
            } else {
                detectionMap[d.id] = d
                changed = true
            }
        }
        if changed || detections.count != detectionMap.count {
            detections = detectionMap.values.sorted { $0.confidence > $1.confidence }
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
