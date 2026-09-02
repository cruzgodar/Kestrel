import AVFoundation
import Foundation
import os

/// Captures mic audio on the watch, converts it to 16 kHz mono Int16, and
/// emits half-second chunks for transport to the paired iPhone (see
/// `chunkSamples`, which is what actually sets the rate).
///
/// Bandwidth: 16 kHz × 2 B = 32 KB/s — comfortable for WCSession's live
/// `sendMessageData` channel. The phone upsamples to 48 kHz before feeding
/// the existing BirdNET windowing pipeline.
///
/// `@unchecked Sendable`: `start()`/`stop()` are the only externally-mutating
/// entry points and the manager never runs them concurrently (a session is
/// fully started before it can be stopped). This lets the manager dispatch the
/// blocking `start()` off the main actor so the UI can animate while audio
/// spins up. The sample buffer they share with the audio render thread is
/// guarded by `bufferLock` — see `handleTap` and `stop`.
final class WatchAudioStreamer: @unchecked Sendable {
    // `nonisolated`, exactly as `AudioPipeline`'s equivalents are and for the same
    // reason: the project defaults to MainActor isolation, and these compile-time
    // constants are read from the audio tap's nonisolated closure — off the main
    // actor entirely. Without it `handleTap`'s read of `chunkSamples` warns today
    // and is an error under the Swift 6 language mode. Immutable value types, so
    // there is nothing to make safe.
    nonisolated static let targetSampleRate: Double = 16_000
    /// 8000 samples @ 16 kHz = 500 ms per chunk → 2 messages/sec.
    ///
    /// Was 200 ms / 5 messages a second. Each `sendMessageData` is a full IPC +
    /// Bluetooth round trip, and watchOS suspends a backgrounded app that averages
    /// over ~15% CPU across a minute — the ceiling a multi-hour birding session
    /// has to live under. Halving-and-then-some the message rate is the single
    /// cheapest win available; the cost is 300 ms more latency to the now-hearing
    /// display, invisible against BirdNET's 3-second analysis window.
    nonisolated static let chunkSamples: Int = 8_000

    /// Frames per input tap. At a 48 kHz hardware rate the old 1024 meant ~47
    /// converter invocations a second; 4800 makes it ~10 for the same audio, with
    /// the buffering that used to happen downstream now happening in the tap.
    private nonisolated static let tapBufferSize: AVAudioFrameCount = 4_800

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
    /// Accumulated 16 kHz samples awaiting a full chunk.
    ///
    /// Locked, because the audio render thread appends to it from `handleTap`
    /// while `start()` clears it from the manager's audio queue — and the
    /// watchdogs' `restartCapture` puts exactly those two a moment apart. An
    /// unguarded `Array` mutated from two threads is not a stale read, it is
    /// heap corruption. `AudioPipeline` guards its equivalent the same way.
    private let bufferLock = OSAllocatedUnfairLock(initialState: [Int16]())

    /// Configures a plain `.record` session. Background capture (wrist-down,
    /// screen off) is kept alive by the outdoor-walk `HKWorkoutSession` that
    /// `WatchSessionManager` runs for the duration of a recording (see
    /// `WatchWorkoutManager`); without an active workout the watch only captures
    /// while its app is frontmost.
    func start(onChunk: @escaping (Data) -> Void) throws {
        self.onChunk = onChunk
        bufferLock.withLock { $0.removeAll(keepingCapacity: true) }

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
        // `onChunk` and the sample buffer are deliberately NOT cleared here, for
        // the reason `AudioPipeline.stop()` spells out: a tap block can still be
        // in flight when `removeTap` returns, so writing either from this thread
        // races the audio render thread. Both are reset at the top of `start()`
        // before the engine comes back up, which is the only moment at which
        // nothing can be inside `handleTap`. The engine is stopped above, so no
        // further taps fire, and the closure captures `self` weakly.
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

        // Append and slice under the lock; deliver outside it, so a slow
        // `sendMessageData` on the delivery side never holds up the next tap.
        let chunks = bufferLock.withLock { storage -> [[Int16]] in
            storage.append(contentsOf: UnsafeBufferPointer(start: ptr, count: frames))
            return Self.drainChunks(from: &storage, chunkSamples: Self.chunkSamples)
        }
        guard let onChunk else { return }
        for chunk in chunks {
            onChunk(chunk.withUnsafeBufferPointer { Data(buffer: $0) })
        }
    }

    /// Removes and returns every whole `chunkSamples`-sized chunk `storage`
    /// currently holds, leaving the remainder for the next tap.
    ///
    /// Split out of `handleTap` so the chunking — which decides what actually
    /// reaches the phone, and how much audio a stop can strand — is exercisable
    /// without an audio engine.
    nonisolated static func drainChunks(
        from storage: inout [Int16],
        chunkSamples: Int
    ) -> [[Int16]] {
        guard chunkSamples > 0 else { return [] }
        var chunks: [[Int16]] = []
        while storage.count >= chunkSamples {
            chunks.append(Array(storage.prefix(chunkSamples)))
            storage.removeFirst(chunkSamples)
        }
        return chunks
    }
}
