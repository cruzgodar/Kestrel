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


    // MARK: collision resolution

    /// Canonicalization resolves a collision it can't otherwise break by keeping
    /// whichever entry it met **first** — `collapseByCommonName` takes
    /// `existing.scientificName`, and the two spelling collapses pick a common
    /// name the same way. Each of those passes keeps an explicit insertion-order
    /// array so it doesn't introduce any order dependence of its own; what none of
    /// them can do is fix the order they were handed.
    ///
    /// `load()` always handed over a decoded file, in stored order. The import
    /// merge handed over a `Dictionary.map`, and Swift randomizes dictionary
    /// iteration per process — so which scientific name a bird survived an import
    /// under was a coin flip between launches. That name is the entry's `id`, its
    /// photo slug, and what a BirdNET detection matches against.
    ///
    /// Two invented names, so neither is in the BirdNET catalog and the catalog
    /// can't break the tie for us — which is precisely the case that fell through
    /// to "whoever came first".
    private static let collidingRows: [(String, String, String, String?, Double?, Double?)] = [
        ("Fakea alpha", "Testudo Warbler", "2019-05-04", "Sapsucker Woods", 42.4791, -76.4512),
        ("Fakea beta", "Testudo Warbler", "2020-06-01", "Ithaca", 42.4400, -76.5000),
    ]

    @Test("an unbreakable collision on import resolves by the entry order, not the dictionary's")
    func importCollisionResolvesDeterministically() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        _ = try await importCSV(store, scratch, Self.collidingRows)

        #expect(store.entries.count == 1, "one bird, two spellings, one entry")
        // `ordersBefore` is newest-`firstSeen` first, so the 2020 spelling leads
        // the sorted set and is the one canonicalization meets first. The merged
        // entry still carries both sightings, so its own `firstSeen` is the 2019
        // one — the name and the date come from different halves, which is exactly
        // why the name has to be pinned by something.
        #expect(store.entries[0].scientificName == "Fakea beta")
        #expect(store.entries[0].firstSeen == utcDay(2019, 5, 4))
        #expect(store.entries[0].allObservations.count == 2)
    }

    @Test("the row order in the file doesn't change which spelling survives")
    func importCollisionIgnoresRowOrder() async throws {
        var survivors: [String] = []
        for rows in [Self.collidingRows, Self.collidingRows.reversed()] {
            let scratch = ScratchDirectory(), defaults = ScratchDefaults()
            let store = makeStore(scratch, defaults)
            _ = try await importCSV(store, scratch, Array(rows))
            survivors.append(store.entries[0].scientificName)
        }
        #expect(survivors == ["Fakea beta", "Fakea beta"])
    }

    /// The same collision reached the other way round: one spelling already on the
    /// list, the other arriving in the CSV. The merge seeds its accumulator from
    /// the stored entries first, so this is a different insertion history — and it
    /// has to land on the same answer.
    @Test("a collision against a stored entry resolves the same way")
    func importCollisionAgainstStoredEntry() async throws {
        for storedFirst in [true, false] {
            let scratch = ScratchDirectory(), defaults = ScratchDefaults()
            let stored = Self.collidingRows[storedFirst ? 0 : 1]
            let incoming = Self.collidingRows[storedFirst ? 1 : 0]
            // Each spelling keeps its own date, so the two entries stay orderable
            // — pinning both to one date would leave `ordersBefore` tiebreaking on
            // the scientific name instead, which is a different rule than the one
            // under test.
            let storedDate = storedFirst ? utcDay(2019, 5, 4) : utcDay(2020, 6, 1)
            try scratch.writeLifeList([
                .make(
                    stored.0, stored.1,
                    [.at(storedDate, stored.3, lat: stored.4, lon: stored.5, imported: true)]
                )
            ])
            let store = makeStore(scratch, defaults)
            #expect(store.entries.count == 1)
            _ = try await importCSV(store, scratch, [incoming])
            #expect(store.entries.count == 1)
            #expect(
                store.entries[0].scientificName == "Fakea beta",
                "whichever side it arrived from"
            )
        }
    }

    /// The whole point of pinning the order to `ordersBefore`: an import resolves
    /// a collision exactly the way a `load()` of the finished data would, so the
    /// entry doesn't change identity on the next launch.
    @Test("the surviving spelling survives the next launch unchanged")
    func importCollisionSurvivesReload() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let afterImport: [LifeListEntry]
        do {
            let store = makeStore(scratch, defaults)
            _ = try await importCSV(store, scratch, Self.collidingRows)
            afterImport = store.entries
            store.flushPendingWrites()
        }
        let reopened = makeStore(scratch, defaults)
        #expect(reopened.entries == afterImport)
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

    /// `touchedKeys` is keyed on the names the CSV used; the tally asks it about
    /// names as they come out of canonicalization. A row canonicalization
    /// rewrites therefore answered "the CSV never mentioned this species" about
    /// the species the CSV was entirely about, and the sole thing that import had
    /// to report went uncounted.
    ///
    /// The rename has to be one the **parser** doesn't already perform.
    /// `EBirdCSVParser` strips parentheticals, collapses trinomials and applies
    /// the alias table before a row ever reaches the merge, so an aliased name
    /// like "Astur cooperii" arrives already canonical and never exercises this.
    /// What survives the parser and still moves is `collapseByCommonName`'s final
    /// relabel: a scientific name the BirdNET catalog doesn't list whose *common*
    /// name it does. "Richmondena cardinalis" is a real former genus for the
    /// Northern Cardinal and is deliberately absent from the alias table — the
    /// table can't enumerate every synonym in existence, which is why that pass
    /// exists at all.
    @Test("a species the CSV named under a relabeled spelling still counts as skipped")
    func skippedCountsARelabeledSpelling() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        let rows: [(String, String, String, String?, Double?, Double?)] = [
            ("Richmondena cardinalis", "Northern Cardinal", "2019-05-04",
             "Sapsucker Woods", 42.4791, -76.4512),
        ]

        let first = try await importCSV(store, scratch, rows)
        #expect(first.added == 1)
        #expect(store.entries.map(\.scientificName) == ["Cardinalis cardinalis"],
                "canonicalization moved it, which is what makes this the interesting case")

        let second = try await importCSV(store, scratch, rows)
        #expect(second.added == 0 && second.gained == 0 && second.revised == 0)
        #expect(second.newObservations == 0)
        #expect(second.skipped == 1, "the CSV named it and it was already known")
    }

    /// The same undercount seen from the summary a user actually reads: every
    /// species in a re-imported file has to land in exactly one bucket, whether
    /// or not canonicalization moved its name.
    @Test("every species in a re-imported CSV is accounted for in the tally")
    func everyRelabeledSpeciesIsCounted() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        let rows: [(String, String, String, String?, Double?, Double?)] = [
            ("Richmondena cardinalis", "Northern Cardinal", "2019-05-04", "A", 42.47, -76.45),
            ("Turdus migratorius", "American Robin", "2019-05-05", "B", 42.48, -76.46),
        ]
        _ = try await importCSV(store, scratch, rows)
        let second = try await importCSV(store, scratch, rows)

        #expect(second.added + second.gained + second.revised + second.skipped == 2,
                "both rows' species have to land in exactly one bucket each")
        #expect(second.skipped == 2)
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

    // MARK: the eBird round trip

    /// The full loop the app tells users to run: record in Kestrel, export,
    /// upload to eBird, download your data months later, import it back. Every
    /// sighting has to recognize the copy that comes home, whatever it did or
    /// didn't have a place name for.
    ///
    /// The nameless cases are the ones that failed. eBird's Location Name column
    /// is required and Kestrel's place name is not, so the exporter fills one in
    /// — the coordinates, or a placeholder — and *that* is what comes back.
    /// Identity compared the raw stored name, so the returning copy didn't match
    /// the sighting it came from and was filed as a second observation: a
    /// duplicate pin on the map and a doubled "N Observations".
    @Test(
        "a sighting survives the export/re-import round trip",
        arguments: [
            ("named", "Sapsucker Woods", 42.4534198, -76.4735178),
            ("named with a comma", "Ithaca, NY", 42.4534198, -76.4735178),
            ("nameless with coordinates", nil, 42.4534198, -76.4735178),
            ("nameless without coordinates", nil, nil, nil),
        ] as [(String, String?, Double?, Double?)]
    )
    func exportReimportRoundTrip(
        label: String, place: String?, latitude: Double?, longitude: Double?
    ) async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(
            scientificName: "Cardinalis cardinalis",
            commonName: "Northern Cardinal",
            date: utcDay(2026, 5, 4),
            location: place,
            latitude: latitude,
            longitude: longitude
        )
        #expect(store.totalObservationCount == 1)

        // Take the place name from the file itself rather than restating it, so
        // this can't drift from what the exporter actually writes.
        let payload = await store.makeEBirdExport(scope: .everything)
        let exported = parseExportedCSV(payload)
        #expect(exported.count == 1)

        // eBird hands back what it was given.
        _ = try await importCSV(store, scratch, [(
            sci: "Cardinalis cardinalis",
            common: "Northern Cardinal",
            date: "2026-05-04",
            location: exported[0][5],
            lat: latitude,
            lon: longitude
        )])

        #expect(
            store.totalObservationCount == 1,
            "\(label): the re-imported copy must fold into the sighting it came from"
        )
        #expect(store.entries.count == 1)
    }

    /// The round trip must not go the other way either: a sighting Kestrel never
    /// exported is genuinely new to the list and has to survive the import.
    @Test("a genuinely new sighting still arrives on the same import")
    func roundTripDoesNotSwallowNewRecords() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(
            scientificName: "Cardinalis cardinalis",
            commonName: "Northern Cardinal",
            date: utcDay(2026, 5, 4),
            location: nil,
            latitude: 42.4534198,
            longitude: -76.4735178
        )
        let payload = await store.makeEBirdExport(scope: .everything)
        let exportedPlace = parseExportedCSV(payload)[0][5]

        _ = try await importCSV(store, scratch, [
            // The returning copy of what we just exported…
            ("Cardinalis cardinalis", "Northern Cardinal", "2026-05-04", exportedPlace, 42.4534198, -76.4735178),
            // …plus a sighting only eBird knows about.
            ("Cardinalis cardinalis", "Northern Cardinal", "2026-06-01", "Mundy Wildflower Garden", 42.4500, -76.4700),
        ])
        #expect(store.totalObservationCount == 2)
    }

    // MARK: writes racing the merge

    /// Tracks whether the import under test has finished, so the writer below
    /// knows when to stop. Main-actor isolated by the project's default, which is
    /// what makes it safe to share with the import's own task.
    @MainActor
    private final class Latch {
        var done = false
    }

    /// The merge runs off the main actor precisely so the UI stays live during a
    /// large import — which means the user can go on recording sightings while it
    /// runs. Assigning the merged result wholesale threw those away: the merge
    /// described a life list that no longer existed.
    ///
    /// The writes are a *stream*, not a single one at a hopefully-right moment.
    /// The import has several suspension points (the parse, then each merge
    /// attempt) and only the window between a merge's snapshot and its
    /// write-back is the dangerous one; a lone write timed with `Task.yield()`
    /// lands in the parse instead and passes against the bug. Writing throughout
    /// guarantees the window is hit, whatever the internal shape turns out to be.
    @Test("sightings recorded during an import are not lost")
    func writeDuringImportSurvives() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)

        // Big enough that the merge takes long enough to write into.
        let rows = (0..<4000).map { i in
            (
                sci: "Genus sp\(i)x", common: "Bird \(i)", date: "2026-05-04",
                location: "Ithaca NY" as String?,
                lat: 42.0 + Double(i) / 100_000 as Double?, lon: -76.0 as Double?
            )
        }
        let url = scratch.url.appendingPathComponent("big.csv")
        try eBirdCSV(rows).write(to: url)

        let latch = Latch()
        async let importing: Void = { @MainActor in
            _ = try? await store.importEBird(from: url)
            latch.done = true
        }()

        var recorded: [String] = []
        while !latch.done {
            let name = "Testus sp\(recorded.count)x"
            store.recordObservation(
                scientificName: name,
                commonName: "Test Bird \(recorded.count)",
                date: utcDay(2026, 5, 4),
                location: "My Yard",
                latitude: 42.45342,
                longitude: -76.47352
            )
            recorded.append(name)
            try await Task.sleep(for: .milliseconds(5))
        }
        await importing

        #expect(!recorded.isEmpty, "the import has to run long enough to write into")
        let lost = recorded.filter { !store.contains(scientificName: $0) }
        #expect(lost.isEmpty, "\(lost.count) of \(recorded.count) sightings were dropped by the merge")
        #expect(store.entries.count == rows.count + recorded.count, "and the import still landed")
        #expect(recorded.allSatisfy { store.speciesNames.contains($0) })
    }

    /// The re-merge has to *terminate*. A writer faster than the merge would
    /// retry forever, which is why the last attempt runs inline on the main actor
    /// where nothing can interleave. This is that case, driven deliberately: the
    /// loop above writes every 5 ms against a merge that takes far longer.
    @Test("an import racing a continuous writer still completes", .timeLimit(.minutes(1)))
    func importTerminatesUnderContinuousWrites() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        let rows = (0..<4000).map { i in
            (
                sci: "Genus sp\(i)x", common: "Bird \(i)", date: "2026-05-04",
                location: "Ithaca NY" as String?, lat: 42.0 as Double?, lon: -76.0 as Double?
            )
        }
        let url = scratch.url.appendingPathComponent("big.csv")
        try eBirdCSV(rows).write(to: url)

        let latch = Latch()
        async let importing: Void = { @MainActor in
            _ = try? await store.importEBird(from: url)
            latch.done = true
        }()
        var written = 0
        while !latch.done {
            written += 1
            store.recordObservation(
                scientificName: "Testus sp\(written)x", commonName: "T\(written)",
                date: utcDay(2026, 5, 4), location: "Yard", latitude: 1, longitude: 1
            )
            try await Task.sleep(for: .milliseconds(1))
        }
        await importing
        #expect(latch.done, "the import must finish rather than retrying forever")
        #expect(store.entries.count == rows.count + written)
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

