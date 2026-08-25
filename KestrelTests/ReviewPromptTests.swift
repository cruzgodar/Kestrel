import Foundation
import Testing
@testable import Kestrel

/// When the app is willing to ask for an App Store review.
///
/// Serialized, because `ReviewPrompt` is an enum of statics over a single
/// `UserDefaults` — the tests swap in a scratch suite and must not do so
/// concurrently. Each test restores the real one on the way out, so a failure
/// can't leave the app's own counters pointed at a temporary suite.
@Suite("ReviewPrompt", .serialized)
@MainActor
struct ReviewPromptTests {

    /// Runs `body` against a private defaults suite.
    private func withScratchDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let scratch = ScratchDefaults()
        let real = ReviewPrompt.defaults
        ReviewPrompt.defaults = scratch.defaults
        defer { ReviewPrompt.defaults = real }
        try body(scratch.defaults)
    }

    // MARK: what counts as a session

    /// A twenty-second tap-and-stop is no evidence the app is worth reviewing, so
    /// short sessions are ignored entirely rather than counted at a discount.
    @Test("sessions shorter than a minute don't count")
    func shortSessionsIgnored() {
        withScratchDefaults { _ in
            for duration in [0.0, 1, 30, 59, 59.999] {
                ReviewPrompt.recordSession(duration: duration)
            }
            #expect(ReviewPrompt.qualifyingSessionCount == 0)
        }
    }

    @Test("a session of exactly the minimum counts")
    func minimumDurationCounts() {
        withScratchDefaults { _ in
            ReviewPrompt.recordSession(duration: ReviewPrompt.minimumSessionDuration)
            #expect(ReviewPrompt.qualifyingSessionCount == 1)
        }
    }

    @Test("qualifying sessions accumulate")
    func sessionsAccumulate() {
        withScratchDefaults { _ in
            for _ in 0..<7 { ReviewPrompt.recordSession(duration: 120) }
            #expect(ReviewPrompt.qualifyingSessionCount == 7)
        }
    }

    // MARK: the first ask

    @Test("the prompt isn't due before three qualifying sessions")
    func notDueBeforeThreshold() {
        withScratchDefaults { _ in
            #expect(!ReviewPrompt.isDue)
            ReviewPrompt.recordSession(duration: 120)
            #expect(!ReviewPrompt.isDue)
            ReviewPrompt.recordSession(duration: 120)
            #expect(!ReviewPrompt.isDue)
            ReviewPrompt.recordSession(duration: 120)
            #expect(ReviewPrompt.isDue, "three real walks in")
        }
    }

    @Test("short sessions don't advance the user toward the prompt")
    func shortSessionsDontAdvance() {
        withScratchDefaults { _ in
            for _ in 0..<20 { ReviewPrompt.recordSession(duration: 10) }
            #expect(!ReviewPrompt.isDue)
        }
    }

    // MARK: the cooldown

    /// Asks land at 3 sessions, then 9, then 15 — counted in sessions rather than
    /// marked against the app version, so someone who declines isn't asked again
    /// on their very next walk, and a heavy user isn't asked again the moment a
    /// new version ships.
    @Test("after an ask, six more qualifying sessions must go by")
    func cooldownBetweenAsks() {
        withScratchDefaults { defaults in
            for _ in 0..<3 { ReviewPrompt.recordSession(duration: 120) }
            #expect(ReviewPrompt.isDue)

            // Simulate the ask having gone out.
            defaults.set(ReviewPrompt.qualifyingSessionCount, forKey: "review.promptedAtSessionCount")
            #expect(!ReviewPrompt.isDue)

            for i in 1...5 {
                ReviewPrompt.recordSession(duration: 120)
                #expect(!ReviewPrompt.isDue, "only \(i) sessions into the cooldown")
            }
            ReviewPrompt.recordSession(duration: 120)
            #expect(ReviewPrompt.isDue, "asks land at 3, then 9")
        }
    }

    @Test("the ask schedule is 3, then 9, then 15")
    func askSchedule() {
        withScratchDefaults { defaults in
            var asks: [Int] = []
            for _ in 0..<20 {
                ReviewPrompt.recordSession(duration: 120)
                if ReviewPrompt.isDue {
                    asks.append(ReviewPrompt.qualifyingSessionCount)
                    defaults.set(ReviewPrompt.qualifyingSessionCount, forKey: "review.promptedAtSessionCount")
                }
            }
            #expect(asks == [3, 9, 15])
        }
    }

    // MARK: migration from the version-stamped scheme

    /// An install that predates the cooldown recorded only the version it asked
    /// on. Backdating that ask to *now* rather than to zero means someone who was
    /// already asked waits out a full cooldown instead of being asked again on
    /// their very next session.
    ///
    /// The migration is invoked the way the app invokes it — once, at launch —
    /// rather than falling out of the first read of `isDue`.
    @Test("a pre-cooldown install is backdated, not asked immediately")
    func migrationBackdatesTheAsk() {
        withScratchDefaults { defaults in
            for _ in 0..<10 { ReviewPrompt.recordSession(duration: 120) }
            defaults.set("1.0", forKey: "review.promptedAppVersion")
            defaults.removeObject(forKey: "review.promptedAtSessionCount")

            ReviewPrompt.migrateLegacyPromptRecord()

            #expect(!ReviewPrompt.isDue, "they were already asked; a full cooldown starts now")
            #expect(defaults.object(forKey: "review.promptedAtSessionCount") as? Int == 10)

            for _ in 0..<5 { ReviewPrompt.recordSession(duration: 120) }
            #expect(!ReviewPrompt.isDue)
            ReviewPrompt.recordSession(duration: 120)
            #expect(ReviewPrompt.isDue)
        }
    }

    /// The migration runs once. A second launch must not re-backdate the ask to
    /// the *new* count, which would push the next prompt out by a further cooldown
    /// every time the app started.
    @Test("the backdate is pinned, not recomputed on every launch")
    func migrationIsOneShot() {
        withScratchDefaults { defaults in
            for _ in 0..<10 { ReviewPrompt.recordSession(duration: 120) }
            defaults.set("1.0", forKey: "review.promptedAppVersion")
            defaults.removeObject(forKey: "review.promptedAtSessionCount")

            ReviewPrompt.migrateLegacyPromptRecord()
            #expect(defaults.object(forKey: "review.promptedAtSessionCount") as? Int == 10)

            for _ in 0..<6 { ReviewPrompt.recordSession(duration: 120) }
            // A relaunch, and another, with sessions in between.
            ReviewPrompt.migrateLegacyPromptRecord()
            ReviewPrompt.migrateLegacyPromptRecord()
            #expect(defaults.object(forKey: "review.promptedAtSessionCount") as? Int == 10)
            #expect(ReviewPrompt.isDue, "16 sessions is 10 + a full cooldown")
        }
    }

    /// Reading whether a prompt is due must not *change* when the next one is —
    /// the counters here are once-per-install state, and a getter that wrote to
    /// them made the backdate land at whatever moment something first happened to
    /// ask.
    @Test("isDue is a pure read")
    func isDueDoesNotWrite() {
        withScratchDefaults { defaults in
            for _ in 0..<10 { ReviewPrompt.recordSession(duration: 120) }
            defaults.set("1.0", forKey: "review.promptedAppVersion")
            defaults.removeObject(forKey: "review.promptedAtSessionCount")

            _ = ReviewPrompt.isDue
            _ = ReviewPrompt.isDue
            #expect(
                defaults.object(forKey: "review.promptedAtSessionCount") == nil,
                "only migrateLegacyPromptRecord() writes the ask point"
            )
        }
    }

    @Test("an install that was never asked is due as soon as it qualifies")
    func neverAskedIsDueAtThreshold() {
        withScratchDefaults { defaults in
            defaults.removeObject(forKey: "review.promptedAppVersion")
            defaults.removeObject(forKey: "review.promptedAtSessionCount")
            for _ in 0..<3 { ReviewPrompt.recordSession(duration: 120) }
            #expect(ReviewPrompt.isDue)
        }
    }

    /// The counter is cumulative for the life of the install and never reset —
    /// the cooldown is expressed as an offset from it, so it has to keep climbing.
    @Test("the session counter is never reset")
    func counterIsCumulative() {
        withScratchDefaults { defaults in
            for _ in 0..<9 { ReviewPrompt.recordSession(duration: 120) }
            defaults.set(9, forKey: "review.promptedAtSessionCount")
            #expect(ReviewPrompt.qualifyingSessionCount == 9)
            ReviewPrompt.recordSession(duration: 120)
            #expect(ReviewPrompt.qualifyingSessionCount == 10, "it only ever grows")
        }
    }
}

