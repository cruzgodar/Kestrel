import CoreGraphics
import Foundation
import Testing
@testable import Kestrel_Watch

/// The per-watch layout table.
///
/// watchOS exposes no API for the physical bezel radius, so these are measured
/// constants — which means nothing but a test can tell you when one has been
/// mistyped, and the symptom on device is subtle (a photo corner that doesn't
/// quite hug the bezel, or a stop button drifting into it). Checking the whole
/// table at once is only possible because `metrics(for:)` takes a size rather
/// than reading the current device.
@Suite("WatchMetrics")
struct WatchMetricsTests {

    /// Every watch size the table names, tagged with the hardware generation it
    /// belongs to. The generation matters: Apple changed the physical corner
    /// styling between them, so a 41mm Series 7 has a *rounder* bezel than the
    /// wider 44mm Series 6. Comparisons are only meaningful within a generation.
    static let knownSizes: [(size: CGSize, model: String, generation: String)] = [
        (CGSize(width: 162, height: 197), "40mm SE 2/3, Series 6", "SE/6"),
        (CGSize(width: 184, height: 224), "44mm SE 2/3, Series 6", "SE/6"),
        (CGSize(width: 176, height: 215), "41mm Series 7/8/9", "7/8/9"),
        (CGSize(width: 198, height: 242), "45mm Series 7/8/9", "7/8/9"),
        (CGSize(width: 187, height: 223), "42mm Series 10/11", "10/11"),
        (CGSize(width: 208, height: 248), "46mm Series 10/11", "10/11"),
        (CGSize(width: 205, height: 251), "49mm Ultra 1/2", "Ultra"),
        (CGSize(width: 211, height: 257), "49mm Ultra 3", "Ultra"),
    ]

    @Test("every known watch size resolves to sane metrics", arguments: knownSizes)
    func knownSizesResolve(entry: (size: CGSize, model: String, generation: String)) {
        let metrics = WatchMetrics.metrics(for: entry.size)

        #expect(metrics.screenCornerRadius > 0, "\(entry.model)")
        #expect(metrics.edgeMargin > 0, "\(entry.model)")
        #expect(metrics.nameImageGap > 0, "\(entry.model)")
        #expect(metrics.imageTopCornerRadius > 0, "\(entry.model)")

        // A radius larger than half the narrow side would be geometrically
        // impossible — the corners would overlap.
        #expect(metrics.screenCornerRadius < entry.size.width / 2, "\(entry.model)")
        // And a margin that big would leave nothing to draw in.
        #expect(metrics.edgeMargin < entry.size.width / 4, "\(entry.model)")
    }

    /// The photo's bottom corners are cut by the bezel itself, so its top radius
    /// has to match the bezel's or the four corners read differently.
    @Test("the photo's top radius matches the bezel radius", arguments: knownSizes)
    func topRadiusMatchesBezel(entry: (size: CGSize, model: String, generation: String)) {
        let metrics = WatchMetrics.metrics(for: entry.size)
        #expect(metrics.imageTopCornerRadius == metrics.screenCornerRadius, "\(entry.model)")
    }