/// The import summary's "before" side: what the life list held for each species,
/// keyed by the name that species comes out of canonicalization under.
///
/// The tally is measured against the *finished* entry set rather than against the
/// CSV's row names, because canonicalization can fold an eBird spelling onto a
/// species already on the list. That only works if the "before" lookup follows
/// the same renames the finished names went through — `touchedKeys` does, and
/// this is the half that didn't.
@Suite("Import tally priors")
@MainActor
struct ImportTallyPriorTests {

    private let may4 = utcDay(2019, 5, 4)
    private let jun1 = utcDay(2020, 6, 1)

    @Test("an untouched name is keyed by itself")
    func passesThroughWithoutRenames() {
        let entry = LifeListEntry.make(
            "Cardinalis cardinalis", "Northern Cardinal",
            [.at(may4, "Sapsucker Woods"), .at(jun1, "Ithaca")]
        )
        let priors = LifeListStore.priorEntries([entry], renames: [:])
        #expect(priors.count == 1)
        #expect(priors["Cardinalis cardinalis"]?.observationCount == 2)
        #expect(priors["Cardinalis cardinalis"]?.first.date == may4)
    }

    /// The fix. A species canonicalization re-files has to be found under its new
    /// name, or the tally compares a species against nothing and calls it new.
    @Test("a renamed species is found under the name it came out under")
    func followsARename() {
        let entry = LifeListEntry.make("Astur cooperii", "Cooper's Hawk", [.at(may4, "Ithaca")])
        let priors = LifeListStore.priorEntries(
            [entry], renames: ["Astur cooperii": "Accipiter cooperii"]
        )
        #expect(priors["Accipiter cooperii"]?.observationCount == 1)
        #expect(priors["Astur cooperii"] == nil, "the old name describes nothing now")
    }

