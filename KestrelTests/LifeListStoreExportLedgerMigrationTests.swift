import Foundation
import Testing
@testable import Kestrel

/// The eBird export ledger following a species whose scientific name
/// canonicalization moves.
///
/// The ledger remembers which sightings have already been handed to eBird, and
/// it is keyed on `EBirdCSVExporter.key` — which leads with the scientific name.
/// Canonicalization *renames* entries: the alias table rewrites post-split eBird
/// names, trinomials collapse to their binomial, and two spellings of one bird
/// merge onto the catalog's. A key left under the old spelling matches nothing
/// the exporter builds afterwards, so the sighting reads as never sent, and the
/// next "Export New Observations" writes it again.
///
/// That is the one failure in this app with no undo. eBird does no deduplication
/// whatsoever, so the second copy becomes real data in the user's account that
/// they unpick by hand, checklist by checklist.
///
/// `starredNames` — the other thing keyed by scientific name and persisted apart
/// from the life list — has followed renames since it shipped; the ledger simply
/// wasn't wired up. Both now go through `migrateRenamedState`, and this suite is
/// the ledger's half of `LifeListStoreStarMigrationTests`.
///
/// Driven through `load()` and `importEBird` rather than against the private
/// migration, for the reason those suites give: these passes run unconditionally
/// on every launch, and a test that reached inside wouldn't notice them being
/// wired up wrong.
@Suite("LifeListStore export ledger migration")
@MainActor
struct LifeListStoreExportLedgerMigrationTests {

    private let may4 = utcDay(2026, 5, 4)
    private let may5 = utcDay(2026, 5, 5)

    /// A sighting Kestrel recorded itself — the only kind the ledger is ever
    /// consulted about, since an imported one is refused by `isNewToEBird` before
    /// the ledger is reached.
    private func native(_ date: Date) -> LifeListEntry.Observation {
        .at(date, "Sapsucker Woods", lat: 42.45342, lon: -76.47352, imported: false)
    }

    private func key(_ scientificName: String, _ observation: LifeListEntry.Observation) -> String {
        EBirdCSVExporter.key(scientificName: scientificName, observation: observation)
    }

    /// Whether a `.newOnly` export would write this sighting — the question the
    /// whole ledger exists to answer, asked the way the exporter asks it.
    private func wouldExport(
        _ store: LifeListStore,
        _ scientificName: String,
        _ observation: LifeListEntry.Observation
    ) -> Bool {
        LifeListStore.isNewToEBird(
            .init(
                scientificName: scientificName,
                commonName: "irrelevant",
                observation: observation
            ),
            exportedKeys: store.exportedObservationKeys
        )
    }

    // MARK: the three ways a name moves

