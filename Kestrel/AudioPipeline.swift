@preconcurrency import AVFoundation
import Foundation
import os

/// Captures microphone audio, resamples to 48 kHz mono Float32, and emits
/// non-overlapping 3-second windows (144,000 samples) suitable for BirdNET.
///
/// `@unchecked Sendable` (and thus nonisolated under the project's MainActor
/// default isolation): `start()`/`stop()` are documented as never running
/// concurrently, the shared sample buffer is guarded by `bufferLock`, and the
/// prewarm task is guarded by `prewarmLock`. Being nonisolated is what lets
/// `RecordingManager` spin the audio engine up from a detached task so the
/// record-button morph can animate while the (main-thread-taxing) engine
/// bring-up runs off the main actor.
nonisolated final class AudioPipeline: @unchecked Sendable {
    // `nonisolated` so these compile-time constants can be read from the
    // nonisolated audio-tap closure (and the detached start task) without the
    // main-actor hop the project's default isolation would otherwise impose.
    nonisolated static let targetSampleRate: Double = 48_000
    nonisolated static let windowSamples: Int = 144_000      // 3 s @ 48 kHz — BirdNET's input length
    nonisolated static let hopSamples: Int = 72_000          // 1.5 s — 50% overlap so songs aren't bisected

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

    private let prewarmLock = NSLock()
    private var prewarmTask: Task<Void, Never>?

    var isRunning: Bool { engine.isRunning }

    /// Schedules background audio prewarm. Idempotent — subsequent calls return
    /// the existing in-flight task. The prewarm briefly activates the session,
    /// touches the input node so iOS resolves the hardware audio route, then
    /// deactivates. Route + format remain cached afterward so the next
    /// `setActive` + `inputFormat` calls inside `start()` are fast.
    func startPrewarm() {
        prewarmLock.lock()
        defer { prewarmLock.unlock() }
        guard prewarmTask == nil else { return }
        prewarmTask = Task.detached(priority: .userInitiated) { [weak self] in
            self?.runPrewarm()
        }
    }

    /// Awaits any in-flight prewarm so start can run without contending for
    /// the audio session.
    func awaitPrewarm() async {
        let task = prewarmLock.withLock { prewarmTask }
        await task?.value
    }

    private func runPrewarm() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
        } catch {
            Log.error("Audio prewarm error: \(error)")
        }
    }

    func start(
        onWindow: @escaping @Sendable ([Float]) -> Void,
        onChunk: (@Sendable ([Float]) -> Void)? = nil
    ) throws {
        self.onWindow = onWindow
        self.onChunk = onChunk

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .defaultToSpeaker])
        // A `.playAndRecord` session silences the Taptic Engine by default, so
        // the phone's new-species haptics wouldn't fire while its own mic is
        // recording. Opt back in so `UINotificationFeedbackGenerator` works.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
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

    /// Reactivates the audio session and restarts the engine after a system audio
    /// interruption ends (a call, alarm, Siri, another app, a video recording), so
    /// recording resumes without the user re-tapping. The tap stays installed
    /// across an interruption, so this just re-arms the session + engine.
    func resumeAfterInterruption() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true, options: [])
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            Log.error("AudioPipeline resume error: \(error)")
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        // `onWindow`/`onChunk` are deliberately NOT cleared here. Niling them from
        // this thread while the audio render thread could still be inside
        // `handleTap` (a tap block can be in flight when `removeTap` returns) is a
        // data race on the closure references. They're always reassigned at the top
        // of `start()` before the engine is restarted, so leaving the stale closures
        // in place until then is harmless — the engine is stopped above, so no
        // further taps fire, and `onWindow` captures `self` weakly so nothing leaks.
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
            if let convError { Log.error("AudioPipeline: convert error \(convError)") }
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
        let completed: [[Float]] = bufferLock.withLock { storage in
            storage.append(contentsOf: newSamples)
            var windows: [[Float]] = []
            while storage.count >= AudioPipeline.windowSamples {
                windows.append(Array(storage.prefix(AudioPipeline.windowSamples)))
                storage.removeFirst(AudioPipeline.hopSamples)
            }
            return windows
        }

        if let onWindow {
            for window in completed { onWindow(window) }
        }
    }
}
