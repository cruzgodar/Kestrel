import Foundation
import Testing
@testable import Kestrel_Watch

/// How captured audio is sliced into the chunks that go to the phone.
///
/// The buffer this drains is written by the audio render thread and cleared by
/// the manager's audio queue — the two are a moment apart every time a watchdog
/// calls `restartCapture` — so it lives behind a lock now, the way
/// `AudioPipeline`'s equivalent always has. The slicing itself is pulled out
/// here because it decides what actually reaches the phone, and how much audio a
/// stop can strand, and none of that should need an audio engine to check.
@Suite("Watch audio chunking")
struct WatchAudioStreamerTests {

    private func samples(_ count: Int) -> [Int16] {
        (0..<count).map { Int16(truncatingIfNeeded: $0) }
    }

    @Test("a buffer short of a whole chunk yields nothing and keeps its samples")
    func shortBufferIsHeld() {
        var storage = samples(100)
        let chunks = WatchAudioStreamer.drainChunks(from: &storage, chunkSamples: 8_000)
        #expect(chunks.isEmpty)
        #expect(storage.count == 100, "the remainder waits for the next tap")
    }

    @Test("an exact chunk is drained whole, leaving nothing behind")
    func exactChunkDrains() {
        var storage = samples(8_000)
        let chunks = WatchAudioStreamer.drainChunks(from: &storage, chunkSamples: 8_000)
        #expect(chunks.count == 1)
        #expect(chunks.first?.count == 8_000)
        #expect(storage.isEmpty)
    }

    /// A tap can deliver several chunks' worth at once after a stall, and every
    /// one of them has to go — dropping the surplus would punch a hole in the
    /// stream the phone is running BirdNET over.
    @Test("a backlog drains every whole chunk in one pass")
    func backlogDrainsCompletely() {
        var storage = samples(8_000 * 3 + 500)
        let chunks = WatchAudioStreamer.drainChunks(from: &storage, chunkSamples: 8_000)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count == 8_000 })
        #expect(storage.count == 500)
    }

    /// The audio has to come out in the order it went in, and unaltered — this
    /// is a byte stream a classifier reads, not a set.
    @Test("samples keep their order and values across the split")
    func samplesAreContiguousAndInOrder() {
        let input = samples(2_500)
        var storage = input
        let chunks = WatchAudioStreamer.drainChunks(from: &storage, chunkSamples: 1_000)
        #expect(chunks.count == 2)
        #expect(chunks[0] == Array(input[0..<1_000]))
        #expect(chunks[1] == Array(input[1_000..<2_000]))
        #expect(storage == Array(input[2_000..<2_500]))
    }

    @Test("an empty buffer is a no-op")
    func emptyBuffer() {
        var storage: [Int16] = []
        #expect(WatchAudioStreamer.drainChunks(from: &storage, chunkSamples: 8_000).isEmpty)
        #expect(storage.isEmpty)
    }

    /// Defensive: a zero or negative chunk size would otherwise spin forever
    /// slicing empty chunks off a buffer that never shrinks — on the audio
    /// thread, holding the lock.
    @Test("a non-positive chunk size returns rather than looping")
    func nonPositiveChunkSize() {
        var storage = samples(10)
        #expect(WatchAudioStreamer.drainChunks(from: &storage, chunkSamples: 0).isEmpty)
        #expect(WatchAudioStreamer.drainChunks(from: &storage, chunkSamples: -1).isEmpty)
        #expect(storage.count == 10)
    }

    /// The shipped chunk size is what sets the message rate to the phone, which
    /// is the thing watchOS suspends a backgrounded app over. Pinned so a change
    /// to it is a deliberate one.
    @Test("the shipped chunk is half a second of 16 kHz mono")
    func shippedChunkIsHalfASecond() {
        #expect(WatchAudioStreamer.chunkSamples == 8_000)
        #expect(Double(WatchAudioStreamer.chunkSamples) / WatchAudioStreamer.targetSampleRate == 0.5)
    }
}