    /// Two entries can land on one name — that is what a rename-and-merge *is* —
    /// and the merged entry holds both their sightings, so the prior has to as
    /// well or the import would look like it grew the species by the size of the
    /// entry it absorbed.
    @Test("two entries merging onto one name sum their sightings")
    func mergesCollidingPriors() {
        let kept = LifeListEntry.make("Accipiter cooperii", "Cooper's Hawk", [.at(jun1, "Ithaca")])
        let moved = LifeListEntry.make("Astur cooperii", "Cooper's Hawk", [.at(may4, "Sapsucker Woods")])
        let priors = LifeListStore.priorEntries(
            [kept, moved], renames: ["Astur cooperii": "Accipiter cooperii"]
        )
        #expect(priors.count == 1)
        #expect(priors["Accipiter cooperii"]?.observationCount == 2)
        // The earlier of the two is what `LifeListEntry.make` would promote, so
        // it is what the merged entry's `firstSeen` will read — and therefore what
        // "did the earliest sighting change?" has to be asked against.
        #expect(priors["Accipiter cooperii"]?.first.date == may4)
    }
}

/// The tally reported for an import that canonicalization re-files a species
/// during — the case where the "before" and "after" names differ.
@Suite("Import tally across a rename")
@MainActor
struct ImportTallyRenameTests {

