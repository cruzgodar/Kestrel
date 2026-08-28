import Foundation
import Testing
@testable import Kestrel

/// When a cached nearby-species list is still worth using.
///
/// The cache persisted its week and the moment it was saved and then read back
/// neither, so the "Using last-known list" fallback would happily filter a
/// spring morning's detections through a list computed the previous autumn — a
/// list that is wrong in both directions, suppressing birds that are here now
/// and admitting ones that aren't.
@Suite("Species range filter cache")
struct SpeciesRangeFilterCacheTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(-seconds) }
    private let day: TimeInterval = 24 * 60 * 60

    // MARK: the detection filter

    @Test("a cache from this week is current")
    func sameWeekIsCurrent() {
        #expect(SpeciesRangeFilter.isCurrent(
            cachedWeek: 18, savedAt: ago(60), week: 18, now: t0
        ))
    }

    @Test("a cache from another week is not")
    func otherWeekIsRefused() {
        #expect(!SpeciesRangeFilter.isCurrent(
            cachedWeek: 17, savedAt: ago(60), week: 18, now: t0
        ))
        #expect(!SpeciesRangeFilter.isCurrent(
            cachedWeek: 44, savedAt: ago(60), week: 18, now: t0
        ))
    }

    /// BirdNET's week repeats annually, so the week check can't bound age on its
    /// own — week 18 of last year matches week 18 of this one exactly. That is
    /// the case the age bound exists for.
    @Test("last year's cache doesn't pass as this week's")
    func aYearOldSameWeekIsRefused() {
        #expect(!SpeciesRangeFilter.isCurrent(
            cachedWeek: 18, savedAt: ago(365 * day), week: 18, now: t0
        ))
    }

    @Test("the age bound is where it says it is")
    func ageBoundary() {
        let maxAge = SpeciesRangeFilter.maxCacheAge
        #expect(SpeciesRangeFilter.isWithinMaxAge(savedAt: ago(maxAge - 1), now: t0))
        #expect(!SpeciesRangeFilter.isWithinMaxAge(savedAt: ago(maxAge), now: t0))
    }

    /// The age bound is comfortably longer than the ~7.5 days a single BirdNET
    /// week spans, so it never fires on a cache the week check would have
    /// accepted for legitimate reasons.
    @Test("the age bound outlasts a single week")
    func ageBoundOutlastsAWeek() {
        #expect(SpeciesRangeFilter.maxCacheAge > 8 * day)
    }

    /// A clock that has gone backwards (a manual change, a DST oddity) stamps a
    /// cache in the future. That is not a reason to throw a good list away.
    @Test("a future timestamp is tolerated rather than discarded")
    func futureStampIsUsable() {
        #expect(SpeciesRangeFilter.isWithinMaxAge(savedAt: t0.addingTimeInterval(600), now: t0))
    }

    // MARK: the two readers, and why they differ

    /// `cachedAllowedIndices` is deliberately *not* week-gated: its readers are
    /// the photo prefetch's protected set and the life list's "found in this
    /// area" grouping, none of which gates a detection. Dropping it on a week
    /// boundary would unprotect a region's cached photos and re-download them,
    /// possibly over cellular, to fix a grouping heading.
    @Test("only the detection filter is week-gated")
    func readersDifferOnWeekButNotOnAge() {
        let lastWeek = ago(3 * day)
        // The detection filter refuses a neighbouring week...
        #expect(!SpeciesRangeFilter.isCurrent(
            cachedWeek: 17, savedAt: lastWeek, week: 18, now: t0
        ))
        // ...while the age-only bound both readers share still accepts it.
        #expect(SpeciesRangeFilter.isWithinMaxAge(savedAt: lastWeek, now: t0))
    }

    /// Whatever the detection filter accepts, the looser reader accepts too —
    /// the two can disagree in one direction only.
    @Test("anything current is also within the shared age bound")
    func currencyImpliesFreshness() {
        for age in [0.0, day, 7 * day, SpeciesRangeFilter.maxCacheAge - 1] {
            let savedAt = ago(age)
            if SpeciesRangeFilter.isCurrent(cachedWeek: 18, savedAt: savedAt, week: 18, now: t0) {
                #expect(SpeciesRangeFilter.isWithinMaxAge(savedAt: savedAt, now: t0))
            }
        }
    }

    // MARK: the week numbering the check turns on

    /// `isCurrent` is only as good as the week it compares against, and that
    /// numbering is what BirdNET's geo model was trained on: 4 buckets a month,
    /// 48 a year.
    ///
    /// Built from *local* noon, not `utcDay`: `birdnetWeek` reads the device's
    /// own calendar on purpose — which season it is, is a question about where
    /// the user is standing — so a UTC-midnight instant would land on the
    /// previous day for everyone west of Greenwich.
    @Test("BirdNET weeks run 1...48, four to a month")
    func weekNumbering() {
        #expect(SpeciesRangeFilter.birdnetWeek(from: localNoon(2026, 1, 1)) == 1)
        #expect(SpeciesRangeFilter.birdnetWeek(from: localNoon(2026, 12, 31)) == 48)
        for month in 1...12 {
            for day in [1, 8, 16, 23, 28] {
                let week = SpeciesRangeFilter.birdnetWeek(from: localNoon(2026, month, day))
                #expect((1...48).contains(week))
                #expect((week - 1) / 4 == month - 1, "a week never escapes its month")
            }
        }
    }

    /// Midday in the device's own zone, so the date components `birdnetWeek`
    /// reads back are the ones asked for whatever the offset and whatever DST is
    /// doing at midnight.
    private func localNoon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components)!
    }
}
