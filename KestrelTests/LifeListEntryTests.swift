import Foundation
import Testing
@testable import Kestrel

/// `LifeListEntry.make` and the entry's decoding defaults.
///
/// The rule under test — stated in `make`'s own doc comment and enforced at every
/// call site in `LifeListStore` — is that **collapsing identical sightings is
/// only ever right when two independent sets of records are being unioned**: an
/// import folding a CSV into what's stored, or two taxonomic spellings of one
/// species being merged. Every path where the *user* writes a sighting passes
/// `dedupe: false`, because two identical sightings are something a person can
/// legitimately record and an edit must never be able to make a record vanish.
///
/// Getting that backwards erodes the list a little at a time, on every launch,
/// silently — which is exactly why it is worth pinning down.
@Suite("LifeListEntry.make")
struct LifeListEntryMakeTests {

    private let may4 = utcDay(2026, 5, 4)
    private let may5 = utcDay(2026, 5, 5)
    private let may6 = utcDay(2026, 5, 6)

    // MARK: earliest promotion

    @Test("the earliest sighting becomes the displayed first-seen fields")
    func earliestPromoted() {
        let entry = LifeListEntry.make(
            "Cardinalis cardinalis", "Northern Cardinal",
            [
                .at(may6, "Late Place", lat: 3, lon: 3),
                .at(may4, "First Place", lat: 1, lon: 1),
                .at(may5, "Middle Place", lat: 2, lon: 2),
            ]
        )
        #expect(entry.firstSeen == may4)
        #expect(entry.firstLocation == "First Place")
        #expect(entry.firstLatitude == 1)
        #expect(entry.firstLongitude == 1)
        #expect(entry.otherObservations.count == 2)
        #expect(entry.otherObservations.map(\.date) == [may5, may6], "the rest stay in date order")
    }

    @Test("allObservations reconstitutes the displayed sighting alongside the rest")
    func allObservationsRoundTrips() {
        let observations: [LifeListEntry.Observation] = [
            .at(may4, "A", lat: 1, lon: 1, imported: true),
            .at(may5, "B", lat: 2, lon: 2),
            .at(may6, "C"),
        ]
        let entry = LifeListEntry.make("X y", "X", observations)
        #expect(entry.allObservations.count == 3)
        #expect(Set(entry.allObservations.map(\.identity)) == Set(observations.map(\.identity)))
        #expect(entry.allObservations.first?.isImported == true, "provenance rides along on the promoted one")
        #expect(entry.firstIsImported)
    }

    /// Feeding an entry's own `allObservations` back through `make` has to be a
    /// fixed point — the canonicalization pipeline does exactly this on every
    /// launch when it relabels an entry.
    @Test("make is a fixed point on an entry's own observations")
    func makeIsFixedPoint() {
        let entry = LifeListEntry.make(
            "X y", "X",
            [.at(may4, "A", lat: 1, lon: 1), .at(may5, "B"), .at(may6, "C", lat: 3, lon: 3)]
        )
        let again = LifeListEntry.make("X y", "X", entry.allObservations)
        #expect(again == entry)
    }

    // MARK: date ties

    /// On a date tie the more complete sighting is displayed. This reproduces the
    /// old "heal a coord-less earliest sighting from a same-date row" behavior —
    /// an import that supplies coordinates for a day you already had shouldn't
    /// leave the entry unmappable.
    @Test("on a date tie the sighting with coordinates is displayed")
    func tieBreaksOnCoordinates() {
        let entry = LifeListEntry.make(
            "X y", "X",
            [.at(may4, "No coords"), .at(may4, "With coords", lat: 1, lon: 1)]
        )
        #expect(entry.firstLatitude == 1)
        #expect(entry.firstLocation == "With coords")
    }

    @Test("on a date tie with neither having coordinates, a place name wins over none")
    func tieBreaksOnPlaceName() {
        let entry = LifeListEntry.make("X y", "X", [.at(may4), .at(may4, "Named")])
        #expect(entry.firstLocation == "Named")
    }

    @Test("coordinates outrank a place name in the completeness tie-break")
    func coordinatesOutrankName() {
        let entry = LifeListEntry.make(
            "X y", "X",
            [.at(may4, "Named but unplaced"), .at(may4, nil, lat: 1, lon: 1)]
        )
        #expect(entry.firstLatitude == 1)
        #expect(entry.firstLocation == nil)
    }