/// Slug derivation for photo filenames. The algorithm has to mirror `slug_for`
/// in the photo set's own build script exactly — a mismatch means the app asks
/// the CDN for a filename that isn't there and silently shows a placeholder.
@Suite("SpeciesImage.slug")
struct SpeciesImageSlugTests {

    @Test(
        "names slug to lowercase ASCII with runs of punctuation collapsed",
        arguments: [
            ("Cardinalis cardinalis", "cardinalis_cardinalis"),
            ("Dryobates villosus harrisi", "dryobates_villosus_harrisi"),
            ("CARDINALIS CARDINALIS", "cardinalis_cardinalis"),
            ("Cardinalis  cardinalis", "cardinalis_cardinalis"),
            ("Motacilla alba", "motacilla_alba"),
        ]
    )
    func slugging(name: String, expected: String) {
        #expect(SpeciesImage.slug(for: name) == expected)
    }

    /// Decomposable diacritics fold to their base letter. (Non-decomposing
    /// letters like `æ` would survive, but no scientific name contains one —
    /// see `everyCatalogNameSlugsToASCII`, which checks the real data rather
    /// than an invented input.)
    @Test("diacritics fold to their base letter")
    func diacriticsStripped() {
        #expect(SpeciesImage.slug(for: "Île d\u{2019}Orléans") == "ile_d_orleans")
        #expect(SpeciesImage.slug(for: "Ünïcödé Bïrd") == "unicode_bird")
        #expect(SpeciesImage.slug(for: "Motacilla ãlbá") == "motacilla_alba")
    }

