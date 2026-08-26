import Foundation
import Testing
@testable import Kestrel

/// The Life List tab's search: matching, ranking, and the in-range grouping.
@Suite("Life list search")
struct SearchTests {

    // MARK: matching

    @Test("a substring match scores best")
    func substringScoresZero() {
        #expect(LifeListView.scoreMatch("northern cardinal", needle: "card", allowFuzzy: true) == 0)
        #expect(LifeListView.scoreMatch("northern cardinal", needle: "northern", allowFuzzy: true) == 0)
        #expect(LifeListView.scoreMatch("northern cardinal", needle: "cardinal", allowFuzzy: false) == 0)
    }

    @Test("a non-match is nil")
    func nonMatchIsNil() {
        #expect(LifeListView.scoreMatch("northern cardinal", needle: "penguin", allowFuzzy: true) == nil)
    }

    /// One typo is forgiven, on a word-prefix basis. Two is not — past that the
    /// suggestions stop resembling what was typed.
    @Test("a single-character typo still matches; two do not")
    func fuzzyTolerance() {
        #expect(LifeListView.scoreMatch("northern cardinal", needle: "cardinl", allowFuzzy: true) != nil)
        #expect(LifeListView.scoreMatch("northern cardinal", needle: "kardinal", allowFuzzy: true) != nil)
        #expect(LifeListView.scoreMatch("northern cardinal", needle: "kkkdinal", allowFuzzy: true) == nil)
    }

