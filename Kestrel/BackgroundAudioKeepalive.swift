import AVFoundation
import Foundation

/// Keeps the iOS app alive in the background while it's acting purely as a
/// WatchConnectivity receiver (no local mic capture).
///
/// iOS suspends apps that aren't doing audible audio I/O even if
/// `UIBackgroundModes` includes `audio`. We trick the system into keeping
/// the app running by activating a `.playback` audio session and looping a
/// short buffer of silence through `AVAudioEngine`. `.mixWithOthers` means
/// nothing the user is playing gets interrupted.
///
/// `WCSession.sendMessageData` from the watch requires the iOS app to be
/// reachable — having an active audio session in a declared background
/// mode satisfies that, so the watch stream keeps flowing.
final class BackgroundAudioKeepalive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private(set) var isActive = false

    func start() {
        guard !isActive else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            Log.error("Keepalive audio session error: \(error)")
            return
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames: AVAudioFrameCount = 4_800  // 100 ms of silence
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        // PCM buffers are zero-initialized → genuine silence.

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            player.play()
            isActive = true
        } catch {
            Log.error("Keepalive engine error: \(error)")
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    func stop() {
        guard isActive else { return }
        player.stop()
        engine.stop()
        engine.detach(player)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isActive = false
    }
}