    // MARK: dedupe: false — the user's own records

    /// The case that motivated the rule. Correcting one imported sighting's date
    /// onto a same-place sibling's date produces two records with an identical
    /// identity; with dedupe on, one of them silently disappeared — no warning,
    /// no undo.
    @Test("identical sightings are kept when the user wrote them")
    func duplicatesKeptWithoutDedupe() {
        let duplicate = LifeListEntry.Observation.at(may4, "Same Place", lat: 1, lon: 1)
        let entry = LifeListEntry.make("X y", "X", [duplicate, duplicate])
        #expect(entry.allObservations.count == 2, "an edit must never make a record vanish")
    }

    @Test("several identical sightings all survive")
    func manyDuplicatesKept() {
        let duplicate = LifeListEntry.Observation.at(may4, "Same Place", lat: 1, lon: 1)
        let entry = LifeListEntry.make("X y", "X", Array(repeating: duplicate, count: 5))
        #expect(entry.allObservations.count == 5)
    }

    /// Two sightings the same day at the same place are a legitimate thing to
    /// record — a bird seen morning and afternoon — and the app has no
    /// finer-grained time to tell them apart with.
    @Test("same day, same place, recorded twice stays twice")
    func sameDaySamePlaceKept() {
        let entry = LifeListEntry.make(
            "X y", "X",
            [.at(may4, "Sapsucker Woods", lat: 42.4791, lon: -76.4512),
             .at(may4, "Sapsucker Woods", lat: 42.4791, lon: -76.4512)]
        )
        #expect(entry.allObservations.count == 2)
    }

    // MARK: dedupe: true — merging two sets of records

    @Test("identical sightings collapse when two record sets are unioned")
    func duplicatesCollapseWithDedupe() {
        let duplicate = LifeListEntry.Observation.at(may4, "Same Place", lat: 1, lon: 1)
        let entry = LifeListEntry.make(
            scientificName: "X y", commonName: "X", isStarred: false,
            observations: [duplicate, duplicate], dedupe: true
        )
        #expect(entry.allObservations.count == 1)
    }

    /// Dedupe keys on *identity*, so the fold that survives an eBird round trip
    /// applies here too: a stored sighting and its re-imported twin collapse.
    @Test("dedupe collapses a sighting against its re-imported twin")
    func dedupeFoldsRoundTrippedSighting() {
        let stored = LifeListEntry.Observation.at(may4, "Ithaca, NY", lat: 42.4534198, lon: -76.4735178)
        let reimported = LifeListEntry.Observation.at(may4, "Ithaca NY", lat: 42.45342, lon: -76.47352, imported: true)
        let entry = LifeListEntry.make(
            scientificName: "X y", commonName: "X", isStarred: false,
            observations: [stored, reimported], dedupe: true
        )
        #expect(entry.allObservations.count == 1)
    }

    /// The flags OR together: if any copy came from an import, eBird has it, and
    /// sending it back would duplicate a record the account already holds.
    @Test("collapsing ORs provenance toward imported")
    func collapseORsProvenance() {
        let native = LifeListEntry.Observation.at(may4, "P", lat: 1, lon: 1, imported: false)
        let imported = LifeListEntry.Observation.at(may4, "P", lat: 1, lon: 1, imported: true)
        for pair in [[native, imported], [imported, native]] {
            let entry = LifeListEntry.make(
                scientificName: "X y", commonName: "X", isStarred: false,
                observations: pair, dedupe: true
            )
            #expect(entry.allObservations.count == 1)
            #expect(entry.allObservations[0].isImported, "if any copy came from eBird, eBird has it")
        }
    }

    @Test("collapsing preserves first-seen order among the survivors")
    func collapsePreservesOrder() {
        let a = LifeListEntry.Observation.at(may4, "A", lat: 1, lon: 1)
        let b = LifeListEntry.Observation.at(may5, "B", lat: 2, lon: 2)
        let c = LifeListEntry.Observation.at(may6, "C", lat: 3, lon: 3)
        let entry = LifeListEntry.make(
            scientificName: "X y", commonName: "X", isStarred: false,
            observations: [c, a, b, a, c, b], dedupe: true
        )
        #expect(entry.allObservations.map(\.date) == [may4, may5, may6])
    }

