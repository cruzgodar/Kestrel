import Foundation
import Testing
@testable import Kestrel

/// The rewrite of every stored sighting onto the UTC-midnight invariant.
///
/// `ObservationDate.canonical` on its own is **not idempotent** — it reads a
/// date's day in the device's current time zone, so a second pass over an
/// already-canonical date lands on the day before for anyone west of UTC. The
/// migration therefore gates every date on `ObservationDate.isCanonical` and is
/// safe to run any number of times.
///
/// That gate is the correctness guarantee; the `UserDefaults` flag is only an
/// optimization. It used to be the other way round, and couldn't be: the flag
/// lands in `UserDefaults` while the migrated list lands on the store's IO queue,
/// and nothing orders the two — so a kill between them can lose either one. The
/// direction that mattered, data written and flag lost, re-ran the migration and
/// shifted the user's whole life list back a day.
@Suite("LifeListStore date migration")
@MainActor
struct LifeListStoreMigrationTests {

    private static let flagKey = "lifeList.datesNormalizedToUTC"

    /// A store that has *not* had the migration marked done, so `load()` runs it.
    private func unmigratedStore(_ scratch: ScratchDirectory, _ defaults: ScratchDefaults) -> LifeListStore {
        LifeListStore(directory: scratch.url, defaults: defaults.defaults)
    }

    @Test("a legacy list is rewritten to midnight UTC on first load")
    func migrationRewritesDates() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        // A wall-clock instant, the shape v1.0 wrote.
        let legacy = instant(2019, 5, 4, 14, 30, zone: .current)
        try scratch.writeLifeList([
            .make(scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal",
                  isStarred: false,
                  observations: [
                    .at(legacy, "Sapsucker Woods", lat: 42.4791, lon: -76.4512),
                    .at(instant(2020, 6, 1, 9, 15, zone: .current), "Ithaca", lat: 1, lon: 1),
                  ],
                  dedupe: false),
        ])

