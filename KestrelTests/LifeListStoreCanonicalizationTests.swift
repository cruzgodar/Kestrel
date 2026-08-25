import Foundation
import Testing
@testable import Kestrel

/// The canonicalization pipeline that runs on every launch, exercised through
/// `load()` — a life list written to disk, a store built on it, and the entries
/// that come back.
///
/// Testing through `load()` rather than against the private statics is
/// deliberate: this pipeline runs *unconditionally, on every launch*, so what
/// matters is what a stored list turns into, and a test that reached inside
/// wouldn't notice the stages being wired up wrong.
@Suite("LifeListStore canonicalization")
@MainActor
struct LifeListStoreCanonicalizationTests {

    private let may4 = utcDay(2026, 5, 4)
    private let may5 = utcDay(2026, 5, 5)
    private let may6 = utcDay(2026, 5, 6)

    /// Writes `entries`, loads them, and hands back what the pipeline produced.
    private func roundTrip(
        _ entries: [LifeListEntry],
        _ scratch: ScratchDirectory,
        _ defaults: ScratchDefaults
    ) throws -> [LifeListEntry] {
        try scratch.writeLifeList(entries)
        return makeStore(scratch, defaults).entries
    }

    // MARK: subspecies collapse

    @Test("trinomial subspecies collapse into their binomial")
    func subspeciesCollapse() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let loaded = try roundTrip([
            .make("Dryobates villosus villosus", "Hairy Woodpecker", [.at(may5, "East", lat: 1, lon: 1)]),
            .make("Dryobates villosus harrisi", "Hairy Woodpecker", [.at(may4, "West", lat: 2, lon: 2)]),
        ], scratch, defaults)