    /// Substring already catches everything useful at one or two characters, and
    /// the per-keystroke cost of fuzzy matching adds up across 6,500 species.
    @Test("fuzzy matching is skipped for very short queries")
    func fuzzyDisabledForShortQueries() {
        #expect(LifeListView.scoreMatch("northern cardinal", needle: "xa", allowFuzzy: false) == nil)
        #expect(LifeListView.scoreMatch("northern cardinal", needle: "ca", allowFuzzy: false) == 0,
                "a genuine substring still matches")
    }

    @Test("an exact substring outranks a fuzzy match")
    func exactOutranksFuzzy() {
        let exact = LifeListView.scoreMatch("northern cardinal", needle: "cardinal", allowFuzzy: true)
        let fuzzy = LifeListView.scoreMatch("northern cardinal", needle: "cardinl", allowFuzzy: true)
        #expect(exact != nil && fuzzy != nil)
        #expect(exact! < fuzzy!)
    }

    /// Swift's `String.contains("")` is `false`, not `true`, so an empty needle
    /// matches nothing rather than everything. Harmless — the view guards on a
    /// non-empty trimmed query before it ever calls this — but worth pinning, since
    /// the opposite behavior would dump all 6,500 species into the list the moment
    /// the field was cleared.
    @Test("an empty needle matches nothing")
    func emptyNeedle() {
        #expect(LifeListView.scoreMatch("anything", needle: "", allowFuzzy: false) == nil)
        #expect(LifeListView.computeSuggestions(
            needle: "", excluding: [], lifeCommonNames: [], allowed: nil
        ).isEmpty)
    }

    // MARK: levenshtein

    @Test(
        "levenshtein counts single edits",
        arguments: [
            ("", "", 0), ("a", "", 1), ("", "abc", 3),
            ("kitten", "sitting", 3), ("flaw", "lawn", 2),
            ("cardinal", "cardinal", 0), ("cardinal", "cardinl", 1),
            ("abc", "cba", 2),
        ]
    )
    func levenshteinDistances(a: String, b: String, expected: Int) {
        #expect(LifeListView.levenshtein(a, b) == expected)
    }

    @Test("levenshtein is symmetric")
    func levenshteinSymmetric() {
        for (a, b) in [("kitten", "sitting"), ("cardinal", "cardinl"), ("", "abc"), ("xyz", "")] {
            #expect(LifeListView.levenshtein(a, b) == LifeListView.levenshtein(b, a))
        }
    }

    // MARK: suggestion ranking

    /// In-range species are ranked ahead of out-of-range ones **before** the
    /// 20-row cap. Ranking after the cut could drop every nearby suggestion before
    /// the view ever got to group them.
    @Test("in-range species are ranked above out-of-range before the cap")
    func inRangeRankedBeforeCap() {
        let catalog = SpeciesCatalog.shared.all
        // Pick a needle that matches far more than the cap, so ordering decides
        // what survives.
        let needle = "a"
        let matchingIndices = catalog.indices.filter {
            LifeListView.scoreMatch(catalog[$0].searchHay, needle: needle, allowFuzzy: false) != nil
        }
        try? #require(matchingIndices.count > 40)
        // Mark only species deep in the match list as in-range.
        let allowed = Set(matchingIndices.suffix(10))

        let rows = LifeListView.computeSuggestions(
            needle: needle, excluding: [], lifeCommonNames: [], allowed: allowed
        )
        #expect(rows.count <= 20)

        let index = SpeciesCatalog.shared.indexByScientificName
        let inRangeCount = rows.filter { row in
            guard case .suggestion(let sci, _) = row, let i = index[sci] else { return false }
            return allowed.contains(i)
        }.count
        #expect(inRangeCount == min(10, rows.count),
                "nearby birds must survive the truncation")
    }

    @Test("suggestions are capped at twenty")
    func suggestionCap() {
        let rows = LifeListView.computeSuggestions(
            needle: "a", excluding: [], lifeCommonNames: [], allowed: nil
        )
        #expect(rows.count <= 20)
    }

    @Test("species already on the life list are never suggested")
    func lifeListExcluded() {
        let sci = "Cardinalis cardinalis"
        let without = LifeListView.computeSuggestions(
            needle: "northern cardinal", excluding: [], lifeCommonNames: [], allowed: nil
        )
        #expect(without.contains { if case .suggestion(let s, _) = $0 { return s == sci }; return false })

        let with = LifeListView.computeSuggestions(
            needle: "northern cardinal", excluding: [sci], lifeCommonNames: [], allowed: nil
        )
        #expect(!with.contains { if case .suggestion(let s, _) = $0 { return s == sci }; return false })
    }

    /// A life-list entry stored under an older genus shares its common name with
    /// the catalog's current one; matching on the common name too is what stops
    /// the same bird appearing twice.
    @Test("a species is excluded by common name even under a stale genus")
    func commonNameExclusion() {
        let rows = LifeListView.computeSuggestions(
            needle: "hairy woodpecker",
            excluding: ["Leuconotopicus villosus"],
            lifeCommonNames: ["hairy woodpecker"],
            allowed: nil
        )
        #expect(!rows.contains {
            if case .suggestion(_, let common) = $0 { return common == "Hairy Woodpecker" }
            return false
        })
    }

    @Test("common-name exclusion is case-insensitive")
    func commonNameExclusionCaseInsensitive() {
        let rows = LifeListView.computeSuggestions(
            needle: "northern cardinal", excluding: [], lifeCommonNames: ["northern cardinal"], allowed: nil
        )
        #expect(!rows.contains {
            if case .suggestion(_, let common) = $0 { return common == "Northern Cardinal" }
            return false
        })
    }

    /// Equal scores are the common case, not the exception: a substring hit
    /// scores 0 for *every* species containing the query, which for a short
    /// needle is hundreds of them. `Array.sorted` can return either arrangement
    /// of equal elements, so without a tiebreaker below the score the twenty
    /// species that survive `.prefix(20)` — the contents, not merely the order —
    /// could differ between two scans of an unchanged catalog. The user sees that
    /// as suggestions appearing and vanishing while they type nothing.
    @Test("equal-scoring suggestions are ordered by name, not arbitrarily")
    func equalScoresOrderByName() {
        let rows = LifeListView.computeSuggestions(
            needle: "sparrow", excluding: [], lifeCommonNames: [], allowed: nil
        )
        try? #require(rows.count > 5)
        let names: [String] = rows.compactMap {
            if case .suggestion(_, let common) = $0 { return common }
            return nil
        }
        // Everything matching "sparrow" as a substring scores 0, so with no range
        // filter the whole list is one equal-score block and must be alphabetical.
        #expect(names == names.sorted(), "\(names)")
    }

    @Test("repeated scans of an unchanged catalog return the identical list")
    func suggestionsAreDeterministic() {
        for needle in ["a", "e", "sparrow", "warb"] {
            let first = LifeListView.computeSuggestions(
                needle: needle, excluding: [], lifeCommonNames: [], allowed: nil
            )
            for _ in 0..<5 {
                let again = LifeListView.computeSuggestions(
                    needle: needle, excluding: [], lifeCommonNames: [], allowed: nil
                )
                #expect(again == first, "\(needle)")
            }
        }
    }

    /// The same guarantee with a range filter in play, where the primary key is
    /// `inRange` rather than the score.
    @Test("the in-range block is itself ordered deterministically")
    func inRangeBlockIsDeterministic() {
        let catalog = SpeciesCatalog.shared.all
        let matching = catalog.indices.filter {
            LifeListView.scoreMatch(catalog[$0].searchHay, needle: "a", allowFuzzy: false) != nil
        }
        try? #require(matching.count > 40)
        let allowed = Set(matching.suffix(10))
        let first = LifeListView.computeSuggestions(
            needle: "a", excluding: [], lifeCommonNames: [], allowed: allowed
        )
        for _ in 0..<5 {
            #expect(LifeListView.computeSuggestions(
                needle: "a", excluding: [], lifeCommonNames: [], allowed: allowed
            ) == first)
        }
    }

    @Test("a query matching nothing yields no suggestions")
    func noMatches() {
        #expect(LifeListView.computeSuggestions(
            needle: "zzzzqqqqxxxx", excluding: [], lifeCommonNames: [], allowed: nil
        ).isEmpty)
    }

    // MARK: partitionByRange

    @Test("out-of-range suggestions go below a header")
    func partitionInsertsHeader() {
        let index = SpeciesCatalog.shared.indexByScientificName
        let inRangeSci = SpeciesCatalog.shared.all[0].scientificName
        let outOfRangeSci = SpeciesCatalog.shared.all[1].scientificName

        let rows: [LifeListView.SearchRow] = [
            .suggestion(scientificName: inRangeSci, commonName: "In"),
            .suggestion(scientificName: outOfRangeSci, commonName: "Out"),
        ]
        let partitioned = LifeListView.partitionByRange(rows, allowed: [index[inRangeSci]!])
        #expect(partitioned.count == 3)
        if case .header(let title) = partitioned[1] {
            #expect(title == "Birds not found in this area")
        } else {
            Issue.record("expected a header between the two groups")
        }
    }

    @Test("no header appears when everything is in range")
    func partitionNoHeaderWhenAllInRange() {
        let index = SpeciesCatalog.shared.indexByScientificName
        let sci = SpeciesCatalog.shared.all[0].scientificName
        let rows: [LifeListView.SearchRow] = [.suggestion(scientificName: sci, commonName: "In")]
        let partitioned = LifeListView.partitionByRange(rows, allowed: [index[sci]!])
        #expect(partitioned.count == 1)
    }

    @Test("with no cached range filter the rows pass through untouched")
    func partitionWithoutFilter() {
        let rows: [LifeListView.SearchRow] = [
            .suggestion(scientificName: "A a", commonName: "A"),
            .suggestion(scientificName: "B b", commonName: "B"),
        ]
        #expect(LifeListView.partitionByRange(rows, allowed: nil).map(\.id) == rows.map(\.id))
    }

    /// A bird you've already recorded should surface instantly when you search for
    /// it, not get buried under "not found in this area" because you saw it on
    /// another continent.
    @Test("life-list entries are always treated as in range")
    func lifeListAlwaysInRange() {
        let entry = LifeListEntry.make("Faraway bird", "Faraway Bird", [.at(utcDay(2026, 5, 4))])
        let rows: [LifeListView.SearchRow] = [
            .suggestion(scientificName: SpeciesCatalog.shared.all[1].scientificName, commonName: "Out"),
            .existing(entry),
        ]
        let partitioned = LifeListView.partitionByRange(rows, allowed: [])
        // The lifer sorts above the header; the suggestion below it.
        guard partitioned.count == 3 else {
            Issue.record("expected the lifer, a header, then the suggestion")
            return
        }
        if case .existing = partitioned[0] {} else { Issue.record("the lifer must come first") }
        if case .header = partitioned[1] {} else { Issue.record("a header must separate them") }
    }

    @Test("relative order within each group is preserved")
    func partitionPreservesOrder() {
        let catalog = SpeciesCatalog.shared.all
        let index = SpeciesCatalog.shared.indexByScientificName
        let inRange = [catalog[0], catalog[2], catalog[4]].map(\.scientificName)
        let outOfRange = [catalog[1], catalog[3]].map(\.scientificName)

        let rows: [LifeListView.SearchRow] =
            zip(inRange, outOfRange + [""]).flatMap { pair -> [LifeListView.SearchRow] in
                var out: [LifeListView.SearchRow] = [.suggestion(scientificName: pair.0, commonName: pair.0)]
                if !pair.1.isEmpty { out.append(.suggestion(scientificName: pair.1, commonName: pair.1)) }
                return out
            }
        let allowed = Set(inRange.compactMap { index[$0] })
        let partitioned = LifeListView.partitionByRange(rows, allowed: allowed)

        var here: [String] = [], notHere: [String] = []
        var seenHeader = false
        for row in partitioned {
            switch row {
            case .header: seenHeader = true
            case .suggestion(let sci, _): (seenHeader ? { notHere.append(sci) } : { here.append(sci) })()
            case .existing: break
            }
        }
        #expect(here == inRange)
        #expect(notHere == outOfRange)
    }
}

