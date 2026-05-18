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
    private var classifier: BirdNETClassifier?
    private var rangeFilter: SpeciesRangeFilter?
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

    func toggle() async {
        if isRecording {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil

        guard await requestMicrophonePermission() else {
            errorMessage = "Microphone permission denied."
            return
        }

        if classifier == nil {
            do {
                classifier = try BirdNETClassifier()
            } catch {
                errorMessage = "Failed to load BirdNET: \(error)"
                print("Kestrel: \(error)")
                return
            }
        }

        if rangeFilter == nil {
            do {
                rangeFilter = try SpeciesRangeFilter()
            } catch {
                print("Kestrel: range filter unavailable — \(error)")
            }
        }

        detections = []
        detectionMap = [:]
        spectrogram.reset()
        await refreshSpeciesFilter()

        do {
            let spectrogram = self.spectrogram
            try pipeline.start(
                onWindow: { [weak self] window in
                    guard let self else { return }
                    Task { await self.process(window: window) }
                },
                onChunk: { chunk in
                    spectrogram.ingest(chunk)
                }
            )
            isRecording = true
        } catch {
            errorMessage = "Failed to start audio: \(error.localizedDescription)"
            print("Kestrel: failed to start pipeline — \(error)")
        }
    }

    private func refreshSpeciesFilter() async {
        guard let rangeFilter else {
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
                locationStatus = "Filtered to \(allowed.count) species near you"
                return
            } catch {
                print("Kestrel: geo inference failed — \(error)")
            }
        }
        // Fallback path: no fresh fix, or geo inference failed.
        if let cached = await rangeFilter.loadCached() {
            allowedIndices = cached
            locationStatus = "Using last-known list (\(cached.count) species)"
        } else {
            allowedIndices = nil
            locationStatus = "Showing all species (no location yet)"
        }
    }

    func stop() {
        guard isRecording else { return }
        pipeline.stop()
        isRecording = false
    }

    private func process(window: [Float]) async {
        guard let classifier else { return }
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
            // User can tap record again — don't auto-resume the engine here.
            break
        @unknown default:
            break
        }
    }
}
