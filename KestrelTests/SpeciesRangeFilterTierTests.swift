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

    // MARK: the geomodel's label map

    @Test("the label map keeps an output that maps to nothing in its place")
    func indexKeepsEmptyRows() throws {
        #expect(try SpeciesRangeFilter.parseGeomodelIndex("1,2\n\n3\n") == [[1, 2], [], [3]])
        #expect(try SpeciesRangeFilter.parseGeomodelIndex("1,2\n\n3") == [[1, 2], [], [3]],
                "no trailing newline")
        #expect(try SpeciesRangeFilter.parseGeomodelIndex("4\n\n") == [[4], []],
                "a last output that maps to nothing")
    }

    @Test("a label map naming a label outside the catalog is refused, not crashed on")
    func indexOutOfRange() {
        #expect(throws: (any Error).self) {
            try SpeciesRangeFilter.parseGeomodelIndex("1\n\(SpeciesRangeFilter.speciesCount)\n")
        }
        #expect(throws: (any Error).self) {
            try SpeciesRangeFilter.parseGeomodelIndex("-1\n")
        }
    }

    @Test("the bundled label map parses and has a row per geomodel output")
    func bundledIndex() throws {
        let url = try #require(Bundle.main.url(forResource: "geomodel_birdnet_index", withExtension: "txt"))
        let rows = try SpeciesRangeFilter.parseGeomodelIndex(String(contentsOf: url, encoding: .utf8))
        #expect(rows.count == 12_314)
    }

    // MARK: one week's scores

    private let speciesCount = SpeciesRangeFilter.speciesCount

    @Test("each label takes its output's score, a lump its likeliest daughter's")
    func scoresFromOutputs() throws {
        // Output 0 → label 5; outputs 1 and 2 both → label 7 (a lump); output 3 → nothing.
        let scores = try SpeciesRangeFilter.scores(
            geomodel: [0.4, 0.2, 0.6, 0.9],
            legacy: nil,
            geomodelIndices: [[5], [7], [7], []],
            uncovered: []
        )
        #expect(scores.count == speciesCount)
        #expect(scores[5] == 0.4)
        #expect(scores[7] == 0.6)
        #expect(scores.enumerated().allSatisfy { [5, 7].contains($0.offset) || $0.element == 0 })
    }

    @Test("labels no output covers take the v2.4 score, calibrated")
    func uncoveredFromLegacy() throws {
        var legacy = [Float](repeating: 0, count: speciesCount)
        legacy[9] = 0.03
        legacy[5] = 1   // covered by the geomodel, so ignored
        let scores = try SpeciesRangeFilter.scores(
            geomodel: [0.4],
            legacy: legacy,
            geomodelIndices: [[5]],
            uncovered: [9]
        )
        #expect(scores[9] == SpeciesRangeFilter.calibratedLegacy(0.03))
        #expect(scores[5] == 0.4)
    }

    @Test("a model that doesn't match its label map throws rather than misreading it")
    func mismatchedOutputs() {
        #expect(throws: (any Error).self, "one output short of the map") {
            try SpeciesRangeFilter.scores(
                geomodel: [0.4], legacy: nil, geomodelIndices: [[5], [7]], uncovered: []
            )
        }
        #expect(throws: (any Error).self, "one output past the map") {
            try SpeciesRangeFilter.scores(
                geomodel: [0.4, 0.2, 0.1], legacy: nil, geomodelIndices: [[5], [7]], uncovered: []
            )
        }
        #expect(throws: (any Error).self, "a v2.4 model of the wrong size") {
            try SpeciesRangeFilter.scores(
                geomodel: [0.4], legacy: [0.1, 0.2], geomodelIndices: [[5]], uncovered: [9]
            )
        }
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