/// The rule deciding whether a heard bird raises a notification and an alert
/// haptic.
///
/// Two life-list sets go in, and the difference between them is the whole point.
/// The frozen session snapshot drives the *display* — the row's purple treatment
/// and the spectrogram band — which must not vanish the instant the user taps
/// add. Alerting is a different question, and reading only the frozen set for
/// both is what made a bird the user had just filed go on buzzing every five
/// seconds and re-notifying every thirty for the rest of the walk.
@Suite("Detection alert rule")
struct AlertRuleTests {

    private func reason(
        starred: Set<String> = [],
        snapshot: Set<String> = [],
        recorded: Set<String> = []
    ) -> SpeciesNotifications.Reason? {
        RecordingManager.alertReason(
            scientificName: "Cardinalis cardinalis",
            starred: starred, snapshotAtSessionStart: snapshot, recordedNow: recorded
        )
    }

    @Test("a bird that was new at session start and still is alerts as a new species")
    func unrecordedAlerts() {
        #expect(reason() == .newSpecies)
    }

    /// The regression: the bird is still absent from the frozen snapshot (so its
    /// row keeps its purple treatment, correctly), but it is now on the list.
    @Test("a bird added mid-session stops alerting")
    func recordedMidSessionStopsAlerting() {
        #expect(reason(snapshot: [], recorded: ["Cardinalis cardinalis"]) == nil,
                "the user has acknowledged it — there is nothing left to tell them")
    }

    @Test("a bird already on the list at session start never alerts")
    func alreadyRecordedNeverAlerts() {
        #expect(reason(snapshot: ["Cardinalis cardinalis"], recorded: ["Cardinalis cardinalis"]) == nil)
    }

    /// A star is a standing "tell me again", not a gap in the user's records — so
    /// it keeps alerting however well recorded the bird is.
    @Test("a starred bird alerts whatever its life-list status")
    func starredAlwaysAlerts() {
        let starred: Set<String> = ["Cardinalis cardinalis"]
        #expect(reason(starred: starred) == .starred)
        #expect(reason(starred: starred, snapshot: ["Cardinalis cardinalis"],
                       recorded: ["Cardinalis cardinalis"]) == .starred)
        #expect(reason(starred: starred, recorded: ["Cardinalis cardinalis"]) == .starred)
    }

    @Test("starred outranks new-species when both apply")
    func starredOutranksNew() {
        #expect(reason(starred: ["Cardinalis cardinalis"], snapshot: [], recorded: []) == .starred)
    }

    /// A bird that was on the list at session start but has since had its last
    /// sighting deleted stays quiet: the session snapshot is what says whether it
    /// was ever a "new species" for this walk, and it wasn't.
    @Test("deleting a bird mid-session does not start it alerting")
    func deletedMidSessionStaysQuiet() {
        #expect(reason(snapshot: ["Cardinalis cardinalis"], recorded: []) == nil)
    }

    @Test("other species are unaffected")
    func otherSpeciesUnaffected() {
        #expect(RecordingManager.alertReason(
            scientificName: "Turdus migratorius",
            starred: ["Cardinalis cardinalis"],
            snapshotAtSessionStart: ["Turdus migratorius"],
            recordedNow: ["Turdus migratorius"]
        ) == nil)
    }
}

