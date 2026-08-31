import Foundation
import Testing
import UserNotifications
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

/// How a notification is presented while the app is on screen.
///
/// The rule is about the **sound**, not the banner: everything Kestrel posts
/// banners, because whether an alert is wanted at all is decided where it is
/// posted (a species alert only exists when `RecordingManager.spectrogramVisible`
/// is false, a lifecycle alert only when a session has actually ended). Deciding
/// it a second time here, under a different rule, is what used to swallow real
/// alerts — recording while looking at the Map tab posted a new-species
/// notification that this delegate then dropped, leaving a haptic with nothing
/// anywhere naming the bird.
///
/// Presenting *everything* fixed that and overshot: species alerts carry
/// `content.sound` for the pocketed-phone case, so a walk spent with the Map tab
/// open began chirping out loud at every new lifer — from an app whose whole
/// premise is that you can put the phone away and let your wrist tell you.
@Suite("Foreground notification presentation")
struct NotificationPresentationTests {

    /// The regression. A per-bird alert already has a signal while the app is
    /// foregrounded — `RecordingManager.merge` buzzes the phone for exactly these
    /// birds — and it repeats for every new species of the walk, which is what
    /// makes an audible one intolerable rather than merely redundant.
    @Test("a species alert banners silently")
    func speciesAlertHasNoSound() {
        let options = SpeciesNotifications.presentationOptions(
            forCategory: SpeciesNotifications.speciesCategory
        )
        #expect(options.contains(.banner), "the bird still has to be named somewhere")
        #expect(!options.contains(.sound), "the haptic already said it")
    }

    /// The lifecycle notifications keep theirs. Each is a one-off asking for a
    /// decision or reporting that recording has stopped, none of them repeats,
    /// and all are worth interrupting for.
    @Test("the idle-timeout prompt still sounds", arguments: [
        SpeciesNotifications.idleTimeoutCategory,
        "",                     // `notifySessionLifecycle` sets no category
        "something-unforeseen", // and anything added later opts in by default
    ])
    func lifecycleAlertsKeepTheirSound(_ category: String) {
        let options = SpeciesNotifications.presentationOptions(forCategory: category)
        #expect(options.contains(.banner))
        #expect(options.contains(.sound))
    }

    /// The categories have to actually differ, or the branch above is decorative.
    @Test("the species category is distinct from the idle-timeout one")
    func categoriesAreDistinct() {
        #expect(SpeciesNotifications.speciesCategory != SpeciesNotifications.idleTimeoutCategory)
        #expect(!SpeciesNotifications.speciesCategory.isEmpty)
    }
}

/// Which location the nearby-species filter is built from.
///
/// The watch sends its own GPS so a watch-first user — phone never opened, so
/// the phone has no fix of its own — still gets a location-focused list. That
/// coordinate was then preferred unconditionally, and nothing cleared it when
/// the session ended, so the phone stopped consulting its own location for good:
/// every later foreground refresh and every phone-only session rebuilt the list
/// from wherever the watch last was. It is also written into `LocationCache` and
/// stamped fresh, which turns a stale filter into a stale *default pin* under
/// the next sighting the user adds.
@Suite("Session coordinate")
struct SessionCoordinateTests {

    private let ithaca = (lat: 42.4534, lon: -76.4735)

    @Test("the watch's coordinate is used while a watch session is running")
    func watchCoordinateUsedDuringSession() {
        let picked = RecordingManager.sessionCoordinate(
            watchSupplied: ithaca, watchRecording: true
        )
        #expect(picked?.lat == ithaca.lat)
        #expect(picked?.lon == ithaca.lon)
    }

    /// The regression: a coordinate that outlived its session.
    @Test("a watch coordinate left over from a finished session is ignored")
    func staleWatchCoordinateIgnored() {
        #expect(RecordingManager.sessionCoordinate(
            watchSupplied: ithaca, watchRecording: false
        ) == nil, "the phone has to go ask where it is")
    }

    @Test("a watch session that hasn't sent a fix yet falls back to the phone")
    func noWatchCoordinateFallsBack() {
        #expect(RecordingManager.sessionCoordinate(
            watchSupplied: nil, watchRecording: true
        ) == nil)
        #expect(RecordingManager.sessionCoordinate(
            watchSupplied: nil, watchRecording: false
        ) == nil)
    }
}

/// Which sessions a *phone-side* `stop()` is allowed to end.
///
/// `RecordingManager.stop()` only knows how to tear down the phone's own half of
/// a session. Run against a watch-sourced one it would clear `isRecording` and
/// cancel the idle watchdog while leaving `watchRecording`, the silent keepalive
/// and the audio-liveness watchdogs running — a session still ingesting watch
/// audio behind a UI that says nothing is recording, whose record button then
/// offers to save a birding walk. Ending a watch session from the phone is
/// `stopWatchSession`'s job.
@Suite("Phone-side stop")
struct LocalStopTests {

    @Test("a phone-mic session is the one it ends")
    func endsAPhoneSession() {
        #expect(RecordingManager.localStopApplies(isRecording: true, watchRecording: false))
    }

    /// The regression. `"stopPhone"` is the one watch command routed straight to
    /// `stop()` — `"start"` and `"stop"` go to entry points that check
    /// `watchRecording` for themselves — and the watch sends it on *both* channels
    /// at once, live and via `transferUserInfo`. The queued copy outlives app
    /// suspension, so it can be flushed after a later watch session has already
    /// begun on the live channel, arriving as a stop for a session that ended long
    /// ago. `isRecording` is true for a watch session too, so it was not enough to
    /// tell those apart.
    @Test("a watch-sourced session is left alone")
    func ignoresAWatchSession() {
        #expect(
            !RecordingManager.localStopApplies(isRecording: true, watchRecording: true),
            "the phone half is not this stop's to tear down"
        )
    }

    @Test("nothing running is nothing to stop")
    func ignoresAnIdlePhone() {
        #expect(!RecordingManager.localStopApplies(isRecording: false, watchRecording: false))
        #expect(!RecordingManager.localStopApplies(isRecording: false, watchRecording: true))
    }
}

