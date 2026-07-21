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
/// fully started before it can be stopped). This lets the manager dispatch the
/// blocking `start()` off the main actor so the UI can animate while audio
/// spins up.
final class WatchAudioStreamer: @unchecked Sendable {
    static let targetSampleRate: Double = 16_000
    /// 8000 samples @ 16 kHz = 500 ms per chunk → 2 messages/sec.
    ///
    /// Was 200 ms / 5 messages a second. Each `sendMessageData` is a full IPC +
    /// Bluetooth round trip, and watchOS suspends a backgrounded app that averages
    /// over ~15% CPU across a minute — the ceiling a multi-hour birding session
    /// has to live under. Halving-and-then-some the message rate is the single
    /// cheapest win available; the cost is 300 ms more latency to the now-hearing
    /// display, invisible against BirdNET's 3-second analysis window.
    static let chunkSamples: Int = 8_000

    /// Frames per input tap. At a 48 kHz hardware rate the old 1024 meant ~47
    /// converter invocations a second; 4800 makes it ~10 for the same audio, with
    /// the buffering that used to happen downstream now happening in the tap.
    private static let tapBufferSize: AVAudioFrameCount = 4_800

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

    /// Configures a plain `.record` session. Background capture (wrist-down,
    /// screen off) is kept alive by the outdoor-walk `HKWorkoutSession` that
    /// `WatchSessionManager` runs for the duration of a recording (see
    /// `WatchWorkoutManager`); without an active workout the watch only captures
    /// while its app is frontmost.
    func start(onChunk: @escaping (Data) -> Void) throws {
        self.onChunk = onChunk
        buffer.removeAll(keepingCapacity: true)

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true, options: [])

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: hwFormat) { [weak self] buf, _ in
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
            if let convError { Log.error("WatchAudioStreamer: convert error \(convError)") }
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
