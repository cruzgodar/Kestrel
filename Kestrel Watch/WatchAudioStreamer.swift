import AVFoundation
import Foundation

/// Captures mic audio on the watch, converts it to 16 kHz mono Int16, and
/// emits ~200 ms chunks for transport to the paired iPhone.
///
/// Bandwidth: 16 kHz × 2 B = 32 KB/s — comfortable for WCSession's live
/// `sendMessageData` channel. The phone upsamples to 48 kHz before feeding
/// the existing BirdNET windowing pipeline.
///
/// `@unchecked Sendable`: `start()`/`stop()` are the only externally-mutating
/// entry points and the manager never runs them concurrently (a session is
/// fully started before it can be stopped, and the auto-restart cycle stops
/// then starts sequentially). This lets the manager dispatch the blocking
/// `start()` off the main actor so the UI can animate while audio spins up.
final class WatchAudioStreamer: @unchecked Sendable {
    static let targetSampleRate: Double = 16_000
    /// 3200 samples @ 16 kHz = 200 ms per chunk → 5 messages/sec.
    static let chunkSamples: Int = 3_200

    private let engine = AVAudioEngine()

    private let targetFormat: AVAudioFormat = {
        guard let f = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: WatchAudioStreamer.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else { fatalError("Failed to build target audio format") }
        return f
    }()

    private var converter: AVAudioConverter?
    private var onChunk: ((Data) -> Void)?
    private var buffer: [Int16] = []

    /// - Parameter useBackgroundEntitlement: when true, configures the session
    ///   as `.playAndRecord` so it can keep capturing under the declared `audio`
    ///   background mode (which depends on the background-audio entitlement).
    ///   When false, uses plain `.record`, which only keeps running while the
    ///   app is in the foreground or inside an extended runtime session.
    func start(useBackgroundEntitlement: Bool, onChunk: @escaping (Data) -> Void) throws {
        self.onChunk = onChunk
        buffer.removeAll(keepingCapacity: true)

        let session = AVAudioSession.sharedInstance()
        if useBackgroundEntitlement {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
        } else {
            try session.setCategory(.record, mode: .measurement, options: [])
        }
        try session.setActive(true, options: [])

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buf, _ in
            self?.handleTap(buf)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        onChunk = nil
        buffer.removeAll(keepingCapacity: true)
    }

    private func handleTap(_ inBuf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / inBuf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return inBuf
        }
        if status == .error {
            if let convError { print("WatchAudioStreamer: convert error \(convError)") }
            return
        }

        let frames = Int(out.frameLength)
        guard frames > 0, let ptr = out.int16ChannelData?[0] else { return }

        buffer.append(contentsOf: UnsafeBufferPointer(start: ptr, count: frames))

        while buffer.count >= Self.chunkSamples {
            let chunk = Array(buffer.prefix(Self.chunkSamples))
            buffer.removeFirst(Self.chunkSamples)
            let data = chunk.withUnsafeBufferPointer { Data(buffer: $0) }
            onChunk?(data)
        }
    }
}
