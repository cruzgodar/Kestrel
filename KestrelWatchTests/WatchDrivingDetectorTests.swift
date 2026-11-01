import Foundation
import Testing
@testable import Kestrel_Watch

/// The rules behind ending a birding walk when the wearer starts driving: which
/// fixes count as faster than walking, by their own speed or by distance covered.
@Suite("Driving detection")
struct WatchDrivingDetectorTests {

    @Test func highwaySpeedIsFast() {
        #expect(WatchDrivingDetector.isFast(speed: 27, speedAccuracy: 1, horizontalAccuracy: 10) == true)
    }

    @Test func runningIsNotFast() {
        #expect(WatchDrivingDetector.isFast(speed: 5, speedAccuracy: 0.5, horizontalAccuracy: 5) == false)
    }

    /// A fix only counts when it is fast even at the bottom of its error bar.
    @Test func uncertainSpeedIsNotFast() {
        #expect(WatchDrivingDetector.isFast(speed: 10, speedAccuracy: 4, horizontalAccuracy: 10) == false)
    }

    /// A speed with no stated accuracy is taken at its word; the streak guards it.
    @Test func speedWithoutAccuracyCounts() {
        #expect(WatchDrivingDetector.isFast(speed: 27, speedAccuracy: -1, horizontalAccuracy: 10) == true)
    }

    @Test func impreciseFixesAreNotFast() {
        #expect(WatchDrivingDetector.isFast(speed: 27, speedAccuracy: 1, horizontalAccuracy: 200) == false)
        #expect(WatchDrivingDetector.isFast(speed: 27, speedAccuracy: 1, horizontalAccuracy: -1) == false)
    }

    /// No speed at all defers to the distance check rather than answering.
    @Test func missingSpeedIsUndecided() {
        #expect(WatchDrivingDetector.isFast(speed: -1, speedAccuracy: -1, horizontalAccuracy: 10) == nil)
    }

    @Test func drivingDistanceIsFast() {
        #expect(WatchDrivingDetector.isFast(distance: 270, interval: 10, accuracies: (10, 10)))
    }

    @Test func walkingDistanceIsNotFast() {
        #expect(!WatchDrivingDetector.isFast(distance: 15, interval: 10, accuracies: (10, 10)))
    }

    /// Position error alone can't pass for motion: a jump inside both fixes'
    /// accuracy says nothing.
    @Test func jumpWithinAccuracyIsNotFast() {
        #expect(!WatchDrivingDetector.isFast(distance: 150, interval: 10, accuracies: (80, 80)))
    }

    @Test func tooShortAnIntervalIsNotFast() {
        #expect(!WatchDrivingDetector.isFast(distance: 100, interval: 2, accuracies: (5, 5)))
    }
}
