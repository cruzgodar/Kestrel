import CoreLocation
import Foundation
import Testing
@testable import Kestrel

/// When the Targets tab may keep the list it has, and what month it names.
///
/// A refresh used to compare only the place and the season. Current is not one
/// fixed span, though — it is whichever three BirdNET weeks surround today — so
/// for as long as the app stayed alive in one spot the list kept the weeks it
/// was first worked out for, and past a month boundary the heading named the
/// new month over the old month's birds.
@Suite("Targets list identity")
struct TargetsListTests {

    private let ithaca = CLLocationCoordinate2D(latitude: 42.44, longitude: -76.50)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func key(
        _ coordinate: CLLocationCoordinate2D,
        _ season: TargetsModel.Season = .current,
        on day: Date
    ) -> TargetsModel.ListKey {
        TargetsModel.ListKey(
            coordinate: coordinate,
            season: season,
            weeks: TargetsModel.weeks(for: season, now: day)
        )
    }

    /// `latitude` degrees north of `ithaca` — about 111 km a degree.
    private func north(by degrees: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: ithaca.latitude + degrees, longitude: ithaca.longitude)
    }

    @Test("the same place, season and weeks is the same list")
    func sameList() {
        let october10 = date(2026, 10, 10)
        #expect(TargetsModel.describesSameList(key(ithaca, on: october10), as: key(ithaca, on: october10)))
        #expect(TargetsModel.describesSameList(
            key(ithaca, on: october10), as: key(north(by: 0.009), on: october10)
        ), "a kilometre's walk is the same list")
    }

    @Test("moving more than two kilometres is a different list")
    func movedFar() {
        let october10 = date(2026, 10, 10)
        #expect(!TargetsModel.describesSameList(
            key(ithaca, on: october10), as: key(north(by: 0.03), on: october10)
        ))
    }

    @Test("another season is a different list")
    func otherSeason() {
        let october10 = date(2026, 10, 10)
        #expect(!TargetsModel.describesSameList(
            key(ithaca, .current, on: october10), as: key(ithaca, .anyTime, on: october10)
        ))
    }

    @Test("a new week is a different list, in the same place and season")
    func newWeek() {
        // Week 38 and week 39.
        #expect(!TargetsModel.describesSameList(
            key(ithaca, on: date(2026, 10, 10)), as: key(ithaca, on: date(2026, 10, 20))
        ))
        // Across a month boundary: week 40 and week 41.
        #expect(!TargetsModel.describesSameList(
            key(ithaca, on: date(2026, 10, 31)), as: key(ithaca, on: date(2026, 11, 1))
        ))
    }

    @Test("Any Time of Year doesn't go stale with the date")
    func anyTimeIsTimeless() {
        #expect(TargetsModel.describesSameList(
            key(ithaca, .anyTime, on: date(2026, 1, 2)), as: key(ithaca, .anyTime, on: date(2026, 10, 31))
        ))
    }

    @Test("a Current list is named for the month of its middle week")
    func month() {
        #expect(key(ithaca, on: date(2026, 10, 10)).month == 10)
        #expect(key(ithaca, on: date(2026, 10, 31)).month == 10, "its last week reaches into November")
        #expect(key(ithaca, on: date(2026, 11, 1)).month == 11, "its first week reaches back into October")
        #expect(key(ithaca, on: date(2026, 1, 2)).month == 1, "wrapping back to December")
        #expect(key(ithaca, on: date(2026, 12, 31)).month == 12, "wrapping on to January")
        #expect(key(ithaca, .anyTime, on: date(2026, 10, 10)).month == nil)
    }
}
