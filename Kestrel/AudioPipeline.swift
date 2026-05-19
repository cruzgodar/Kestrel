import AVFoundation
import Foundation
import os

/// Captures microphone audio, resamples to 48 kHz mono Float32, and emits
/// non-overlapping 3-second windows (144,000 samples) suitable for BirdNET.
final class AudioPipeline {
    static let targetSampleRate: Double = 48_000
    static let windowSamples: Int = 144_000      // 3 s @ 48 kHz — BirdNET's input length
    static let hopSamples: Int = 72_000          // 1.5 s — 50% overlap so songs aren't bisected

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
    private var onChunk: (@Sendable ([Float]) -> Void)?

    var isRunning: Bool { engine.isRunning }

    func start(
        onWindow: @escaping @Sendable ([Float]) -> Void,
        onChunk: (@Sendable ([Float]) -> Void)? = nil
    ) throws {
        self.onWindow = onWindow
        self.onChunk = onChunk

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true, options: [])

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)

        // Reset converter when format changes.
        converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        converterInputFormat = hwFormat

        bufferLock.withLock { $0.removeAll(keepingCapacity: true) }

        // Small buffer = frequent callbacks → smooth spectrogram updates.
        // The system may still coalesce; this is advisory.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 256, format: hwFormat) { [weak self] buffer, _ in
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
        onChunk = nil
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

        // Forward to the spectrogram renderer (if any) before chunking into windows.
        onChunk?(newSamples)

        // Append, slice off complete windows, deliver each. We advance by `hopSamples`
        // rather than `windowSamples` so consecutive windows overlap (50%) — a song
        // that lands across a window boundary still gets one window centered on it.
        var completed: [[Float]] = []
        bufferLock.withLock { storage in
            storage.append(contentsOf: newSamples)
            while storage.count >= AudioPipeline.windowSamples {
                let window = Array(storage.prefix(AudioPipeline.windowSamples))
                storage.removeFirst(AudioPipeline.hopSamples)
                completed.append(window)
            }
        }

        if let onWindow {
            for window in completed { onWindow(window) }
        }
    }
}
