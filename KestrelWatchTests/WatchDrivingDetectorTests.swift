import Foundation
import Testing
@testable import Kestrel_Watch

/// The two rules behind leaving a drive out of a birding walk: which fixes count
/// as faster than walking, and how long driving outlasts its last evidence.
@Suite("Driving detection")
struct WatchDrivingDetectorTests {

    @Test func highwaySpeedIsFast() {
        #expect(WatchDrivingDetector.isFast(speed: 27, speedAccuracy: 1, horizontalAccuracy: 10))
    }

    @Test func runningIsNotFast() {
        #expect(!WatchDrivingDetector.isFast(speed: 5, speedAccuracy: 0.5, horizontalAccuracy: 5))
    }

    /// A fix only counts when it is fast even at the bottom of its error bar.
    @Test func uncertainSpeedIsNotFast() {
        #expect(!WatchDrivingDetector.isFast(speed: 10, speedAccuracy: 4, horizontalAccuracy: 10))
    }

    @Test func invalidOrImpreciseFixesAreNotFast() {
        #expect(!WatchDrivingDetector.isFast(speed: -1, speedAccuracy: 1, horizontalAccuracy: 10))
        #expect(!WatchDrivingDetector.isFast(speed: 27, speedAccuracy: -1, horizontalAccuracy: 10))
        #expect(!WatchDrivingDetector.isFast(speed: 27, speedAccuracy: 1, horizontalAccuracy: 200))
    }

    @Test func drivingHoldsThroughARedLight() {
        let now = Date()
        #expect(WatchDrivingDetector.isDriving(lastEvidenceAt: now.addingTimeInterval(-60), now: now))
    }

    @Test func drivingEndsAfterTheHold() {
        let now = Date()
        let last = now.addingTimeInterval(-WatchDrivingDetector.hold)
        #expect(!WatchDrivingDetector.isDriving(lastEvidenceAt: last, now: now))
        #expect(!WatchDrivingDetector.isDriving(lastEvidenceAt: nil, now: now))
    }
}