/// Whether the phone owes the watch a heartbeat.
///
/// The watch shows a recording screen for two different things — its own
/// capture, and the mirror of a phone-mic session — and runs one watchdog over
/// both. The phone was beating for only the first, so the mirror had no liveness
/// signal: `phoneStop` is the only message that clears it, and a phone app that
/// has been killed sends none. The wrist then sat on "Listening on iPhone…" for
/// a session that had already ended, until the user happened to tap Stop.
@Suite("Phone heartbeat")
struct PhoneHeartbeatTests {

    /// Both kinds of live session beat, which is the whole point: the rule is
    /// `isRecording` and pointedly not `watchRecording`, so a mirrored phone-mic
    /// session — the case the old gate excluded — is covered by the same
    /// expression as a watch-sourced one.
    @Test("either kind of live session is beaten to")
    func beatsForALiveSession() {
        #expect(
            RecordingManager.shouldSendPhoneHeartbeat(isRecording: true),
            "the wrist is showing this session, and can't otherwise tell it ended"
        )
    }

    @Test("nothing running earns no beat")
    func silentWhenIdle() {
        #expect(!RecordingManager.shouldSendPhoneHeartbeat(isRecording: false))
    }

    /// The pairing worth stating outright, since the two guards sit in the same
    /// file and read almost alike: a stop relayed from the watch *is* the
    /// watch-vs-phone distinction, and a heartbeat is deliberately not.
    @Test("the heartbeat gate is not the local-stop gate")
    func differsFromLocalStopApplies() {
        // A watch-sourced session: the phone must beat, and must not tear its
        // own half down.
        #expect(RecordingManager.shouldSendPhoneHeartbeat(isRecording: true))
        #expect(!RecordingManager.localStopApplies(isRecording: true, watchRecording: true))
    }
}

/// Whether stopping a watch session on the phone should offer to save the walk.
///
/// The phone can answer half of that on its own — how long the session ran — and
/// was answering only that half. The other half is whether the *watch* can write
/// a workout to HealthKit at all, which is per-device authorization it can only
/// be told about. Getting that wrong wasn't a cosmetic mismatch: the prompt
/// appeared, "Save Workout" was tapped, and nothing happened. The watch had
/// already refused to park a walk it couldn't save (`canOfferSave`), discarded
/// it, and the relayed decision then found neither a builder nor a span to write.
@Suite("Watch workout prompt")
struct WatchWorkoutPromptTests {

    @Test("a long enough walk on a watch that can save is offered")
    func offersASavableWalk() {
        #expect(RecordingManager.shouldPromptForWatchWorkout(
            elapsed: 60, watchReportsSavable: true
        ))
    }

    @Test("a walk too short to be real is never offered")
    func skipsAShortWalk() {
        // Below the watch's own `minimumDuration`, where it discards the walk
        // without asking either.
        #expect(!RecordingManager.shouldPromptForWatchWorkout(
            elapsed: 5, watchReportsSavable: true
        ))
        #expect(!RecordingManager.shouldPromptForWatchWorkout(
            elapsed: 5, watchReportsSavable: nil
        ))
    }

    /// The regression. Workout sharing denied on the watch means Save cannot do
    /// anything, so asking is a promise the pair can't keep.
    @Test("a watch that cannot save is not asked about")
    func skipsAnUnsavableWalk() {
        #expect(
            !RecordingManager.shouldPromptForWatchWorkout(
                elapsed: 3600, watchReportsSavable: false
            ),
            "an hour of birding is still unsavable if Health won't take it"
        )
    }

    /// Only an explicit refusal suppresses the prompt. An older watch build sends
    /// nothing, and a handshake can be in flight — neither is evidence the walk
    /// can't be saved, and treating them as such would cost a user a real walk.
    @Test("an unheard-from watch keeps the prompt")
    func unknownStillAsks() {
        #expect(RecordingManager.shouldPromptForWatchWorkout(
            elapsed: 60, watchReportsSavable: nil
        ))
    }
}

/// Which phone session a `stopPhone` from the watch is allowed to end.
///
/// The watch sends it on both channels at once and the queued copy outlives app
/// suspension, so it can arrive after the session it was about has ended.
/// `localStopApplies` catches the case where the session running *now* is
/// watch-sourced; it cannot see the case where it is simply a different phone-mic
/// session, which is what the token is for.
@Suite("Mirrored stop token")
struct MirrorStopTests {

    @Test("a stop for the running session applies")
    func appliesToTheCurrentSession() {
        #expect(RecordingManager.mirrorStopApplies(requestToken: 7, currentToken: 7))
    }

    @Test("a stop for a session that has already ended is ignored")
    func ignoresAStaleStop() {
        #expect(
            !RecordingManager.mirrorStopApplies(requestToken: 6, currentToken: 7),
            "a queued stop must not end the recording that replaced its own"
        )
    }

    /// An older watch build sends no token. Dropping those would leave its Stop
    /// button dead, which is worse than the race they'd close.
    @Test("an untokened stop still applies")
    func appliesWithoutAToken() {
        #expect(RecordingManager.mirrorStopApplies(requestToken: nil, currentToken: 7))
    }
}