    @Test("punctuation collapses to single underscores and never leads or trails")
    func punctuationCollapses() {
        #expect(SpeciesImage.slug(for: "A-B/C.D") == "a_b_c_d")
        #expect(SpeciesImage.slug(for: "  spaced  out  ") == "spaced_out")
        #expect(SpeciesImage.slug(for: "---A---B---") == "a_b")
        #expect(SpeciesImage.slug(for: "!!!") == "")
    }

    /// The invariant that actually protects the photo set, checked against the
    /// shipped catalog rather than a handful of invented names: every species the
    /// app can look up must produce a filename-safe ASCII slug. Anything else is
    /// a request to the CDN for a name that cannot be there, which shows as a
    /// silent placeholder.
    @Test("every species in the shipped catalog slugs to filename-safe ASCII")
    func everyCatalogNameSlugsToASCII() {
        for species in SpeciesCatalog.shared.all {
            let slug = SpeciesImage.slug(for: species.scientificName)
            #expect(!slug.isEmpty, "\(species.scientificName) slugged to nothing")
            #expect(slug.allSatisfy { ($0.isASCII && $0.isLowercase) || $0.isNumber || $0 == "_" },
                    "\(species.scientificName) slugged to \(slug.debugDescription)")
        }
    }

    /// Two species sharing a slug would share a photo file — one of them would
    /// silently show the other's bird, with the other's credit line.
    @Test("no two catalog species share a slug")
    func slugsAreUniqueAcrossTheCatalog() {
        var seen: [String: String] = [:]
        for species in SpeciesCatalog.shared.all {
            let slug = SpeciesImage.slug(for: species.scientificName)
            if let existing = seen[slug] {
                Issue.record("\(existing) and \(species.scientificName) both slug to \(slug)")
            }
            seen[slug] = species.scientificName
        }
        #expect(seen.count == SpeciesCatalog.shared.all.count)
    }

    @Test("an empty name slugs to nothing, which every read path treats as no photo")
    func emptyName() {
        #expect(SpeciesImage.slug(for: "").isEmpty)
    }

    @Test("slugging is stable")
    func slugIsStable() {
        let name = "Dryobates villosus"
        #expect(SpeciesImage.slug(for: name) == SpeciesImage.slug(for: name))
    }
}

/// The leaked-temp-model sweep. It deletes directories in the app's own tmp, so
/// the guard that decides what *not* to delete is worth pinning precisely.
@Suite("CoreMLModelCache temp sweep")
struct CoreMLModelCacheTests {

    private let pid = ProcessInfo.processInfo.processIdentifier

    /// ORT names them `onnxruntime-<uuid>-<pid>-<hex>.model.mlmodelc`, with the
    /// pid in the seventh hyphen-separated position.
    @Test("an entry carrying this process's pid is left alone")
    func ownEntryIsSkipped() {
        let url = URL(fileURLWithPath:
            "/tmp/onnxruntime-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE-\(pid)-abc.model.mlmodelc")
        #expect(CoreMLModelCache.isOwnedByThisProcess(url),
                "pulling a live model out from under a running session is not worth a few MB")
    }

    @Test("an entry from another process is eligible for deletion")
    func foreignEntryIsSweepable() {
        let other = pid == 1 ? 2 : 1
        let url = URL(fileURLWithPath:
            "/tmp/onnxruntime-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE-\(other)-abc.model.mlmodelc")
        #expect(!CoreMLModelCache.isOwnedByThisProcess(url))
    }

    /// Unparseable names are treated as *ours*, so an unrecognized naming scheme
    /// is left alone rather than deleted blind.
    @Test(
        "an unrecognized name is treated as ours and left alone",
        arguments: [
            "onnxruntime-too-few-parts",
            "onnxruntime-AAAA-BBBB-CCCC-DDDD-EEEE-notanumber-abc.model.mlmodelc",
            "onnxruntime",
            "something-else-entirely",
        ]
    )
    func unparseableIsProtected(name: String) {
        #expect(CoreMLModelCache.isOwnedByThisProcess(URL(fileURLWithPath: "/tmp/\(name)")),
                "\(name) should not be deleted on a guess")
    }

    /// Age is deliberately *not* the filter: it left the most recent leak — the
    /// largest one — sitting for an hour after the user updated.
    @Test("the sweep runs without throwing on a real temp directory")
    func sweepIsSafe() {
        CoreMLModelCache.purgeLegacyTempModels()
    }
}
