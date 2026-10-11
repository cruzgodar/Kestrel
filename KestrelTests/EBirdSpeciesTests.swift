import Foundation
import Testing
@testable import Kestrel

/// The pure parts of the eBird species lists: which past days are sampled,
/// how reports become frequencies, and how frequencies become filter tiers.
@Suite("eBird species")
struct EBirdSpeciesTests {

    private typealias Entry = EBirdSpecies.Frequencies.Entry

    private let now = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2026, month: 10, day: 10))!

    // MARK: samples

    @Test("a week sample is fifteen days around the week's middle in each of the last three years")
    func weekSample() {
        let sample = EBirdSpecies.weekSample(week: 38, now: now)
        #expect(sample.years == 3)
        #expect(sample.dates.count == 45)
        #expect(Set(sample.dates.compactMap(\.year)) == [2023, 2024, 2025])
        // Week 38 is October 8–15; its middle is the 11th.
        #expect(sample.dates.first == DateComponents(year: 2023, month: 10, day: 4))
        #expect(sample.dates.last == DateComponents(year: 2025, month: 10, day: 18))
    }

    @Test("a week sample crosses month and year ends")
    func weekSampleWraps() {
        let sample = EBirdSpecies.weekSample(week: 1, now: now)
        #expect(sample.dates.first == DateComponents(year: 2022, month: 12, day: 28))
    }

    @Test("samples name their years, so a new year refetches")
    func sampleKeys() {
        let nextYear = now.addingTimeInterval(365 * 24 * 60 * 60)
        #expect(EBirdSpecies.weekSample(week: 38, now: now).key
                != EBirdSpecies.weekSample(week: 38, now: nextYear).key)
        #expect(EBirdSpecies.monthSample(month: 10, now: now).key
                != EBirdSpecies.monthSample(month: nil, now: now).key)
    }

    @Test("month and any-month samples stay near 45 requests")
    func monthSamples() {
        let month = EBirdSpecies.monthSample(month: 2, now: now)
        #expect(month.dates.count == 42)
        #expect(month.dates.allSatisfy { $0.month == 2 && $0.day! <= 28 })
        let year = EBirdSpecies.monthSample(month: nil, now: now)
        #expect(year.dates.count == 48)
        #expect(year.years == 2)
    }

    // MARK: tallying

    @Test("frequency is the share of days reported; years count distinct years")
    func tally() {
        let indices: (String) -> [Int] = ["mallar3": [1], "redpol1": [2, 3]].mapping
        let entries = EBirdSpecies.tally(
            days: [
                (2024, ["mallar3", "redpol1", "unknown"]),
                (2024, ["mallar3", "mallar3"]),
                (2025, ["mallar3"]),
                (2025, []),
            ],
            indices: indices
        )
        #expect(entries == [
            Entry(index: 1, frequency: 0.75, years: 2),
            Entry(index: 2, frequency: 0.25, years: 1),
            Entry(index: 3, frequency: 0.25, years: 1),
        ])
    }

    @Test("two codes for one label count once a day")
    func tallyMergesCodes() {
        // An eBird split: both daughters are BirdNET's one label.
        let indices: (String) -> [Int] = ["amhgul1": [7], "eurhgul": [7]].mapping
        let entries = EBirdSpecies.tally(days: [(2025, ["amhgul1", "eurhgul"])], indices: indices)
        #expect(entries == [Entry(index: 7, frequency: 1, years: 1)])
    }

    @Test("a region needs half its days well reported")
    func coverage() {
        #expect(EBirdSpecies.isWellCovered(speciesPerDay: [50, 40, 0, 3]))
        #expect(!EBirdSpecies.isWellCovered(speciesPerDay: [50, 9, 0, 3]))
        #expect(!EBirdSpecies.isWellCovered(speciesPerDay: []))
    }

    // MARK: tiers

    @Test("common, rare, one-year and notable species land in the right tiers")
    func tiers() {
        let (allowed, rare) = EBirdSpecies.tiers(
            [
                Entry(index: 1, frequency: 0.9, years: 3),   // common
                Entry(index: 2, frequency: 0.05, years: 3),  // rare: seldom
                Entry(index: 3, frequency: 0.5, years: 1),   // rare: one year's chased vagrant
            ],
            sampledYears: 3,
            notable: [1, 4]
        )
        #expect(allowed == [1, 2, 3, 4])
        #expect(rare == [2, 3, 4], "a notable sighting of a common bird leaves it common")
    }
}

private extension Dictionary where Key == String, Value == [Int] {
    var mapping: (String) -> [Int] { { self[$0] ?? [] } }
}
