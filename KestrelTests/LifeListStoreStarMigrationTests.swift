import Foundation
import Testing
@testable import Kestrel

/// Stars following a species whose scientific name canonicalization moves.
///
/// `starredNames` is keyed by scientific name and persisted separately from the
/// life list, so it can outlive an entry — that is what lets a star survive a
/// wipe-and-reimport. But canonicalization *renames* entries: the alias table
/// rewrites post-split eBird names, trinomials collapse to their binomial, and
/// two spellings of one bird merge onto the catalog's. Every one of those
/// OR-merges `isStarred` onto the survivor, and `applyStarsToEntries` then
/// re-stamps every entry from the set — which was still keyed to the old name.
///
/// So the re-stamp didn't merely fail to notice the star, it cleared the one the
/// merge had just carried over: a bird the user had asked to be alerted about
/// went quiet on the launch its name moved, and its row showed an empty star with
/// nothing anywhere to say why. Every test here would have failed on that.
///
/// Driven through `load()` and `importEBird` rather than against the private
/// statics, for the reason `LifeListStoreCanonicalizationTests` gives: these
/// passes run unconditionally, and a test that reached inside wouldn't notice
/// them being wired up wrong.
@Suite("LifeListStore star migration")
@MainActor
struct LifeListStoreStarMigrationTests {

    private let may4 = utcDay(2026, 5, 4)
    private let may5 = utcDay(2026, 5, 5)

    // MARK: the three ways a name moves