        #expect(loaded.count == 1)
        #expect(loaded[0].scientificName == "Dryobates villosus")
        #expect(loaded[0].firstSeen == may4, "the earlier of the two becomes first-seen")
        #expect(loaded[0].allObservations.count == 2, "both subspecies' sightings are kept")
    }

    @Test("a lone trinomial is still renamed to its binomial")
    func loneTrinomialRenamed() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let loaded = try roundTrip([
            .make("Dryobates villosus harrisi", "Hairy Woodpecker", [.at(may4, "P", lat: 1, lon: 1)]),
        ], scratch, defaults)
        #expect(loaded.count == 1)
        #expect(loaded[0].scientificName == "Dryobates villosus")
        #expect(loaded[0].allObservations.count == 1)
    }

    /// Merging two spellings *is* a union of two record sets, so a sighting filed
    /// under both collapses — that's the one place dedupe is right.
    @Test("a sighting filed under two subspecies spellings collapses to one")
    func duplicateAcrossSubspeciesCollapses() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let shared = LifeListEntry.Observation.at(may4, "Same", lat: 1, lon: 1, imported: true)
        let loaded = try roundTrip([
            .make("Dryobates villosus villosus", "Hairy Woodpecker", [shared]),
            .make("Dryobates villosus harrisi", "Hairy Woodpecker", [shared]),
        ], scratch, defaults)
        #expect(loaded[0].allObservations.count == 1)
    }

    /// The counterpart: an entry that is *already* a binomial must pass through
    /// untouched, never round-tripped through `make`. That round-trip ran on every
    /// entry on every launch and is exactly where a rebuild could quietly disturb
    /// observations the user recorded by hand.
    @Test("a binomial entry's own duplicate sightings survive every launch")
    func binomialEntryPassesThroughUntouched() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let twice = LifeListEntry.Observation.at(may4, "Sapsucker Woods", lat: 1, lon: 1)
        var loaded = try roundTrip([
            .make("Cardinalis cardinalis", "Northern Cardinal", [twice, twice]),
        ], scratch, defaults)
        #expect(loaded[0].allObservations.count == 2)

        // And again — erosion would show up as a slow leak across launches.
        for _ in 0..<5 {
            loaded = makeStore(scratch, defaults).entries
        }
        #expect(loaded[0].allObservations.count == 2, "the list must not erode a record per launch")
    }

    @Test("the parenthetical-free common name is preferred when merging")
    func prefersUnparentheticalName() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let loaded = try roundTrip([
            .make("Junco hyemalis hyemalis", "Dark-eyed Junco (Slate-colored)", [.at(may4, "A", lat: 1, lon: 1)]),
            .make("Junco hyemalis oreganus", "Dark-eyed Junco", [.at(may5, "B", lat: 2, lon: 2)]),
        ], scratch, defaults)
        #expect(loaded.count == 1)
        #expect(loaded[0].commonName == "Dark-eyed Junco")
    }

    @Test("a star on either spelling survives the merge")
    func starSurvivesMerge() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars(["Dryobates villosus"])
        let loaded = try roundTrip([
            .make("Dryobates villosus villosus", "Hairy Woodpecker", [.at(may4, "A", lat: 1, lon: 1)], starred: true),
            .make("Dryobates villosus harrisi", "Hairy Woodpecker", [.at(may5, "B", lat: 2, lon: 2)]),
        ], scratch, defaults)
        #expect(loaded[0].isStarred)
    }

    // MARK: taxonomic synonyms

    /// A species that moved genera. eBird exports the current name; BirdNET was
    /// trained on the old one, and the image slug follows BirdNET — so the entry
    /// has to end up under the catalog's spelling or its photo silently goes
    /// missing.
    @Test("two spellings of one bird collapse onto the catalog's scientific name")
    func commonNameCollapse() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let loaded = try roundTrip([
            .make("Leuconotopicus villosus", "Hairy Woodpecker", [.at(may5, "Old genus", lat: 1, lon: 1)]),
            .make("Dryobates villosus", "Hairy Woodpecker", [.at(may4, "New genus", lat: 2, lon: 2)]),
        ], scratch, defaults)

        #expect(loaded.count == 1)
        #expect(loaded[0].scientificName == "Dryobates villosus", "the name BirdNET emits wins")
        #expect(loaded[0].allObservations.count == 2)
    }

    /// The singleton case the multi-entry merge can't reach: one entry, stored
    /// under a name the catalog doesn't have, whose common name it does.
    @Test("a lone entry under a stale synonym is rewritten to the catalog's name")
    func loneSynonymRewritten() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let loaded = try roundTrip([
            .make("Leuconotopicus villosus", "Hairy Woodpecker", [.at(may4, "P", lat: 1, lon: 1)]),
        ], scratch, defaults)
        #expect(loaded.count == 1)
        #expect(loaded[0].scientificName == "Dryobates villosus")
        #expect(loaded[0].allObservations.count == 1, "a relabel is not a merge — nothing collapses")
    }

    @Test("an entry the catalog doesn't recognize at all is left alone")
    func unknownEntryUntouched() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let loaded = try roundTrip([
            .make("Madeupus fictitius", "Entirely Invented Bird", [.at(may4, "P", lat: 1, lon: 1)]),
        ], scratch, defaults)
        #expect(loaded.count == 1)
        #expect(loaded[0].scientificName == "Madeupus fictitius")
    }

    /// The alias table handles the case where *neither* name matches the catalog
    /// — a post-split eBird name whose common name is also new.
    @Test("the alias table rewrites post-split eBird names")
    func aliasTableApplied() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        // Take a real alias from the table so this tracks the shipped data.
        guard let (stale, canonical) = TaxonomyAliases.ebirdToBirdNET.first else {
            Issue.record("the alias table is empty — the migration it exists for is unreachable")
            return
        }
        let loaded = try roundTrip([
            .make(stale, "Some Split Species", [.at(may4, "P", lat: 1, lon: 1)]),
        ], scratch, defaults)
        #expect(loaded.count == 1)
        #expect(loaded[0].scientificName == canonical)
    }

    @Test("an alias rewrite merges onto an entry already under the canonical name")
    func aliasMergesOntoCanonical() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        guard let (stale, canonical) = TaxonomyAliases.ebirdToBirdNET.first else { return }
        let loaded = try roundTrip([
            .make(stale, "Split Name", [.at(may5, "A", lat: 1, lon: 1)]),
            .make(canonical, "Original Name", [.at(may4, "B", lat: 2, lon: 2)]),
        ], scratch, defaults)
        #expect(loaded.count == 1, "one bird, one row")
        #expect(loaded[0].scientificName == canonical)
        #expect(loaded[0].allObservations.count == 2)
    }

    // MARK: the scientific-name collision guard

    /// The rewrite above keys on the *common* name, so it can land one entry on a
    /// name another already holds. It takes two entries for the same bird with
    /// different common names — which an eBird export in a non-English display
    /// language produces readily: the localized name doesn't match the catalog, so
    /// that entry keeps its stale synonym, while the English-named one gets
    /// rewritten onto the catalog's.
    ///
    /// Left unmerged, the two ride out of canonicalization sharing a
    /// `LifeListEntry.id`, and a `ForEach` over duplicate ids renders one row and
    /// misroutes the other's swipe actions — the bird becomes unreachable.
    /// The synonym here is deliberately one the **alias table doesn't list**
    /// (`Richmondena cardinalis`, a real former genus for the Northern Cardinal).
    /// A listed synonym is rewritten by `applyAliases` before `collapseToSpecies`
    /// runs, so the two entries merge on their binomial and the collision path is
    /// never reached — which is exactly the trap an earlier version of this test
    /// fell into. The alias table can't enumerate every synonym in existence (its
    /// own doc says entries get added as users report missing images), so the
    /// unlisted case is the one that has to hold.
    @Test("a rewrite that collides with an existing entry merges instead of duplicating")
    func rewriteCollisionMerges() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let loaded = try roundTrip([
            // Already canonical, but under a common name the catalog doesn't use —
            // what a non-English eBird export produces.
            .make("Cardinalis cardinalis", "Roter Kardinal", [.at(may5, "German", lat: 1, lon: 1)]),
            // An unlisted stale synonym whose *English* common name the catalog knows,
            // so the final pass rewrites it straight onto the name above.
            .make("Richmondena cardinalis", "Northern Cardinal", [.at(may4, "English", lat: 2, lon: 2)]),
        ], scratch, defaults)

        #expect(loaded.count == 1, "one species must not occupy two rows")
        #expect(loaded.map(\.scientificName) == ["Cardinalis cardinalis"])
        #expect(loaded[0].allObservations.count == 2, "neither entry's sightings may be dropped")
        #expect(loaded[0].firstSeen == may4)
    }

    /// The failure mode the merge prevents, stated directly: two entries sharing a
    /// `LifeListEntry.id`. A `ForEach` over duplicate ids renders one row and
    /// misroutes the other's swipe actions, so the second bird becomes invisible
    /// and unreachable.
    @Test("a collision never leaves two entries sharing an id")
    func collisionLeavesNoDuplicateIDs() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let loaded = try roundTrip([
            .make("Cardinalis cardinalis", "Roter Kardinal", [.at(may5, "A", lat: 1, lon: 1)]),
            .make("Richmondena cardinalis", "Northern Cardinal", [.at(may4, "B", lat: 2, lon: 2)]),
        ], scratch, defaults)
        let ids = loaded.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test("no two entries ever share a scientific name after a load")
    func idsAreUniqueAfterLoad() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let loaded = try roundTrip([
            .make("Cardinalis cardinalis", "Roter Kardinal", [.at(may4, "A", lat: 1, lon: 1)]),
            .make("Richmondena cardinalis", "Northern Cardinal", [.at(may5, "B", lat: 2, lon: 2)]),
            .make("Dryobates villosus", "Haariger Specht", [.at(may6, "C", lat: 3, lon: 3)]),
            .make("Leuconotopicus villosus", "Hairy Woodpecker", [.at(may4, "D", lat: 4, lon: 4)]),
            .make("Dryobates villosus villosus", "Pic chevelu", [.at(may5, "E", lat: 5, lon: 5)]),
        ], scratch, defaults)
        let names = loaded.map(\.scientificName)
        #expect(names.count == Set(names).count)
    }

    @Test("a collision merge ORs the star and prefers the unparenthetical name")
    func collisionMergeKeepsStarAndName() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars(["Dryobates villosus"])
        let loaded = try roundTrip([
            .make("Dryobates villosus", "Hairy Woodpecker (Eastern)", [.at(may5, "A", lat: 1, lon: 1)], starred: true),
            .make("Leuconotopicus villosus", "Hairy Woodpecker", [.at(may4, "B", lat: 2, lon: 2)]),
        ], scratch, defaults)
        #expect(loaded.count == 1)
        #expect(loaded[0].isStarred)
    }

    /// And the collision merge must preserve the star too, by the same rule.
    @Test("a collision merge keeps a star from either side")
    func collisionMergeKeepsStar() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeStars(["Cardinalis cardinalis"])
        let loaded = try roundTrip([
            .make("Cardinalis cardinalis", "Roter Kardinal", [.at(may5, "A", lat: 1, lon: 1)], starred: true),
            .make("Richmondena cardinalis", "Northern Cardinal", [.at(may4, "B", lat: 2, lon: 2)]),
        ], scratch, defaults)
        #expect(loaded.count == 1)
        #expect(loaded[0].isStarred)
    }

    // MARK: ordering

    @Test("entries come back newest first")
    func sortedNewestFirst() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let loaded = try roundTrip([
            .make("A a", "A", [.at(may4, "P", lat: 1, lon: 1)]),
            .make("C c", "C", [.at(may6, "P", lat: 1, lon: 1)]),
            .make("B b", "B", [.at(may5, "P", lat: 1, lon: 1)]),
        ], scratch, defaults)
        #expect(loaded.map(\.scientificName) == ["C c", "B b", "A a"])
    }

    /// `Array.sort` isn't guaranteed stable on equal keys, so without the
    /// scientific-name tiebreaker a batch import that stamps every entry with the
    /// same date could shuffle its rows between recomputations.
    @Test("entries sharing a date order deterministically by scientific name")
    func stableTieBreak() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let names = (0..<40).map { "Genus sp\(String(format: "%02d", $0))" }
        let entries = names.shuffled().map {
            LifeListEntry.make($0, "Bird \($0)", [.at(may4, "P", lat: 1, lon: 1)])
        }
        let first = try roundTrip(entries, scratch, defaults)
        #expect(first.map(\.scientificName) == names, "equal dates must fall back to the name")

        let second = makeStore(scratch, defaults).entries
        #expect(second.map(\.scientificName) == first.map(\.scientificName))
    }

    /// When two entries have to be merged, *which one survives* must be a
    /// function of the stored file, not of the run.
    ///
    /// The pipeline's stages hand entries to each other as arrays, and each stage
    /// resolves a collision by keeping whichever entry it met first — so an
    /// unordered `Dictionary.values` anywhere in the chain made the winner a coin
    /// flip re-tossed on every launch. The survivor's scientific name is the
    /// entry's `id`, and its id is its photo slug, so the same bird could come
    /// back under a different name (and a different photo) than it had yesterday.
    ///
    /// Ten independent pairs, so an arbitrary ordering agreeing with the file's
    /// by luck is a one-in-a-thousand accident rather than a coin flip.
    @Test("which of two merged entries wins is decided by the stored order")
    func mergeWinnerFollowsStoredOrder() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        // Neither name is in the catalog, so neither can win on that ground and
        // the tie falls to whichever was seen first.
        let entries = (0..<10).flatMap { i -> [LifeListEntry] in
            let shared = "Shared Bird \(i)"
            return [
                .make("Aaa sp\(i)x", shared, [.at(may5, "First", lat: 1, lon: 1)]),
                .make("Zzz sp\(i)x", shared, [.at(may4, "Second", lat: 2, lon: 2)]),
            ]
        }
        let loaded = try roundTrip(entries, scratch, defaults)
        #expect(loaded.count == 10, "each pair merges to one entry")
        #expect(
            loaded.allSatisfy { $0.scientificName.hasPrefix("Aaa") },
            "the entry listed first in the file decides the surviving name"
        )
        // Both records survive the merge whichever name won.
        #expect(loaded.allSatisfy { $0.allObservations.count == 2 })
    }

    /// The same, one stage earlier: a trinomial collapse feeds the common-name
    /// pass, so its output has to be ordered too or the guarantee above only
    /// holds for lists with no subspecies rows in them.
    @Test("the stored order survives a subspecies collapse on the way through")
    func subspeciesCollapsePreservesOrder() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let entries = (0..<10).flatMap { i -> [LifeListEntry] in
            let shared = "Shared Bird \(i)"
            return [
                .make("Aaa sp\(i)x reidi", shared, [.at(may5, "First", lat: 1, lon: 1)]),
                .make("Zzz sp\(i)x", shared, [.at(may4, "Second", lat: 2, lon: 2)]),
            ]
        }
        let loaded = try roundTrip(entries, scratch, defaults)
        #expect(loaded.count == 10)
        #expect(
            loaded.allSatisfy { $0.scientificName.hasPrefix("Aaa") },
            "the trinomial collapses to its binomial and still wins the tie"
        )
        #expect(loaded.allSatisfy { !$0.scientificName.contains("reidi") })
    }

    @Test("ordersBefore is a strict weak ordering")
    func ordersBeforeIsStrict() {
        let a = LifeListEntry.make("A a", "A", [.at(may4)])
        let b = LifeListEntry.make("B b", "B", [.at(may4)])
        let c = LifeListEntry.make("C c", "C", [.at(may5)])
        #expect(LifeListStore.ordersBefore(a, b))
        #expect(!LifeListStore.ordersBefore(b, a))
        #expect(!LifeListStore.ordersBefore(a, a), "irreflexive")
        #expect(LifeListStore.ordersBefore(c, a), "later dates come first")
    }

    // MARK: persistence side effects of a load

    @Test("a load that rewrote names persists the rewrite")
    func rewritePersisted() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker", [.at(may4, "P", lat: 1, lon: 1)]),
        ])
        let store = makeStore(scratch, defaults)
        store.flushPendingWrites()
        let onDisk = try scratch.readLifeList()
        #expect(onDisk.map(\.scientificName) == ["Dryobates villosus"])
    }

    /// One entry, already canonical in every respect, written compactly. `save()`
    /// writes pretty-printed JSON with sorted keys, so if the load rewrote the
    /// file at all these bytes would not survive.
    private static let cleanCompactJSON =
        #"[{"scientificName":"Cardinalis cardinalis","commonName":"Northern Cardinal","#
        + #""firstSeen":"2019-05-04T00:00:00Z","firstLocation":"Ithaca","#
        + #""firstLatitude":42.45,"firstLongitude":-76.5,"#
        + #""firstIsImported":false,"isStarred":false,"otherObservations":[]}]"#

    /// The other half of `rewritePersisted`: a load that found nothing to fix
    /// must not write.
    ///
    /// The test this replaces compared entry counts and scientific names only, so
    /// it read "nothing changed" off two properties rather than off the entries
    /// themselves. Straight value equality against what was decoded is what
    /// actually says a launch had no work to do.
    @Test("a load that changed nothing leaves the file untouched")
    func cleanLoadDoesNotRewrite() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeRawLifeList(Self.cleanCompactJSON)
        let store = makeStore(scratch, defaults)
        store.flushPendingWrites()

        #expect(store.entries.count == 1)
        #expect(scratch.data("life_list.json") == Data(Self.cleanCompactJSON.utf8),
                "nothing about this entry needed canonicalizing, so nothing should have been written")
    }

    /// And with the migration flag *clear* over data that is already canonical —
    /// the lost-flag case. The migration runs, finds every date already midnight
    /// UTC, and changes nothing; the file should be left exactly as it was rather
    /// than rewritten for the sake of a pass that did no work.
    @Test("a migration pass over canonical data leaves the file untouched")
    func idempotentMigrationDoesNotRewrite() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeRawLifeList(Self.cleanCompactJSON)
        // Deliberately *not* `makeStore`, which marks the migration done.
        let store = LifeListStore(directory: scratch.url, defaults: defaults.defaults)
        store.flushPendingWrites()

        #expect(store.entries[0].firstSeen == utcDay(2019, 5, 4))
        #expect(scratch.data("life_list.json") == Data(Self.cleanCompactJSON.utf8))
    }

    @Test("an empty or absent life list loads as empty without writing anything")
    func absentFileIsEmpty() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        #expect(store.entries.isEmpty)
        #expect(store.speciesNames.isEmpty)
        #expect(scratch.data("life_list.json") == nil)
    }

    @Test("a corrupt life list leaves the store empty rather than crashing")
    func corruptFileTolerated() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeRawLifeList("{ this is not JSON")
        let store = makeStore(scratch, defaults)
        #expect(store.entries.isEmpty)
    }

    @Test("speciesNames matches entries after a load")
    func speciesNamesAfterLoad() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeLifeList([
            .make("A a", "A", [.at(may4, "P", lat: 1, lon: 1)]),
            .make("B b", "B", [.at(may5, "P", lat: 1, lon: 1)]),
        ])
        let store = makeStore(scratch, defaults)
        #expect(store.speciesNames == Set(store.entries.map(\.scientificName)))
    }
}