    /// A life-list entry under a scientific name the BirdNET catalog doesn't
    /// carry, whose common name it doesn't carry either — so nothing on the
    /// launch path relabels it and it survives `load()` as it was stored. That is
    /// the only state from which an *import* can move an existing entry's name.
    private static let strandedEntry = LifeListEntry.make(
        "Fakea gamma", "Testudo Warbler",
        [.at(utcDay(2020, 6, 1), "Ithaca", lat: 42.44, lon: -76.50)]
    )

    /// The same bird, spelled the way the catalog spells it, on an earlier date so
    /// the stored entry is the one canonicalization meets first — which is what
    /// makes it the entry that gets moved rather than the one that stays put.
    private static let incomingRow: [(String, String, String, String?, Double?, Double?)] = [
        ("Cardinalis cardinalis", "Testudo Warbler", "2019-05-04", "Sapsucker Woods", 42.4791, -76.4512),
    ]

    /// The regression. `collapseByCommonName` prefers the name BirdNET emits, so
    /// the surviving entry is filed under the *imported* spelling — a name the
    /// life list didn't hold before. The tally's "what did we have?" lookup was
    /// keyed by the pre-import name, found nothing, and reported a bird the user
    /// had recorded last year as new to their life list, with every sighting it
    /// had ever held counted as freshly added.
    @Test("a species the import re-files is not reported as new")
    func renamedSpeciesIsNotNew() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeLifeList([Self.strandedEntry])
        let store = makeStore(scratch, defaults)
        #expect(store.entries.map(\.scientificName) == ["Fakea gamma"], "the entry survived load()")

        let url = scratch.url.appendingPathComponent("import.csv")
        try eBirdCSV(Self.incomingRow).write(to: url)
        let summary = try await store.importEBird(from: url)

        // One bird, one entry, under the catalog's spelling.
        #expect(store.entries.count == 1)
        #expect(store.entries[0].scientificName == "Cardinalis cardinalis")
        #expect(store.entries[0].allObservations.count == 2)

        #expect(summary.added == 0, "the user already had this bird, under another name")
        #expect(summary.gained == 1)
        #expect(
            summary.newObservations == 1,
            "one row was written, not the whole entry over again"
        )
    }
}
