import AVFoundation
import Foundation
import os

/// Captures microphone audio, resamples to 48 kHz mono Float32, and emits
/// non-overlapping 3-second windows (144,000 samples) suitable for BirdNET.
final class AudioPipeline {
    static let targetSampleRate: Double = 48_000
    static let windowSamples: Int = 144_000

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat = {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioPipeline.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { fatalError("Failed to build target audio format") }
        return fmt
    }()

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    private let bufferLock = OSAllocatedUnfairLock(initialState: [Float]())
    private var onWindow: (@Sendable ([Float]) -> Void)?

    var isRunning: Bool { engine.isRunning }

    func start(onWindow: @escaping @Sendable ([Float]) -> Void) throws {
        self.onWindow = onWindow

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true, options: [])

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)

        // Reset converter when format changes.
        converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        converterInputFormat = hwFormat

        bufferLock.withLock { $0.removeAll(keepingCapacity: true) }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_800, format: hwFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        onWindow = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        // Estimate output capacity: ratio of sample rates × input frames + slack.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            if let convError { print("AudioPipeline: convert error \(convError)") }
            return
        }

        let frames = Int(outBuffer.frameLength)
        guard frames > 0, let ptr = outBuffer.floatChannelData?[0] else { return }

        let newSamples = Array(UnsafeBufferPointer(start: ptr, count: frames))

        // Append, slice off complete windows, deliver each.
        var completed: [[Float]] = []
        bufferLock.withLock { storage in
            storage.append(contentsOf: newSamples)
            while storage.count >= AudioPipeline.windowSamples {
                let window = Array(storage.prefix(AudioPipeline.windowSamples))
                storage.removeFirst(AudioPipeline.windowSamples)
                completed.append(window)
            }
        }

        if let onWindow {
            for window in completed { onWindow(window) }
        }
    }
}