    /// The alias table. A user recorded and exported a bird under eBird's
    /// spelling; the launch that adds the alias rewrites the entry onto BirdNET's.
    @Test("the ledger follows an alias rewrite")
    func ledgerFollowsAliasRewrite() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let sighting = native(may4)
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker", [sighting]),
        ])
        try scratch.writeExportedKeys([key("Leuconotopicus villosus", sighting)])

        let store = makeStore(scratch, defaults)

        #expect(store.entries[0].scientificName == "Dryobates villosus", "the name moved")
        #expect(
            store.exportedObservationKeys.contains(key("Dryobates villosus", sighting)),
            "and the ledger came with it"
        )
        #expect(
            !wouldExport(store, "Dryobates villosus", sighting),
            "so Export New still knows eBird has this record"
        )
    }

    /// A trinomial collapsing to its binomial is the same rename by another
    /// route, and `collapseToSpecies` reports it from one place — so this covers
    /// both its relabel and its merge branch.
    @Test("the ledger follows a trinomial collapsing to its binomial")
    func ledgerFollowsSubspeciesCollapse() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let sighting = native(may4)
        try scratch.writeLifeList([
            .make("Dryobates villosus harrisi", "Hairy Woodpecker (Pacific)", [sighting]),
        ])
        try scratch.writeExportedKeys([key("Dryobates villosus harrisi", sighting)])

        let store = makeStore(scratch, defaults)

        #expect(store.entries[0].scientificName == "Dryobates villosus")
        #expect(!wouldExport(store, "Dryobates villosus", sighting))
    }

    /// Two spellings of one bird merging on an import — the path that reaches the
    /// ledger through `importEBird` rather than `load()`. Both call
    /// `migrateRenamedState`; this is what says so.
    @Test("the ledger follows a merge onto the other spelling during an import")
    func ledgerFollowsMergeOnImport() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let sighting = native(may4)
        try scratch.writeLifeList([
            .make("Zzz zzz", "Fictional Bird", [sighting]),
        ])
        try scratch.writeExportedKeys([key("Zzz zzz", sighting)])

        let store = makeStore(scratch, defaults)
        #expect(store.entries[0].scientificName == "Zzz zzz", "nothing moved it on load")

        let csv = scratch.url.appendingPathComponent("import.csv")
        try eBirdCSV([
            (sci: "Aaa aaa", common: "Fictional Bird", date: "2026-05-05",
             location: "B" as String?, lat: 2.0 as Double?, lon: 2.0 as Double?),
        ]).write(to: csv)
        _ = try await store.importEBird(from: csv)

        let survivor = store.entries[0].scientificName
        #expect(store.entries.count == 1, "the two spellings merged")
        #expect(survivor != "Zzz zzz", "onto the other spelling")
        #expect(
            !wouldExport(store, survivor, sighting),
            "and the already-uploaded sighting is still recognized as sent"
        )
    }

    // MARK: what the migration must not do

    /// Additive, exactly like `migrateStars`. The old key describes a record eBird
    /// still holds, and this is the one piece of state whose loss can't be undone
    /// — so a rename adds a key, it never trades one away.
    @Test("the old key is kept alongside the new one")
    func migrationIsAdditive() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let sighting = native(may4)
        let oldKey = key("Leuconotopicus villosus", sighting)
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker", [sighting]),
        ])
        try scratch.writeExportedKeys([oldKey])

        let store = makeStore(scratch, defaults)

        #expect(store.exportedObservationKeys.contains(oldKey))
        #expect(store.exportedObservationKeys.count == 2)
    }

    /// A ledger written by an earlier build is full of the legacy (raw-location)
    /// key format, and `hasBeenExported` reads both. The migration has to move
    /// both too, or the compatibility read starts finding nothing the moment a
    /// name changes.
    @Test("a legacy-format key follows the rename as well")
    func legacyKeysMigrateToo() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        // A place name `sanitize` folds, so the two key formats genuinely differ.
        let sighting = LifeListEntry.Observation.at(
            may4, "Ithaca, NY", lat: 42.45342, lon: -76.47352, imported: false
        )
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker", [sighting]),
        ])
        try scratch.writeExportedKeys([
            EBirdCSVExporter.legacyKey(
                scientificName: "Leuconotopicus villosus", observation: sighting
            ),
        ])

        let store = makeStore(scratch, defaults)

        #expect(store.entries[0].scientificName == "Dryobates villosus")
        #expect(
            !wouldExport(store, "Dryobates villosus", sighting),
            "the legacy key still answers for the renamed species"
        )
    }

    /// A launch that moves nothing must not rewrite the ledger file — the
    /// overwhelmingly common case, and the one where a stray write would be pure
    /// cost on every launch.
    @Test("a launch with nothing to migrate leaves the ledger alone")
    func nothingToMigrateWritesNothing() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let sighting = native(may4)
        try scratch.writeLifeList([
            .make("Dryobates villosus", "Hairy Woodpecker", [sighting]),
        ])
        try scratch.writeExportedKeys([key("Dryobates villosus", sighting)])

        let store = makeStore(scratch, defaults)
        store.flushPendingWrites()

        #expect(store.exportedObservationKeys.count == 1, "nothing was added")
        #expect(try scratch.readExportedKeys().count == 1)
    }

    /// Running the same migration twice adds nothing the second time: the moved
    /// key is filed under the new name, which no longer matches the rename. This
    /// is what makes it safe on every launch rather than only the first.
    @Test("re-launching over a migrated ledger adds nothing")
    func migrationIsIdempotentAcrossLaunches() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let sighting = native(may4)
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker", [sighting]),
        ])
        try scratch.writeExportedKeys([key("Leuconotopicus villosus", sighting)])

        let first = makeStore(scratch, defaults)
        first.flushPendingWrites()
        let afterFirst = first.exportedObservationKeys

        // The life list on disk now holds the canonical name, so the second launch
        // has no rename to follow at all.
        let second = makeStore(scratch, defaults)
        #expect(second.exportedObservationKeys == afterFirst)
    }

    /// The migration only moves keys belonging to the species that was renamed.
    /// A ledger holds one entry per *sighting* across the whole life list, so a
    /// rename that touched anything else would be corrupting records for birds it
    /// was never about.
    @Test("keys for other species are untouched")
    func otherSpeciesAreUntouched() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let moved = native(may4)
        let untouched = native(may5)
        let cardinalKey = key("Cardinalis cardinalis", untouched)
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker", [moved]),
            .make("Cardinalis cardinalis", "Northern Cardinal", [untouched]),
        ])
        try scratch.writeExportedKeys([key("Leuconotopicus villosus", moved), cardinalKey])

        let store = makeStore(scratch, defaults)

        #expect(store.exportedObservationKeys.contains(cardinalKey))
        #expect(
            store.exportedObservationKeys.count == 3,
            "one key added for the renamed bird, and nothing else disturbed"
        )
    }

    // MARK: the user-visible shape of the bug

    /// End to end, in the terms the user experiences: record a bird, export it,
    /// then let a launch rename the species. Without the migration the very next
    /// Export New writes that sighting again, and eBird ends up holding two.
    @Test("a renamed species' exported sighting is not offered again")
    func exportNewDoesNotReoffterARenamedSighting() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let sighting = native(may4)
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker", [sighting]),
        ])
        try scratch.writeExportedKeys([key("Leuconotopicus villosus", sighting)])

        let store = makeStore(scratch, defaults)
        let payload = await store.makeEBirdExport(scope: .newOnly)

        #expect(
            payload.observationCount == 0,
            "the file would have handed eBird a second copy of a record it holds"
        )
    }
}
