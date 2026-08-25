import CoreGraphics
import Foundation
import Testing
@testable import Kestrel

/// The spectrogram's display-link pause accounting.
///
/// The display link is paused whenever the Identify tab is off screen or the app
/// is inactive, but audio keeps being captured. Resuming without accounting for
/// the absence spliced the columns from before it directly against the ones
/// after, so a spectrogram from ten minutes ago read as continuous with what was
/// happening now — a picture of sound that was never there.
@Suite("Spectrogram pause gap")
struct SpectrogramGapTests {

    /// Enough silence to render several columns, with the ~1 s of headroom the
    /// pump wants before it will anchor.
    private func audio(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(Double(SpectrogramRenderer.sampleRate) * seconds))
    }

    /// Runs a renderer up to a steady state: audio in, pumped twice so the pacing
    /// anchor is established and columns are actually being produced.
    private func warmedRenderer() -> (SpectrogramRenderer, CFTimeInterval) {
        let renderer = SpectrogramRenderer()
        renderer.ingest(audio(seconds: 2))
        var t: CFTimeInterval = 1_000
        renderer.pumpColumns(at: t)          // anchors
        t += 0.5
        renderer.pumpColumns(at: t)          // produces
        #expect(renderer.columnsGenerated > 0, "the renderer should be producing columns")
        return (renderer, t)
    }

    // MARK: the gap

    @Test("a long pause writes one blank column per column-time missed")
    func gapInsertsBlanks() {
        let (renderer, t) = warmedRenderer()
        let before = renderer.columnsGenerated

        let gap: CFTimeInterval = 2.0
        renderer.ingest(audio(seconds: 1))
        renderer.pumpColumns(at: t + gap)

        let inserted = renderer.columnsGenerated - before
        let expected = Int(gap * SpectrogramRenderer.columnsPerSecond)
        #expect(inserted == expected,
                "a \(gap)s absence should advance the ring by \(expected) columns, not splice over it")
    }

    /// A gap longer than the whole visible history means every column on screen
    /// is part of the absence.
    @Test("a pause longer than the visible history clears the whole ring")
    func longGapClearsRing() {
        let (renderer, t) = warmedRenderer()
        let before = renderer.columnsGenerated

        // The ring holds ~3.85 s; jump well past it.
        renderer.pumpColumns(at: t + 60)
        let inserted = renderer.columnsGenerated - before
        #expect(inserted >= SpectrogramRenderer.columnCount)

        // Nothing of the old picture may remain.
        guard let image = renderer.snapshot() else {
            Issue.record("the renderer should still produce a snapshot after a long gap")
            return
        }
        #expect(image.width == SpectrogramRenderer.columnCount)
        #expect(isEntirelyBlank(image), "a ten-minute absence must not be drawn as sound")
    }

    /// The audio buffered during the absence belongs to the gap, not to now.
    @Test("audio captured during the pause is discarded, not drawn as current")
    func gapDropsBufferedAudio() {
        let (renderer, t) = warmedRenderer()

        // A big backlog accumulates while the display link is parked.
        renderer.ingest(audio(seconds: 5))
        renderer.pumpColumns(at: t + 2.0)
        let afterGap = renderer.columnsGenerated

        // Immediately after, with no fresh audio, nothing may be produced: the
        // backlog is gone and the pacing anchor was reset.
        renderer.pumpColumns(at: t + 2.001)
        #expect(renderer.columnsGenerated == afterGap,
                "stale audio must not be rendered as though it had just arrived")
    }

    // MARK: not a gap

    /// The threshold sits comfortably above the ~0.16 s the existing burst-rebase
    /// already treats as a system hiccup, so ordinary dropped frames must not be
    /// drawn as silence.
    @Test(
        "an ordinary frame hitch is not treated as a pause",
        arguments: [0.016, 0.05, 0.1, 0.2, 0.3, 0.34]
    )
    func shortGapIsNotAPause(hitch: CFTimeInterval) {
        #expect(hitch < SpectrogramRenderer.pauseGapThreshold)

        let (renderer, t) = warmedRenderer()
        let before = renderer.columnsGenerated
        renderer.ingest(audio(seconds: 1))
        renderer.pumpColumns(at: t + hitch)

        let produced = renderer.columnsGenerated - before
        let paced = Int(hitch * SpectrogramRenderer.columnsPerSecond)
        #expect(produced <= paced + 2, "a \(hitch)s hitch should render audio, not blanks")
    }

    @Test("the very first pump is never treated as a pause")
    func firstPumpIsNotAGap() {
        let renderer = SpectrogramRenderer()
        renderer.ingest(audio(seconds: 2))
        // A large absolute display time — a device that has been up for hours.
        renderer.pumpColumns(at: 500_000)
        renderer.pumpColumns(at: 500_000.5)
        let produced = renderer.columnsGenerated
        #expect(produced > 0)
        #expect(produced < SpectrogramRenderer.columnCount,
                "there was no prior pump to have been absent from")
    }

    @Test("reset clears the pause bookkeeping along with everything else")
    func resetClearsGapState() {
        let (renderer, t) = warmedRenderer()
        renderer.reset()
        #expect(renderer.columnsGenerated == 0)

        // A pump long after the pre-reset one must anchor fresh, not report a gap.
        renderer.ingest(audio(seconds: 2))
        renderer.pumpColumns(at: t + 600)
        renderer.pumpColumns(at: t + 600.5)
        #expect(renderer.columnsGenerated > 0)
        #expect(renderer.columnsGenerated < SpectrogramRenderer.columnCount)
    }

    @Test("a reset spectrogram is blank")
    func resetIsBlank() {
        let (renderer, _) = warmedRenderer()
        renderer.reset()
        guard let image = renderer.snapshot() else {
            Issue.record("a reset renderer should still snapshot")
            return
        }
        #expect(isEntirelyBlank(image))
    }

    // MARK: geometry

    @Test("the snapshot matches the ring's declared dimensions")
    func snapshotDimensions() {
        let (renderer, _) = warmedRenderer()
        guard let image = renderer.snapshot() else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(image.width == SpectrogramRenderer.columnCount)
        #expect(image.height == SpectrogramRenderer.displayBins)
    }

    @Test("the highlight span never exceeds the visible history")
    func highlightSpanBounded() {
        #expect(SpectrogramRenderer.highlightSpan <= SpectrogramRenderer.columnCount)
        #expect(SpectrogramRenderer.highlightSpan > 0)
    }

    @Test("marking a detection is safe on an empty renderer")
    func markDetectionOnEmpty() {
        let renderer = SpectrogramRenderer()
        renderer.markDetection(kind: .starred)
        renderer.markDetection(kind: .lifer)
        renderer.markDetection(kind: .needsAdd)
        #expect(renderer.snapshot() != nil)
    }

    // MARK: helpers

    /// Whether every pixel is the opaque black the ring is cleared to.
    private func isEntirelyBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return false }
        let count = CFDataGetLength(data)
        for i in stride(from: 0, to: count, by: 4) {
            // Alpha is 255 everywhere; a lit column shows in the color channels.
            if bytes[i] != 0 || bytes[i + 1] != 0 || bytes[i + 2] != 0 { return false }
        }
        return true
    }
}