/// Where the alert rule gets its `starred` set from.
///
/// `alertReason` is pure and well covered above, but it only ever sees whatever
/// the caller hands it — and the caller used to hand it a mirror the Identify tab
/// refreshed from an `.onChange`. That was true enough while starring happened
/// only on that tab, and it hasn't been for a while: the map's pin and
/// cluster-grid menus, the full-screen viewer's menu and the life-list row's own
/// menu all toggle stars, every one of them reachable with Identify deselected.
/// Whether the alert rule saw the toggle then came down to whether SwiftUI had
/// re-evaluated an off-screen tab's body.
@Suite("Starred set wiring")
@MainActor
struct StarredWiringTests {

    private func manager(_ store: LifeListStore) -> RecordingManager {
        let manager = RecordingManager()
        manager.lifeListStore = store
        return manager
    }

    @Test("the manager reads stars straight off the store")
    func readsFromStore() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        let manager = manager(store)
        #expect(manager.starredNames.isEmpty)

        store.setStarred(scientificName: "Cardinalis cardinalis", isStarred: true)
        #expect(manager.starredNames == ["Cardinalis cardinalis"],
                "no view is mounted to push this in — it has to be read")
    }

    /// The regression, in the shape it actually took: a star toggled from
    /// somewhere that is not the Identify tab, mid-session.
    @Test("a star toggled with no view mounted reaches the alert rule")
    func starToggledOffTabAlerts() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.add(scientificName: "Turdus migratorius", commonName: "American Robin",
                  firstSeen: utcDay(2020, 1, 1))
        let manager = manager(store)

        // Recorded before the session and unstarred: nothing to say about it.
        let snapshot: Set<String> = ["Turdus migratorius"]
        #expect(RecordingManager.alertReason(
            scientificName: "Turdus migratorius",
            starred: manager.starredNames,
            snapshotAtSessionStart: snapshot,
            recordedNow: store.speciesNames
        ) == nil)

        // Starred from the map's pin menu, say, while the Map tab is showing.
        store.setStarred(scientificName: "Turdus migratorius", isStarred: true)
        #expect(RecordingManager.alertReason(
            scientificName: "Turdus migratorius",
            starred: manager.starredNames,
            snapshotAtSessionStart: snapshot,
            recordedNow: store.speciesNames
        ) == .starred, "the toggle has to take effect on the very next detection")
    }

    @Test("unstarring takes effect just as immediately")
    func unstarringTakesEffect() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.setStarred(scientificName: "Cardinalis cardinalis", isStarred: true)
        let manager = manager(store)
        #expect(manager.starredNames == ["Cardinalis cardinalis"])

        store.setStarred(scientificName: "Cardinalis cardinalis", isStarred: false)
        #expect(manager.starredNames.isEmpty)
    }

    /// A star outlives the life-list entry it was set on — deleting a species'
    /// last sighting deliberately keeps it — so the manager must keep seeing it.
    @Test("a star on a species that has left the life list is still seen")
    func starOnDepartedSpeciesIsSeen() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        let sighting = LifeListEntry.Observation.at(utcDay(2020, 1, 1), "P", lat: 1, lon: 1)
        store.add(scientificName: "X y", commonName: "X", firstSeen: sighting.date,
                  location: "P", latitude: 1, longitude: 1)
        store.setStarred(scientificName: "X y", isStarred: true)
        store.removeObservation(scientificName: "X y", observation: sighting)

        #expect(!store.contains(scientificName: "X y"))
        #expect(manager(store).starredNames == ["X y"])
    }

    /// With no store there is nothing to record and nothing to star.
    @Test("a manager with no store reports no stars rather than trapping")
    func noStoreIsEmpty() {
        #expect(RecordingManager().starredNames.isEmpty)
    }
}
