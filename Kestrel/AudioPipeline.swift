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
    private var highPass = BiquadHighPass(cutoffHz: 150, sampleRate: AudioPipeline.targetSampleRate)

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
        highPass.reset()

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

        var newSamples = Array(UnsafeBufferPointer(start: ptr, count: frames))
        // Remove low-frequency rumble (wind, footsteps, pocket thump) before BirdNET.
        // Filter state persists across taps so window boundaries are click-free.
        highPass.process(&newSamples)

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

/// Biquad Butterworth high-pass (RBJ cookbook, Q=1/√2). Stateful so it can be
/// called incrementally on consecutive buffers without introducing clicks at the
/// boundary.
struct BiquadHighPass {
    private let b0, b1, b2, a1, a2: Float
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    init(cutoffHz: Double, sampleRate: Double, q: Double = 0.7071067811865476) {
        let w0 = 2.0 * .pi * cutoffHz / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2.0 * q)
        let a0 = 1.0 + alpha
        let b0 = (1.0 + cosW0) / 2.0
        let b1 = -(1.0 + cosW0)
        let b2 = (1.0 + cosW0) / 2.0
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha
        self.b0 = Float(b0 / a0)
        self.b1 = Float(b1 / a0)
        self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0)
        self.a2 = Float(a2 / a0)
    }

    mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }

    mutating func process(_ samples: inout [Float]) {
        for i in 0..<samples.count {
            let x = samples[i]
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            samples[i] = y
        }
    }
}
