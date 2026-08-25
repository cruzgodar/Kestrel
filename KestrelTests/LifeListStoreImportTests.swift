import Foundation
import Testing
@testable import Kestrel

/// eBird CSV import: the merge, the tally it reports, and — the point of the
/// whole thing — idempotency. eBird's import tool does **no** deduplication, so
/// the app's own must be exact: re-importing the same export cannot double a
/// user's history, and a round trip out to eBird and back cannot either.
@Suite("LifeListStore import")
@MainActor
struct LifeListStoreImportTests {

    private func importCSV(
        _ store: LifeListStore,
        _ scratch: ScratchDirectory,
        _ rows: [(sci: String, common: String, date: String, location: String?, lat: Double?, lon: Double?)]
    ) async throws -> LifeListStore.ImportSummary {
        let url = scratch.url.appendingPathComponent("import-\(UUID().uuidString).csv")
        try eBirdCSV(rows).write(to: url)
        return try await store.importEBird(from: url)
    }

    // MARK: idempotency

    @Test("re-importing the same export changes nothing")
    func reimportIsIdempotent() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        let rows: [(String, String, String, String?, Double?, Double?)] = [
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "Sapsucker Woods", 42.4791, -76.4512),
            ("Cardinalis cardinalis", "Northern Cardinal", "2020-06-01", "Ithaca", 42.4400, -76.5000),
            ("Turdus migratorius", "American Robin", "2019-05-04", "Sapsucker Woods", 42.4791, -76.4512),
        ]

        let first = try await importCSV(store, scratch, rows)
        #expect(first.added == 2)
        #expect(first.newObservations == 3)
        let afterFirst = store.entries

        let second = try await importCSV(store, scratch, rows)
        #expect(second.added == 0)
        #expect(second.gained == 0)
        #expect(second.revised == 0)
        #expect(second.newObservations == 0)
        #expect(second.skipped == 2, "both species were named and had nothing new to say")
        #expect(store.entries == afterFirst, "a re-import must not touch a single record")
    }

    @Test("importing the same file ten times leaves one copy of each sighting")
    func repeatedImportsDoNotAccumulate() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        let rows: [(String, String, String, String?, Double?, Double?)] = [
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "Sapsucker Woods", 42.4791, -76.4512),
        ]
        for _ in 0..<10 {
            _ = try await importCSV(store, scratch, rows)
        }
        #expect(store.totalObservationCount == 1)
    }

    /// The round trip the app explicitly recommends: export to eBird, then import
    /// your eBird data back. The CSV carries coordinates at five decimals and
    /// cannot carry a comma in a place name, so the sighting that comes back is
    /// *not byte-identical* to the one that went out — and if identity compared
    /// the raw values it would be filed as a second observation.
    @Test("a sighting exported to eBird and re-imported does not duplicate")
    func eBirdRoundTripDoesNotDuplicate() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)

        // Recorded in Kestrel, at full CoreLocation precision, in a place whose
        // name contains the one character the CSV can't carry.
        store.recordObservation(
            scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal",
            date: utcDay(2026, 5, 4), location: "Ithaca, NY",
            latitude: 42.4534198, longitude: -76.4735178
        )
        #expect(store.totalObservationCount == 1)

        // Render the real export, then feed its own values back as eBird would.
        let payload = await store.makeEBirdExport(scope: .newOnly)
        let exported = parseExportedCSV(payload)[0]
        let summary = try await importCSV(store, scratch, [(
            sci: "Cardinalis cardinalis", common: exported[0], date: "2026-05-04",
            location: exported[5], lat: Double(exported[6]), lon: Double(exported[7])
        )])

        #expect(store.totalObservationCount == 1, "the round trip must not double the record")
        #expect(store.entries.count == 1)
        #expect(summary.newObservations == 0)
        #expect(summary.skipped == 1)
    }

    /// And the provenance consequence: after the round trip eBird demonstrably
    /// holds the record, so the next Export New must not offer it again.
    @Test("a re-imported sighting stops being offered to eBird")
    func roundTrippedSightingIsNoLongerNew() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(
            scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal",
            date: utcDay(2026, 5, 4), location: "Ithaca, NY",
            latitude: 42.4534198, longitude: -76.4735178
        )
        _ = try await importCSV(store, scratch, [(
            sci: "Cardinalis cardinalis", common: "Northern Cardinal", date: "2026-05-04",
            location: "Ithaca NY", lat: 42.45342, lon: -76.47352
        )])
        #expect(store.observationCount(for: .newOnly) == 0,
                "eBird has it — sending it again would be a duplicate on their side")
    }

    // MARK: merging

    @Test("a CSV that has grown since last time files the new rows only")
    func growingCSVAddsOnlyNewRows() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        let original: [(String, String, String, String?, Double?, Double?)] = [
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "A", 1.0, 1.0),
        ]
        _ = try await importCSV(store, scratch, original)

        let grown = original + [
            ("Cardinalis cardinalis", "Northern Cardinal", "2021-07-04", "B", 2.0, 2.0),
        ]
        let summary = try await importCSV(store, scratch, grown)
        #expect(summary.added == 0, "the species was already on the list")
        #expect(summary.gained == 1)
        #expect(summary.newObservations == 1)
        #expect(store.totalObservationCount == 2)
    }

    @Test("an earlier row displaces the displayed first-seen fields")
    func earlierRowPromoted() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        _ = try await importCSV(store, scratch, [
            ("Cardinalis cardinalis", "Northern Cardinal", "2020-05-04", "Later", 2.0, 2.0),
        ])
        _ = try await importCSV(store, scratch, [
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-01-01", "Earlier", 1.0, 1.0),
        ])
        #expect(store.entries[0].firstSeen == utcDay(2019, 1, 1))
        #expect(store.entries[0].firstLocation == "Earlier")
    }

    /// Every imported row is marked as coming from eBird, so the export never
    /// hands it back.
    @Test("imported sightings are marked imported and never offered to eBird")
    func importedRowsAreMarked() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        _ = try await importCSV(store, scratch, [
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "A", 1.0, 1.0),
            ("Cardinalis cardinalis", "Northern Cardinal", "2020-05-04", "B", 2.0, 2.0),
        ])
        #expect(store.entries[0].allObservations.allSatisfy { $0.isImported })
        #expect(store.observationCount(for: .newOnly) == 0)
        #expect(store.observationCount(for: .everything) == 2)
    }

    /// A bird recorded in Kestrel and later restated by an import is one
    /// observation, not two — but eBird now has it, so provenance flips.
    @Test("an import over a Kestrel-native sighting merges and flips provenance")
    func importOverNativeSighting() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal",
                                date: utcDay(2019, 5, 4), location: "Sapsucker Woods",
                                latitude: 42.4791, longitude: -76.4512)
        _ = try await importCSV(store, scratch, [
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "Sapsucker Woods", 42.4791, -76.4512),
        ])
        #expect(store.totalObservationCount == 1)
        #expect(store.entries[0].firstIsImported)
        #expect(store.observationCount(for: .newOnly) == 0)
    }

    @Test("stars are re-stamped after a wipe-and-reimport")
    func starsRestampedOnImport() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.setStarred(scientificName: "Cardinalis cardinalis", isStarred: true)
        store.removeAll()

        _ = try await importCSV(store, scratch, [
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "A", 1.0, 1.0),
        ])
        #expect(store.entries[0].isStarred, "the user's alert-me choice outlives the wipe")
    }

    @Test("import canonicalizes names immediately, not on the next launch")
    func importCanonicalizes() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        _ = try await importCSV(store, scratch, [
            ("Leuconotopicus villosus", "Hairy Woodpecker", "2019-05-04", "A", 1.0, 1.0),
        ])
        #expect(store.entries[0].scientificName == "Dryobates villosus",
                "otherwise the image slug misses and the row shows a placeholder until relaunch")
    }

    /// Canonicalization can fold an eBird spelling onto a species already on the
    /// list. Counting *rows* would report that as a species added when the list
    /// didn't grow at all.
    @Test("a name folded onto an existing species is not counted as added")
    func foldedNameNotCountedAsAdded() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        _ = try await importCSV(store, scratch, [
            ("Dryobates villosus", "Hairy Woodpecker", "2019-05-04", "A", 1.0, 1.0),
        ])
        let summary = try await importCSV(store, scratch, [
            ("Leuconotopicus villosus", "Hairy Woodpecker", "2020-05-04", "B", 2.0, 2.0),
        ])
        #expect(store.entries.count == 1)
        #expect(summary.added == 0, "the list did not grow")
        #expect(summary.gained == 1)
    }

    @Test("speciesNames is refreshed by an import")
    func importRefreshesMembership() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        _ = try await importCSV(store, scratch, [
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "A", 1.0, 1.0),
            ("Turdus migratorius", "American Robin", "2019-05-04", "A", 1.0, 1.0),
        ])
        #expect(store.speciesNames == Set(store.entries.map(\.scientificName)))
        #expect(store.speciesNames.count == 2)
    }

    // MARK: the summary

    /// The tally is what the user is told happened, so each bucket has to mean
    /// exactly one thing.
    @Test("a first import reports every species as added")
    func summaryFirstImport() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        let summary = try await importCSV(store, scratch, [
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "A", 1.0, 1.0),
            ("Cardinalis cardinalis", "Northern Cardinal", "2020-05-04", "B", 2.0, 2.0),
            ("Turdus migratorius", "American Robin", "2019-05-04", "A", 1.0, 1.0),
        ])
        #expect(summary.added == 2)
        #expect(summary.gained == 0)
        #expect(summary.revised == 0)
        #expect(summary.skipped == 0)
        #expect(summary.newObservations == 3)
        #expect(summary.speciesWithNewObservations == 2)
    }

    /// The bucket that used to be conflated. A species whose displayed first
    /// sighting was displaced but which gained no rows contributed nothing to
    /// `newObservations` — so counting it among the species behind that number
    /// overstated the import, and when it was *all* the import did, the whole
    /// clause was suppressed and the user was told "Nothing new to import" over a
    /// list whose first-seen dates had just moved.
    @Test("a revised earliest sighting is reported separately from gained ones")
    func summarySeparatesRevisedFromGained() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)

        // A Kestrel-native sighting, at coordinates the import will not repeat.
        store.recordObservation(scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal",
                                date: utcDay(2020, 5, 4), location: "Later", latitude: 5, longitude: 5)

        // One earlier row: it displaces the displayed fields *and* is a new record.
        let gainedSummary = try await importCSV(store, scratch, [
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-01-01", "Earlier", 1.0, 1.0),
        ])
        #expect(gainedSummary.gained == 1, "it gained a row, so it counts there")
        #expect(gainedSummary.revised == 0, "and not twice")
        #expect(gainedSummary.newObservations == 1)
        #expect(gainedSummary.speciesWithNewObservations == 1)
    }

    /// The precise shape of the bug: a species whose displayed first sighting
    /// moves while its observation *count* stays put.
    ///
    /// Reaching it takes the import's dedupe absorbing a record as it adds one.
    /// The user recorded the same sighting twice on purpose (which the app allows
    /// — every user-write path passes `dedupe: false`), then imported a CSV with
    /// an earlier row. The import is the one place that *does* dedupe, so it
    /// collapses their duplicate pair as it files the new row: one in, one out,
    /// net zero.
    ///
    /// Under the old single bucket that species was counted as "updated" and
    /// contributed 0 to `newObservations` — which suppressed the whole "Added N
    /// observations" clause and reported **"Nothing new to import"** over an
    /// import that had just moved the user's first-seen date back two years.
    @Test("an import that only moves the first-seen date still reports what it did")
    func summaryReportsRevisedOnlyImport() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)

        // Two deliberate, identical records — a bird seen twice at one spot.
        for _ in 0..<2 {
            store.recordObservation(scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal",
                                    date: utcDay(2021, 5, 5), location: "Same Place",
                                    latitude: 1, longitude: 1)
        }
        #expect(store.totalObservationCount == 2)

        let summary = try await importCSV(store, scratch, [
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-01-01", "Earlier Place", 2.0, 2.0),
        ])

        // Net zero: the pair collapsed as the earlier row was filed.
        #expect(store.totalObservationCount == 2)
        #expect(summary.gained == 0, "no net gain in records")
        #expect(summary.newObservations == 0)
        #expect(summary.revised == 1, "but the displayed first sighting moved, and that is worth saying")
        #expect(summary.speciesWithNewObservations == 0, "nothing to spread a count across")

        // And it really did move.
        #expect(store.entries[0].firstSeen == utcDay(2019, 1, 1))
        #expect(store.entries[0].firstLocation == "Earlier Place")
    }

    /// Dedupe is scoped to the species the CSV actually mentioned.
    ///
    /// For a mentioned species, `observations` is two independent record sets
    /// unioned, and collapsing the overlap is right. For every other species it is
    /// just what was already stored — no second set, nothing to be a duplicate
    /// *of* — so collapsing there silently destroys records the user entered by
    /// hand. Two deliberate sightings of one bird at one spot became one because
    /// an import that never named that bird happened to run.
    @Test("an import only dedupes the species it names")
    func importDedupeIsScopedToNamedSpecies() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)

        // Three deliberate, identical records — legitimate, and every user-write
        // path preserves them.
        for _ in 0..<3 {
            store.recordObservation(scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal",
                                    date: utcDay(2021, 5, 5), location: "Same Place",
                                    latitude: 1, longitude: 1)
        }
        #expect(store.totalObservationCount == 3)

        // An import about a completely different bird must not touch them.
        _ = try await importCSV(store, scratch, [
            ("Turdus migratorius", "American Robin", "2019-01-01", "Elsewhere", 2.0, 2.0),
        ])
        #expect(store.totalObservationCount == 4,
                "an import that never named the cardinal must leave its records alone")
        #expect(store.entries.first { $0.scientificName == "Cardinalis cardinalis" }?
            .allObservations.count == 3)

        // Naming it *is* a union of two record sets, so now the overlap collapses.
        _ = try await importCSV(store, scratch, [
            ("Cardinalis cardinalis", "Northern Cardinal", "2021-05-05", "Same Place", 1.0, 1.0),
        ])
        #expect(store.entries.first { $0.scientificName == "Cardinalis cardinalis" }?
            .allObservations.count == 1,
            "naming it folds the identical records together — that is what makes a re-import idempotent")
    }

    @Test("an unrelated import leaves untouched species byte-identical")
    func unrelatedImportLeavesEntriesUntouched() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal",
                                date: utcDay(2021, 5, 5), location: "A", latitude: 1, longitude: 1)
        store.recordObservation(scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal",
                                date: utcDay(2021, 5, 5), location: "A", latitude: 1, longitude: 1)
        let before = store.entries.first { $0.scientificName == "Cardinalis cardinalis" }

        _ = try await importCSV(store, scratch, [
            ("Turdus migratorius", "American Robin", "2019-01-01", "Elsewhere", 2.0, 2.0),
        ])
        #expect(store.entries.first { $0.scientificName == "Cardinalis cardinalis" } == before)
    }

    @Test("speciesWithNewObservations never counts a species that gained nothing")
    func summaryDenominatorIsHonest() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        _ = try await importCSV(store, scratch, [
            ("A a", "Alpha", "2019-05-04", "P", 1.0, 1.0),
            ("B b", "Beta", "2019-05-04", "P", 1.0, 1.0),
        ])
        // Second import: A gains a row, B says nothing new.
        let summary = try await importCSV(store, scratch, [
            ("A a", "Alpha", "2021-05-04", "Q", 2.0, 2.0),
            ("B b", "Beta", "2019-05-04", "P", 1.0, 1.0),
        ])
        #expect(summary.added == 0)
        #expect(summary.gained == 1)
        #expect(summary.skipped == 1)
        #expect(summary.speciesWithNewObservations == 1, "not 2 — B gained nothing")
        #expect(summary.newObservations == 1)
    }

    /// Species the CSV never mentioned are not part of the tally at all — the
    /// rest of the life list is untouched and has nothing to report.
    @Test("species the CSV never named are not counted as skipped")
    func untouchedSpeciesNotCounted() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "Zzz zzz", commonName: "Never Mentioned",
                                date: utcDay(2019, 5, 4), location: "P", latitude: 1, longitude: 1)
        let summary = try await importCSV(store, scratch, [
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "A", 1.0, 1.0),
        ])
        #expect(summary.added == 1)
        #expect(summary.skipped == 0)
    }

    @Test("an empty CSV is a no-op with an all-zero tally")
    func emptyImport() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        let summary = try await importCSV(store, scratch, [])
        #expect(summary.added == 0 && summary.gained == 0 && summary.revised == 0)
        #expect(summary.skipped == 0 && summary.newObservations == 0)
        #expect(store.entries.isEmpty)
    }

    // MARK: persistence

    @Test("an import reaches disk")
    func importPersists() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        do {
            let store = makeStore(scratch, defaults)
            _ = try await importCSV(store, scratch, [
                ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "Sapsucker Woods", 42.4791, -76.4512),
            ])
            store.flushPendingWrites()
        }
        let reopened = makeStore(scratch, defaults)
        #expect(reopened.entries.count == 1)
        #expect(reopened.entries[0].firstIsImported)
    }
}