    /// Within one hardware generation the bigger watch has the bigger radius. A
    /// break here is almost always a transposed digit in the table.
    ///
    /// Deliberately *not* checked across generations: the 41mm Series 7 (radius
    /// 39) is rounder than the wider 44mm Series 6 (radius 35), because Apple
    /// changed the corner styling. That's the hardware, not a typo.
    @Test("within a generation, the bigger watch has the rounder bezel")
    func radiusIsMonotonicWithinGeneration() {
        let byGeneration = Dictionary(grouping: Self.knownSizes, by: \.generation)
        for (generation, entries) in byGeneration {
            let sorted = entries.sorted { $0.size.width < $1.size.width }
            var previous: (radius: CGFloat, model: String)?
            for entry in sorted {
                let radius = WatchMetrics.metrics(for: entry.size).screenCornerRadius
                if let previous {
                    #expect(radius >= previous.radius,
                            "\(generation): \(entry.model) is wider than \(previous.model) but less round")
                }
                previous = (radius, entry.model)
            }
        }
    }

    /// The radii are measured constants with no API behind them, so pin the
    /// actual values. A silent edit to any of them changes how the app looks on a
    /// device the developer may not have to hand.
    @Test(
        "the measured bezel radii are what the table says",
        arguments: [
            (CGSize(width: 162, height: 197), CGFloat(29)),
            (CGSize(width: 184, height: 224), CGFloat(35)),
            (CGSize(width: 176, height: 215), CGFloat(39)),
            (CGSize(width: 198, height: 242), CGFloat(42)),
            (CGSize(width: 187, height: 223), CGFloat(46)),
            (CGSize(width: 208, height: 248), CGFloat(50)),
            (CGSize(width: 205, height: 251), CGFloat(55)),
            (CGSize(width: 211, height: 257), CGFloat(57)),
        ]
    )
    func measuredRadii(entry: (size: CGSize, expected: CGFloat)) {
        #expect(WatchMetrics.metrics(for: entry.size).screenCornerRadius == entry.expected)
    }

    /// An unlisted size — a watch released after this build — must still lay out
    /// sensibly rather than collapsing to zero.
    @Test(
        "an unknown size falls back to a proportional estimate",
        arguments: [
            CGSize(width: 150, height: 180),
            CGSize(width: 220, height: 270),
            CGSize(width: 300, height: 360),
        ]
    )
    func unknownSizeFallsBack(size: CGSize) {
        let metrics = WatchMetrics.metrics(for: size)
        #expect(metrics.screenCornerRadius > 0)
        #expect(metrics.screenCornerRadius < size.width / 2)
        #expect(metrics.edgeMargin == 12, "the documented default")
        #expect(metrics.nameImageGap == 10, "the documented default")
        #expect(metrics.imageTopCornerRadius == metrics.screenCornerRadius)
    }

    @Test("a zero size doesn't produce a negative or absurd radius")
    func zeroSizeIsSafe() {
        let metrics = WatchMetrics.metrics(for: .zero)
        #expect(metrics.screenCornerRadius >= 0)
        #expect(metrics.edgeMargin > 0)
    }

    @Test("the table is a pure function of size")
    func metricsAreDeterministic() {
        for entry in Self.knownSizes {
            let a = WatchMetrics.metrics(for: entry.size)
            let b = WatchMetrics.metrics(for: entry.size)
            #expect(a.screenCornerRadius == b.screenCornerRadius)
            #expect(a.edgeMargin == b.edgeMargin)
            #expect(a.nameImageGap == b.nameImageGap)
        }
    }

    @Test("the current device resolves through the same table")
    func currentMatchesTable() {
        let current = WatchMetrics.current
        let viaTable = WatchMetrics.metrics(for: WatchMetrics.currentScreenSize)
        #expect(current.screenCornerRadius == viaTable.screenCornerRadius)
        #expect(current.edgeMargin == viaTable.edgeMargin)
        #expect(WatchMetrics.screenCornerRadius == current.screenCornerRadius)
    }
}

/// When a birding walk is recorded as having ended.
@Suite("Workout end instant")
struct WorkoutEndInstantTests {

    private let stopTap = Date(timeIntervalSince1970: 1_780_000_000)

    /// The regression: a walk the user stopped at 2pm, whose save prompt they
    /// left sitting until 2:10, must be recorded as ending at 2pm. Every later
    /// teardown path — the abandon timeout, a watchdog, the system ending the
    /// session, a remote stop from the phone — reads the parked moment.
    @Test("a parked walk ends when the user tapped stop, not when the teardown ran")
    func parkedWalkKeepsItsStopMoment() {
        let tenMinutesLater = stopTap.addingTimeInterval(600)
        #expect(WatchWorkoutManager.endInstant(parked: stopTap, now: tenMinutesLater) == stopTap)
    }

    @Test("a walk nothing has parked ends now")
    func unparkedWalkEndsNow() {
        let now = stopTap.addingTimeInterval(42)
        #expect(WatchWorkoutManager.endInstant(parked: nil, now: now) == now)
    }

    /// However long the prompt sits, the recorded end never drifts.
    @Test(
        "the recorded end is independent of how long the prompt sat",
        arguments: [0.0, 1, 60, 600, 3_600, 86_400]
    )
    func endIsIndependentOfDelay(delay: TimeInterval) {
        #expect(
            WatchWorkoutManager.endInstant(parked: stopTap, now: stopTap.addingTimeInterval(delay))
            == stopTap
        )
    }

    /// And the duration Health is handed stays the walk the user actually took.
    @Test("a parked walk's duration doesn't grow while the prompt waits")
    func durationDoesNotGrow() {
        let start = stopTap.addingTimeInterval(-1_800)   // a 30-minute walk
        let recordedEnd = WatchWorkoutManager.endInstant(
            parked: stopTap, now: stopTap.addingTimeInterval(600)
        )
        #expect(recordedEnd.timeIntervalSince(start) == 1_800,
                "Health must not record a walk that ran on after the user stopped birding")
    }
}
