import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class RecordingManager {
    private(set) var isRecording = false
    private(set) var detections: [Detection] = []
    private(set) var errorMessage: String?

    private let pipeline = AudioPipeline()
    private var classifier: BirdNETClassifier?
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

        detections = []
        detectionMap = [:]

        do {
            try pipeline.start { [weak self] window in
                guard let self else { return }
                Task { await self.process(window: window) }
            }
            isRecording = true
        } catch {
            errorMessage = "Failed to start audio: \(error.localizedDescription)"
            print("Kestrel: failed to start pipeline — \(error)")
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
            let results = try await classifier.classify(window)
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
