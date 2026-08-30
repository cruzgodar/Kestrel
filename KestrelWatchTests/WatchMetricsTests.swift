import CoreGraphics
import Foundation
import HealthKit
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

/// Whether a Resume tap can pick a parked walk back up.
///
/// The prompt's Resume row is drawn from `PendingWorkout.canResume`, but that
/// flag alone isn't enough: `endPausedSession()` — which the ten-minute abandon
/// timeout runs — clears the live session and only re-parks the walk as
/// non-resumable *after* an `await` on HealthKit's `endCollection`. For the
/// whole of that call the row is still on screen and still takes taps while the
/// session behind it is gone.
///
/// `WatchSessionManager.resumeBirding` treats a refusal as "start nothing": the
/// walk is parked and unanswered, and beginning a session over it would let the
/// next stop overwrite `pendingSave` and throw it away — which is exactly what
/// `start()` refuses to do, and used to be reachable through this button.
@Suite("Workout resume precondition")
struct WorkoutResumeTests {

    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    private func pending(canResume: Bool) -> WatchWorkoutManager.PendingWorkout {
        .init(start: start, end: start.addingTimeInterval(600), canResume: canResume)
    }

    @Test("a paused walk with a live session picks back up")
    func livePausedWalkResumes() {
        #expect(WatchWorkoutManager.canPickBackUp(
            hasLiveSession: true, pending: pending(canResume: true)
        ))
    }

    /// The window this exists for: the flag still says resumable, the session is
    /// already gone.
    @Test("a resumable-looking walk whose session has gone does not")
    func lostSessionRefusesEvenWhenFlagged() {
        #expect(!WatchWorkoutManager.canPickBackUp(
            hasLiveSession: false, pending: pending(canResume: true)
        ))
    }

    @Test("a walk that was never resumable does not, session or no session")
    func nonResumableWalkRefuses() {
        #expect(!WatchWorkoutManager.canPickBackUp(
            hasLiveSession: true, pending: pending(canResume: false)
        ))
        #expect(!WatchWorkoutManager.canPickBackUp(
            hasLiveSession: false, pending: pending(canResume: false)
        ))
    }

    @Test("with no walk parked there is nothing to pick back up")
    func nothingParkedRefuses() {
        #expect(!WatchWorkoutManager.canPickBackUp(hasLiveSession: true, pending: nil))
        #expect(!WatchWorkoutManager.canPickBackUp(hasLiveSession: false, pending: nil))
    }
}

/// Whether a birding walk on this watch could reach HealthKit at all — the half
/// of "is this walk worth offering to save?" that has nothing to do with the walk.
///
/// It exists as its own question because the *phone* needs the answer and cannot
/// work it out: watchOS HealthKit authorization is per-device and grantable only
/// from the wrist. The phone raises the save/discard prompt when a watch session
/// is stopped there, and was gating it on duration alone — so a user who had
/// declined workout sharing was offered "Save Workout", tapped it, and got
/// nothing at all. The watch had already refused to park a walk it couldn't save,
/// discarded it, and the relayed decision found neither a builder nor a span.
@Suite("Workout savability")
struct WorkoutSavabilityTests {

    @Test("an authorized watch can save")
    func authorizedCanSave() {
        #expect(WatchWorkoutManager.canSaveWorkouts(
            healthDataAvailable: true, sharing: .sharingAuthorized
        ))
    }

    /// The case the phone has to be told about.
    @Test("a denied watch cannot")
    func deniedCannotSave() {
        #expect(!WatchWorkoutManager.canSaveWorkouts(
            healthDataAvailable: true, sharing: .sharingDenied
        ))
    }

    /// Not yet asked is not the same as refused. The authorization sheet goes up
    /// on the first `start()`, and declining to offer a save before the user has
    /// even been asked would be its own kind of wrong — the push is repeated once
    /// that resolves, so a denial still lands before the first stop.
    @Test("an unasked watch is treated as able to save")
    func notDeterminedCanSave() {
        #expect(WatchWorkoutManager.canSaveWorkouts(
            healthDataAvailable: true, sharing: .notDetermined
        ))
    }

    @Test("no health store at all means no save")
    func unavailableCannotSave() {
        #expect(!WatchWorkoutManager.canSaveWorkouts(
            healthDataAvailable: false, sharing: .sharingAuthorized
        ))
        #expect(!WatchWorkoutManager.canSaveWorkouts(
            healthDataAvailable: false, sharing: .notDetermined
        ))
    }
}

/// Which now-hearing pushes the watch acts on.
///
/// The bird rides the application context, which re-delivers the *whole* context
/// whenever any key in it changes — so the watch has to tell a genuine update
/// from a replay. The phone tags each real push with a `birdSeq` that only rises,
/// seeded from the wall clock so a fresh phone process out-numbers whatever it
/// said last time.
@Suite("Now-hearing push de-duplication")
struct BirdPushSequenceTests {

    @Test("a newer push applies")
    func newerApplies() {
        #expect(WatchSessionManager.shouldApplyBirdPush(seq: 11, lastApplied: 10))
    }

    @Test("the same push again is a re-delivery")
    func repeatIsIgnored() {
        #expect(!WatchSessionManager.shouldApplyBirdPush(seq: 10, lastApplied: 10))
    }

    /// The regression. Equality alone let an *older* context through: the context
    /// carries a single now-hearing slot, so an out-of-order replay announced a
    /// bird the phone had already moved on from as the one it was hearing now.
    @Test("an older push is ignored, not just an identical one")
    func staleIsIgnored() {
        #expect(
            !WatchSessionManager.shouldApplyBirdPush(seq: 9, lastApplied: 10),
            "a replay of an earlier push is not news"
        )
    }

    /// Nothing in the app sends an untagged push today, but dropping an update
    /// that can't be ordered would be worse than repeating one.
    @Test("an untagged push always applies")
    func untaggedApplies() {
        #expect(WatchSessionManager.shouldApplyBirdPush(seq: nil, lastApplied: 10))
    }

    /// The first push of a watch process, against the sentinel.
    @Test("the first push of a process applies")
    func firstPushApplies() {
        #expect(WatchSessionManager.shouldApplyBirdPush(seq: 0, lastApplied: -1))
    }
}