        let store = unmigratedStore(scratch, defaults)
        let dates = store.entries[0].allObservations.map(\.date)
        for date in dates {
            #expect(isMidnightUTC(date), "every stored date must sit at midnight UTC")
        }
        #expect(store.entries[0].firstSeen == ObservationDate.canonical(legacy))
    }

    /// From the user's side the migration is a no-op: a row that said "May 4,
    /// 2019" still says it.
    @Test("the displayed day is unchanged by the migration")
    func migrationPreservesDisplayedDay() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let legacy = instant(2019, 5, 4, 23, 45, zone: .current)

        var localFormatter = DateFormatter()
        localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.calendar = Calendar(identifier: .gregorian)
        localFormatter.timeZone = .current
        localFormatter.dateFormat = "yyyy-MM-dd"
        let dayBefore = localFormatter.string(from: legacy)

        try scratch.writeLifeList([
            .make(scientificName: "X y", commonName: "X", isStarred: false,
                  observations: [.at(legacy, "P", lat: 1, lon: 1)], dedupe: false),
        ])
        let store = unmigratedStore(scratch, defaults)
        #expect(ObservationDate.isoDay(store.entries[0].firstSeen) == dayBefore)
    }

    /// The export ledger's existing keys must still match, or an
    /// already-uploaded sighting looks new and eBird takes a second copy.
    @Test("migrated dates still match their pre-migration ledger keys")
    func migrationPreservesLedgerKeys() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let legacy = instant(2019, 5, 4, 18, 0, zone: .current)

        // The key the old build would have written: local day, raw coordinates.
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.calendar = Calendar(identifier: .gregorian)
        localFormatter.timeZone = .current
        localFormatter.dateFormat = "yyyy-MM-dd"
        let legacyKey = [
            "Cardinalis cardinalis",
            localFormatter.string(from: legacy),
            "Sapsucker Woods",
            String(format: "%.5f", 42.4791),
            String(format: "%.5f", -76.4512),
        ].joined(separator: "|")

        try scratch.writeLifeList([
            .make(scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal",
                  isStarred: false,
                  observations: [.at(legacy, "Sapsucker Woods", lat: 42.4791, lon: -76.4512, imported: false)],
                  dedupe: false),
        ])
        try scratch.writeExportedKeys([legacyKey])

        let store = unmigratedStore(scratch, defaults)
        let migratedKey = EBirdCSVExporter.key(
            scientificName: "Cardinalis cardinalis",
            observation: store.entries[0].allObservations[0]
        )
        #expect(migratedKey == legacyKey, "nothing already sent to eBird may look new again")
        #expect(store.observationCount(for: .newOnly) == 0)
    }

    // MARK: running exactly once

    @Test("the migration sets its flag and does not run again")
    func migrationRunsOnce() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeLifeList([
            .make(scientificName: "X y", commonName: "X", isStarred: false,
                  observations: [.at(instant(2019, 5, 4, 14, zone: .current), "P", lat: 1, lon: 1)],
                  dedupe: false),
        ])

        let first = unmigratedStore(scratch, defaults)
        let afterMigration = first.entries[0].firstSeen
        #expect(defaults.defaults.bool(forKey: Self.flagKey))
        first.flushPendingWrites()

        // Every subsequent launch must leave the dates exactly where they are.
        for _ in 0..<5 {
            let reopened = unmigratedStore(scratch, defaults)
            #expect(reopened.entries[0].firstSeen == afterMigration,
                    "re-running a non-idempotent migration would shift the day")
            reopened.flushPendingWrites()
        }
    }

    /// The crash window the flag cannot close, exercised directly: the migrated
    /// list reaches disk but the `UserDefaults` write is lost, so the next launch
    /// runs the migration over data that has already been through it.
    ///
    /// This is what used to corrupt a life list. `normalizeDates` re-applied
    /// `ObservationDate.canonical` unconditionally, and on any device west of UTC
    /// that read midnight-UTC back as the previous local day and stored midnight
    /// UTC on *that* — every sighting in the Americas one day earlier, the export
    /// ledger's keys no longer matching, and the next "Export New Observations"
    /// handing eBird a duplicate of the user's history.
    ///
    /// Correct on any machine: where the device is on UTC the migration is the
    /// identity anyway, and everywhere else this fails without the
    /// `isCanonical` gate.
    @Test("the migration survives a lost flag")
    func migrationSurvivesALostFlag() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeLifeList([
            .make(scientificName: "X y", commonName: "X", isStarred: false,
                  observations: [
                    .at(instant(2019, 5, 4, 14, zone: .current), "P", lat: 1, lon: 1),
                    .at(instant(2021, 8, 9, 22, zone: .current), "Q", lat: 2, lon: 2),
                  ],
                  dedupe: false),
        ])

        let first = unmigratedStore(scratch, defaults)
        let migrated = first.entries[0].allObservations.map(\.date).sorted()
        #expect(migrated.allSatisfy(isMidnightUTC))
        first.flushPendingWrites()

        // The data landed; the flag didn't. Re-open five times in a row, each one
        // believing it still has the migration to do.
        for pass in 1...5 {
            defaults.defaults.removeObject(forKey: Self.flagKey)
            let reopened = unmigratedStore(scratch, defaults)
            let now = reopened.entries[0].allObservations.map(\.date).sorted()
            #expect(now == migrated, "pass \(pass) moved the dates")
            reopened.flushPendingWrites()
            #expect(try scratch.readLifeList()[0].allObservations.map(\.date).sorted() == migrated,
                    "pass \(pass) wrote shifted dates back to disk")
        }
    }

    /// The ledger half of the same scenario. A shifted day changes the key, and a
    /// key that stops matching is unrecoverable — eBird does no deduplication, so
    /// the next export hands over a second copy of records already uploaded.
    @Test("a repeated migration leaves the export ledger's keys matching")
    func repeatedMigrationPreservesLedgerKeys() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeLifeList([
            .make(scientificName: "X y", commonName: "X", isStarred: false,
                  observations: [.at(instant(2019, 5, 4, 14, zone: .current), "P", lat: 1, lon: 1)],
                  dedupe: false),
        ])
        let first = unmigratedStore(scratch, defaults)
        let key = EBirdCSVExporter.key(
            scientificName: "X y", observation: first.entries[0].allObservations[0]
        )
        first.flushPendingWrites()
        try scratch.writeExportedKeys([key])

        defaults.defaults.removeObject(forKey: Self.flagKey)
        let reopened = unmigratedStore(scratch, defaults)
        let after = EBirdCSVExporter.key(
            scientificName: "X y", observation: reopened.entries[0].allObservations[0]
        )
        #expect(after == key)
        #expect(reopened.observationCount(for: .newOnly) == 0,
                "a re-migrated sighting must not look new to eBird again")
    }

    @Test("a fresh install marks the migration done without touching anything")
    func freshInstallMarksMigrated() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        #expect(!defaults.defaults.bool(forKey: Self.flagKey))
        let store = unmigratedStore(scratch, defaults)
        #expect(store.entries.isEmpty)
        #expect(defaults.defaults.bool(forKey: Self.flagKey),
                "a fresh install writes canonical dates from its first sighting on")
    }

    /// The ordinary already-migrated launch: the flag is set, so the pass is
    /// skipped outright. `migrationSurvivesALostFlag` covers the case where it
    /// isn't and the pass runs anyway.
    @Test("an already-migrated install leaves its dates alone")
    func migratedInstallUntouched() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let canonical = utcDay(2019, 5, 4)
        try scratch.writeLifeList([
            .make(scientificName: "X y", commonName: "X", isStarred: false,
                  observations: [.at(canonical, "P", lat: 1, lon: 1)], dedupe: false),
        ])
        defaults.defaults.set(true, forKey: Self.flagKey)

        let store = unmigratedStore(scratch, defaults)
        #expect(store.entries[0].firstSeen == canonical)
    }

    @Test("the migrated list is written back to disk")
    func migrationPersists() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeLifeList([
            .make(scientificName: "X y", commonName: "X", isStarred: false,
                  observations: [.at(instant(2019, 5, 4, 14, zone: .current), "P", lat: 1, lon: 1)],
                  dedupe: false),
        ])
        let store = unmigratedStore(scratch, defaults)
        store.flushPendingWrites()

        let onDisk = try scratch.readLifeList()
        #expect(isMidnightUTC(onDisk[0].firstSeen))
    }

    @Test("the migration reaches every repeat observation, not just the first")
    func migrationCoversRepeats() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let observations = (0..<6).map { i in
            LifeListEntry.Observation.at(
                instant(2019, 5, 4 + i, 13 + i, zone: .current), "P\(i)", lat: 1, lon: 1
            )
        }
        try scratch.writeLifeList([
            .make(scientificName: "X y", commonName: "X", isStarred: false,
                  observations: observations, dedupe: false),
        ])
        let store = unmigratedStore(scratch, defaults)
        #expect(store.entries[0].allObservations.count == 6)
        for observation in store.entries[0].allObservations {
            #expect(isMidnightUTC(observation.date))
        }
    }

    /// Ordering has to survive, or an entry's earliest sighting could stop being
    /// its earliest — and the migration deliberately doesn't re-promote.
    @Test("the migration preserves which sighting is earliest")
    func migrationPreservesEarliest() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeLifeList([
            .make(scientificName: "X y", commonName: "X", isStarred: false,
                  observations: [
                    .at(instant(2019, 5, 4, 23, zone: .current), "Earliest", lat: 1, lon: 1),
                    .at(instant(2019, 5, 5, 1, zone: .current), "Middle", lat: 2, lon: 2),
                    .at(instant(2021, 1, 1, 12, zone: .current), "Latest", lat: 3, lon: 3),
                  ],
                  dedupe: false),
        ])
        let store = unmigratedStore(scratch, defaults)
        #expect(store.entries[0].firstLocation == "Earliest")
        #expect(store.entries[0].otherObservations.map(\.location) == ["Middle", "Latest"])
    }

    /// The migration must not be a dedupe: two records that were distinct before
    /// it can land on the same day afterwards, and both still have to be there.
    @Test("the migration never collapses two records onto one")
    func migrationDoesNotDedupe() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        // Two sightings, same local day, different times — distinct instants
        // before the migration, identical after it.
        try scratch.writeLifeList([
            .make(scientificName: "X y", commonName: "X", isStarred: false,
                  observations: [
                    .at(instant(2019, 5, 4, 8, zone: .current), "Same Place", lat: 1, lon: 1),
                    .at(instant(2019, 5, 4, 17, zone: .current), "Same Place", lat: 1, lon: 1),
                  ],
                  dedupe: false),
        ])
        let store = unmigratedStore(scratch, defaults)
        #expect(store.entries[0].allObservations.count == 2,
                "a morning and an afternoon sighting are two records the user made")
    }
}
