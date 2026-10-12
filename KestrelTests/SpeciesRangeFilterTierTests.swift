import Foundation
import Testing
@testable import Kestrel

/// How location-model scores become the recording filter's tiers, and that the
/// bundled models and their label map line up.
@Suite("Species range filter tiers")
struct SpeciesRangeFilterTierTests {

    @Test("scores split into common, rare and out of range")
    func tiers() {
        let common = SpeciesRangeFilter.commonThreshold
        let range = SpeciesRangeFilter.rangeThreshold
        let tiers = SpeciesRangeFilter.tiers(
            scores: [common, common.nextDown, range, range.nextDown, 0], isBird: { _ in true }
        )
        #expect(tiers.allowed == [0, 1, 2])
        #expect(tiers.rare == [1, 2])
    }

    @Test("only birds make the lists, whatever they score")
    func birdsOnly() {
        let tiers = SpeciesRangeFilter.tiers(scores: [1, 0.1, 1, 0.1], isBird: { $0 < 2 })
        #expect(tiers.allowed == [0, 1])
        #expect(tiers.rare == [1])
    }

    @Test("the catalog's non-birds are the noise classes and the 90 other animals")
    func nonBirds() {
        let catalog = SpeciesCatalog.shared
        #expect(catalog.nonBirdIndices.count == BirdNETClassifier.nonBirdLabels.count + 90)
        for name in ["Lithobates catesbeianus", "Canis latrans", "Apis mellifera", "Acris crepitans", "Human vocal"] {
            #expect(!catalog.isBird(scientificName: name), "\(name)")
        }
        for name in ["Turdus migratorius", "Larus argentatus", "Parus minor"] {
            #expect(catalog.isBird(scientificName: name), "\(name)")
        }
        #expect(catalog.isBird(scientificName: "Leuconotopicus villosus"), "a name outside the catalog is a bird")
    }

    @Test("the v2.4 model's thresholds land on the geomodel's")
    func legacyCalibration() {
        #expect(SpeciesRangeFilter.calibratedLegacy(0.03) == SpeciesRangeFilter.commonThreshold)
        #expect(SpeciesRangeFilter.calibratedLegacy(0.003) == SpeciesRangeFilter.rangeThreshold)
        #expect(SpeciesRangeFilter.calibratedLegacy(0) == 0)
        #expect(SpeciesRangeFilter.calibratedLegacy(1) == 1)
        #expect(SpeciesRangeFilter.calibratedLegacy(-1) == 0)
        let increasing = stride(from: Float(0), through: 1, by: 0.001).map(SpeciesRangeFilter.calibratedLegacy)
        #expect(zip(increasing, increasing.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("Current's weeks are this week and one either side, wrapping")
    func currentWeeks() {
        let calendar = Calendar(identifier: .gregorian)
        let newYear = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2))!
        let october = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10))!
        #expect(TargetsModel.weeks(for: .current, now: newYear) == [48, 1, 2])
        #expect(TargetsModel.weeks(for: .current, now: october) == [37, 38, 39])
        #expect(TargetsModel.weeks(for: .anyTime).count == 48)
    }

    /// Runs the bundled models. A label map shifted by one line would put every
    /// species on its neighbour's score, which this catches: Portland in
    /// October has these birds every day, and has no Hawaiian honeycreepers.
    @Test("the bundled models put Portland's October birds in range")
    func portland() async throws {
        let filter = try SpeciesRangeFilter()
        let tiers = try await filter.tiers(lat: 45.52, lon: -122.68, week: 38)
        let catalog = SpeciesCatalog.shared
        func index(_ name: String) -> Int { catalog.indexByScientificName[name]! }
        for regular in ["Setophaga townsendi", "Strix varia", "Catharus ustulatus", "Larus argentatus", "Tyto alba"] {
            #expect(tiers.allowed.contains(index(regular)), "\(regular)")
        }
        for common in ["Corvus brachyrhynchos", "Anas platyrhynchos", "Poecile atricapillus"] {
            #expect(tiers.allowed.contains(index(common)) && !tiers.rare.contains(index(common)), "\(common)")
        }
        for absent in ["Palmeria dolei", "Corvus hawaiiensis", "Parus minor"] {
            #expect(!tiers.allowed.contains(index(absent)), "\(absent)")
        }
        #expect(tiers.allowed.allSatisfy(catalog.isBird), "no frogs, insects or mammals")
    }

    /// The bundled grid answers as the live models do, near enough: the same
    /// Portland birds, and only birds.
    @Test("the bundled offline grid has Portland's October birds")
    func offlineGrid() throws {
        let tiers = try #require(OfflineSpeciesFilter.shared.tiers(lat: 45.52, lon: -122.68, week: 38))
        let catalog = SpeciesCatalog.shared
        for regular in ["Setophaga townsendi", "Catharus ustulatus", "Corvus brachyrhynchos"] {
            #expect(tiers.allowed.contains(catalog.indexByScientificName[regular]!), "\(regular)")
        }
        #expect(tiers.rare.isSubset(of: tiers.allowed))
        #expect(!tiers.rare.isEmpty)
        #expect(tiers.allowed.allSatisfy(catalog.isBird))
    }
}