    /// The alias table. A user who imported before an alias existed has the entry
    /// stored — and starred — under eBird's spelling; the launch that adds the
    /// alias rewrites it.
    @Test("a star follows an alias rewrite")
    func starFollowsAliasRewrite() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars(["Leuconotopicus villosus"])
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker",
                  [.at(may4, "Sapsucker Woods", lat: 42.45, lon: -76.47)], starred: true),
        ])

        let store = makeStore(scratch, defaults)

        #expect(store.entries.count == 1)
        #expect(store.entries[0].scientificName == "Dryobates villosus")
        #expect(store.entries[0].isStarred, "the row still shows its star")
        #expect(store.starredNames.contains("Dryobates villosus"),
                "and the classifier alerts on the name BirdNET actually emits")
    }

    /// A trinomial collapsing to its binomial is the same rename by a different
    /// route, and `collapseToSpecies` reports it from one place so both the
    /// relabel and the merge branch are covered.
    @Test("a star follows a trinomial collapsing to its binomial")
    func starFollowsSubspeciesCollapse() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars(["Dryobates villosus harrisi"])
        try scratch.writeLifeList([
            .make("Dryobates villosus harrisi", "Hairy Woodpecker",
                  [.at(may4, "A", lat: 1, lon: 1)], starred: true),
        ])

        let store = makeStore(scratch, defaults)

        #expect(store.entries[0].scientificName == "Dryobates villosus")
        #expect(store.entries[0].isStarred)
        #expect(store.starredNames.contains("Dryobates villosus"))
    }

    /// Two spellings of one bird merging. The star is on the spelling that
    /// *loses* — the surviving name is the catalog's — so nothing but the rename
    /// map can carry it across.
    @Test("a star on the losing spelling survives a common-name merge")
    func starFollowsCommonNameMerge() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars(["Leuconotopicus villosus"])
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker",
                  [.at(may5, "Old genus", lat: 1, lon: 1)], starred: true),
            .make("Dryobates villosus", "Hairy Woodpecker",
                  [.at(may4, "New genus", lat: 2, lon: 2)]),
        ])

        let store = makeStore(scratch, defaults)

        #expect(store.entries.count == 1)
        #expect(store.entries[0].scientificName == "Dryobates villosus")
        #expect(store.entries[0].isStarred)
        #expect(store.starredNames.contains("Dryobates villosus"))
    }

    // MARK: persistence + repeat launches

    /// The migration has to reach the stars *file*, not just the in-memory set —
    /// otherwise every launch would re-derive it, and the launch after the entry
    /// was deleted would have nothing left to derive it from.
    @Test("the migrated star is written to the stars file")
    func migrationIsPersisted() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars(["Astur cooperii"])
        try scratch.writeLifeList([
            .make("Astur cooperii", "Cooper's Hawk", [.at(may4, "A", lat: 1, lon: 1)], starred: true),
        ])

        let store = makeStore(scratch, defaults)
        store.flushPendingWrites()

        let onDisk = try scratch.readStars()
        #expect(onDisk.contains("Accipiter cooperii"))
    }

    /// A second launch over the already-migrated data finds nothing left to
    /// rename — the entry is stored under the new name — so it neither re-runs
    /// the migration nor loses the star.
    @Test("a second launch over migrated data changes nothing")
    func migrationIsOneShot() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars(["Leuconotopicus villosus"])
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker",
                  [.at(may4, "A", lat: 1, lon: 1)], starred: true),
        ])
        makeStore(scratch, defaults).flushPendingWrites()

        let relaunched = makeStore(scratch, defaults)
        #expect(relaunched.entries[0].scientificName == "Dryobates villosus")
        #expect(relaunched.entries[0].isStarred)
    }

    /// The reason the old name is *kept* rather than removed has to not cost
    /// anything: unstarring after a migration must stick. It does, because the
    /// unstar removes the current name and the next launch has nothing left to
    /// rename — so there is no path back from the retired name to the live one.
    @Test("unstarring after a migration is not undone by the next launch")
    func unstarSticksAfterMigration() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars(["Leuconotopicus villosus"])
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker",
                  [.at(may4, "A", lat: 1, lon: 1)], starred: true),
        ])

        let store = makeStore(scratch, defaults)
        store.setStarred(scientificName: "Dryobates villosus", isStarred: false)
        store.flushPendingWrites()

        let relaunched = makeStore(scratch, defaults)
        #expect(!relaunched.entries[0].isStarred, "it stays unstarred")
        #expect(!relaunched.starredNames.contains("Dryobates villosus"))
    }

    // MARK: what it must not do

    /// The migration is keyed on names that actually moved. An entry whose name
    /// canonicalization leaves alone must come out exactly as the set says —
    /// including *unstarred*, which is the property `applyStarsToEntries` exists
    /// for: a decoded `isStarred: true` that the set contradicts is a stale
    /// mirror (a kill between the two writes), and the set is what wins.
    @Test("a stale starred flag on an unrenamed entry is still overwritten")
    func staleFlagOnUnrenamedEntryLoses() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars([])
        try scratch.writeLifeList([
            .make("Cardinalis cardinalis", "Northern Cardinal",
                  [.at(may4, "A", lat: 1, lon: 1)], starred: true),
        ])

        let store = makeStore(scratch, defaults)

        #expect(store.entries[0].scientificName == "Cardinalis cardinalis", "nothing moved")
        #expect(!store.entries[0].isStarred, "so the set wins, as it always has")
    }

    @Test("a rename doesn't star a bird that wasn't starred")
    func renameWithoutAStarAddsNothing() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars([])
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker", [.at(may4, "A", lat: 1, lon: 1)]),
        ])

        let store = makeStore(scratch, defaults)

        #expect(store.entries[0].scientificName == "Dryobates villosus")
        #expect(!store.entries[0].isStarred)
        #expect(store.starredNames.isEmpty)
    }

    /// A star on a species the rename never touched is left exactly where it is —
    /// including one with no entry at all, which is the whole point of keeping the
    /// set separate from the life list.
    @Test("unrelated stars are untouched by a migration")
    func unrelatedStarsSurvive() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars(["Leuconotopicus villosus", "Cardinalis cardinalis", "Corvus corax"])
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker",
                  [.at(may4, "A", lat: 1, lon: 1)], starred: true),
            .make("Cardinalis cardinalis", "Northern Cardinal",
                  [.at(may5, "B", lat: 2, lon: 2)], starred: true),
        ])

        let store = makeStore(scratch, defaults)

        #expect(store.starredNames.contains("Dryobates villosus"))
        #expect(store.starredNames.contains("Cardinalis cardinalis"))
        #expect(store.starredNames.contains("Corvus corax"), "a star with no entry outlives one")
        #expect(store.entries.filter { !$0.isStarred }.isEmpty)
    }

    // MARK: the import path

    /// The other place canonicalization runs. Names the *parser* already
    /// canonicalizes never reach it, so this uses a pair the catalog has never
    /// heard of: the merge picks a survivor by stored order, and the star is on
    /// the one that loses.
    @Test("a star survives a merge an import causes")
    func starFollowsAMergeDuringImport() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars(["Zzz zzz"])
        try scratch.writeLifeList([
            .make("Zzz zzz", "Fictional Bird", [.at(may4, "A", lat: 1, lon: 1)], starred: true),
        ])
        let store = makeStore(scratch, defaults)
        #expect(store.entries[0].scientificName == "Zzz zzz", "nothing moved it on load")

        let csv = scratch.url.appendingPathComponent("import.csv")
        try eBirdCSV([
            (sci: "Aaa aaa", common: "Fictional Bird", date: "2026-05-05",
             location: "B" as String?, lat: 2.0 as Double?, lon: 2.0 as Double?),
        ]).write(to: csv)
        _ = try await store.importEBird(from: csv)

        #expect(store.entries.count == 1, "the two spellings merged")
        let survivor = store.entries[0]
        #expect(survivor.scientificName != "Zzz zzz", "onto the other spelling")
        #expect(survivor.isStarred, "carrying the star with it")
        #expect(store.starredNames.contains(survivor.scientificName))
    }

    // MARK: composing the passes

    /// The passes run in sequence, so a name one moves can be moved again by the
    /// next. `composeRenames` is what keeps the map pointing at where a name
    /// actually landed rather than at an intermediate it passed through.
    @Test("a rename chained through two passes reports the final name")
    func composeChains() {
        let composed = LifeListStore.composeRenames(["A": "B"], ["B": "C"])
        #expect(composed["A"] == "C")
        #expect(composed["B"] == "C")
    }

    @Test("a rename with nothing after it is carried through unchanged")
    func composeCarriesThrough() {
        let composed = LifeListStore.composeRenames(["A": "B"], ["X": "Y"])
        #expect(composed["A"] == "B")
        #expect(composed["X"] == "Y")
    }

    /// A name that comes back to itself isn't a rename. Recording it as one would
    /// have `migrateStars` re-insert a star that is already there, and — more to
    /// the point — a rename map is supposed to list what changed.
    @Test("a name renamed back to itself drops out")
    func composeDropsRoundTrips() {
        let composed = LifeListStore.composeRenames(["A": "B"], ["B": "A"])
        #expect(composed["A"] == nil)
    }

    @Test("composing with an empty map is the identity in both directions")
    func composeWithEmpty() {
        #expect(LifeListStore.composeRenames([:], ["A": "B"]) == ["A": "B"])
        #expect(LifeListStore.composeRenames(["A": "B"], [:]) == ["A": "B"])
        #expect(LifeListStore.composeRenames([:], [:]).isEmpty)
    }

    // MARK: a single pass moving one name twice

    /// `composeRenames` chains one pass's map onto the next one's. Nothing
    /// chained a pass's map onto *itself*, and `collapseByCommonName` is a pass
    /// that can move the same name twice — see `recordRename`.
    @Test("a name a pass moves twice ends up pointing at where it landed")
    func recordRenameFlattensChains() {
        var map: [String: String] = [:]
        LifeListStore.recordRename("Z", to: "X", in: &map)
        LifeListStore.recordRename("X", to: "Y", in: &map)
        #expect(map["Z"] == "Y", "not at the intermediate it passed through")
        #expect(map["X"] == "Y")
    }

    @Test("a name moved three times still reports only the final one")
    func recordRenameFlattensLongChains() {
        var map: [String: String] = [:]
        LifeListStore.recordRename("A", to: "B", in: &map)
        LifeListStore.recordRename("B", to: "C", in: &map)
        LifeListStore.recordRename("C", to: "D", in: &map)
        #expect(map == ["A": "D", "B": "D", "C": "D"])
    }

    @Test("a name that didn't move isn't recorded")
    func recordRenameIgnoresIdentity() {
        var map: [String: String] = [:]
        LifeListStore.recordRename("A", to: "A", in: &map)
        #expect(map.isEmpty)
    }

    /// The same rule `composeRenames` follows: a name that comes back to itself
    /// isn't a rename, so it drops out rather than being recorded as one.
    @Test("a name moved and moved back drops out")
    func recordRenameDropsRoundTrips() {
        var map: [String: String] = [:]
        LifeListStore.recordRename("A", to: "B", in: &map)
        LifeListStore.recordRename("B", to: "A", in: &map)
        #expect(map["A"] == nil)
        #expect(map["B"] == "A")
    }

    @Test("an unrelated rename is left alone")
    func recordRenameLeavesUnrelatedEntries() {
        var map: [String: String] = [:]
        LifeListStore.recordRename("A", to: "B", in: &map)
        LifeListStore.recordRename("P", to: "Q", in: &map)
        #expect(map == ["A": "B", "P": "Q"])
    }

    /// The end-to-end failure the flattening prevents, and the reason it had to
    /// be fixed at the map rather than at `migrateStars`.
    ///
    /// Three entries under one common name merge *pairwise*. The first collision
    /// picks a survivor; the second can pick a different one, which moves the
    /// first survivor's name again. Written straight into the dictionary that
    /// left `stale2 → stale1` beside `stale1 → catalog`, with nothing pointing
    /// `stale2` at the name the surviving entry actually holds.
    ///
    /// `migrateStars` walks that map with `for (old, new) in renames`, and
    /// `Dictionary` iteration order is seeded per process — so the star reached
    /// the survivor only when the walk happened to take the two links in order.
    /// Same list, same code, a different answer on the next launch, and on the
    /// launches that lost it `applyStarsToEntries` went on to clear the flag the
    /// merge had OR'd onto the entry. The bird stopped raising alerts and its row
    /// showed an empty star.
    ///
    /// Sixteen species rather than one: a single case would pass roughly half the
    /// time under the old code, which is not a regression test.
    @Test("a star survives three entries merging on one common name")
    func starSurvivesThreeWayCommonNameMerge() throws {
        let targets = SpeciesCatalog.shared.all
            .lazy
            .filter { !$0.commonName.contains("(") }
            .prefix(16)
        #expect(targets.count == 16, "the catalog has to be loaded for this to mean anything")

        var entries: [LifeListEntry] = []
        var stars: [String] = []
        for (n, species) in targets.enumerated() {
            // Two invented synonyms the catalog doesn't know, then the catalog's
            // own name last — the order that makes the second collision move the
            // first collision's survivor.
            let stale1 = "Zzstale\(n)a species"
            let stale2 = "Zzstale\(n)b species"
            entries.append(.make(stale1, species.commonName, [.at(may4, "A", lat: 1, lon: 1)]))
            entries.append(.make(stale2, species.commonName, [.at(may5, "B", lat: 2, lon: 2)],
                                 starred: true))
            entries.append(.make(species.scientificName, species.commonName,
                                 [.at(may5, "C", lat: 3, lon: 3)]))
            stars.append(stale2)
        }

        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars(stars)
        try scratch.writeLifeList(entries)
        let store = makeStore(scratch, defaults)

        for species in targets {
            let entry = store.entries.first { $0.scientificName == species.scientificName }
            #expect(entry != nil, "\(species.commonName) must survive under the catalog's name")
            #expect(entry?.isStarred == true, "\(species.commonName) must keep its star")
            #expect(store.starredNames.contains(species.scientificName),
                    "and the classifier must alert on the name the entry now holds")
        }
    }
}