    @Test("dedupe leaves genuinely distinct sightings alone")
    func dedupeDoesNotOverMerge() {
        let entry = LifeListEntry.make(
            scientificName: "X y", commonName: "X", isStarred: false,
            observations: [
                .at(may4, "A", lat: 1, lon: 1),
                .at(may4, "B", lat: 1, lon: 1),
                .at(may5, "A", lat: 1, lon: 1),
                .at(may4, "A", lat: 2, lon: 1),
            ],
            dedupe: true
        )
        #expect(entry.allObservations.count == 4)
    }

    // MARK: edges

    @Test("an entry built from no observations still has a usable first-seen date")
    func emptyObservations() {
        let entry = LifeListEntry.make("X y", "X", [])
        #expect(entry.otherObservations.isEmpty)
        #expect(entry.firstLocation == nil)
        #expect(!entry.firstIsImported)
    }

    @Test("the star flag rides through unchanged")
    func starPreserved() {
        #expect(LifeListEntry.make("X y", "X", [.at(may4)], starred: true).isStarred)
        #expect(!LifeListEntry.make("X y", "X", [.at(may4)], starred: false).isStarred)
    }

    @Test("id is the scientific name")
    func idIsScientificName() {
        #expect(LifeListEntry.make("Cardinalis cardinalis", "Northern Cardinal", [.at(may4)]).id
                == "Cardinalis cardinalis")
    }
}

/// Decoding defaults. Both `isImported` flags default to **true** for rows
/// written before provenance was tracked, and the asymmetry is deliberate:
/// wrongly calling an old sighting Kestrel-native duplicates a record in eBird,
/// which is the whole thing the flag exists to prevent, while wrongly calling one
/// imported just means reaching for "Export All Observations" once.
@Suite("LifeListEntry decoding")
struct LifeListEntryDecodingTests {

    private func decode(_ json: String) throws -> LifeListEntry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LifeListEntry.self, from: Data(json.utf8))
    }

    @Test("a legacy entry with no provenance decodes as imported")
    func legacyEntryIsImported() throws {
        let entry = try decode("""
        {"scientificName":"Cardinalis cardinalis","commonName":"Northern Cardinal",
         "firstSeen":"2019-05-04T00:00:00Z"}
        """)
        #expect(entry.firstIsImported, "the safe default: assume eBird already has it")
        #expect(!entry.isStarred)
        #expect(entry.otherObservations.isEmpty)
        #expect(entry.firstLocation == nil)
        #expect(entry.firstLatitude == nil)
    }

    @Test("a legacy repeat observation with no provenance decodes as imported")
    func legacyObservationIsImported() throws {
        let entry = try decode("""
        {"scientificName":"X y","commonName":"X","firstSeen":"2019-05-04T00:00:00Z",
         "otherObservations":[{"date":"2020-05-04T00:00:00Z"}]}
        """)
        #expect(entry.otherObservations.count == 1)
        #expect(entry.otherObservations[0].isImported)
    }

    @Test("an explicit provenance flag is honored in both directions")
    func explicitProvenanceHonored() throws {
        let native = try decode("""
        {"scientificName":"X y","commonName":"X","firstSeen":"2019-05-04T00:00:00Z",
         "firstIsImported":false,
         "otherObservations":[{"date":"2020-05-04T00:00:00Z","isImported":false}]}
        """)
        #expect(!native.firstIsImported)
        #expect(!native.otherObservations[0].isImported)
    }

    @Test("optional fields survive a full round trip")
    func fullRoundTrip() throws {
        let original = LifeListEntry.make(
            scientificName: "Cardinalis cardinalis",
            commonName: "Northern Cardinal",
            isStarred: true,
            observations: [
                .at(utcDay(2019, 5, 4), "Ithaca NY", lat: 42.45342, lon: -76.47352, imported: true),
                .at(utcDay(2020, 6, 1), nil, lat: nil, lon: nil, imported: false),
            ],
            dedupe: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(LifeListEntry.self, from: encoder.encode(original))
        #expect(restored == original)
    }
}
