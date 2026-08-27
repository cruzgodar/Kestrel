import Foundation
import Testing
@testable import Kestrel

/// The runtime record of which species have a published photo, what it hashes
/// to, and who took it.
///
/// Nothing about the photo set is bundled: this store is the app's *only*
/// knowledge of the set, and `RemoteSpeciesImageStore` refuses to show any photo
/// whose metadata is missing here. That gate is load-bearing for licensing, not
/// just display — a CC BY image shown without its credit line is a license
/// violation, not a cosmetic gap.
@Suite("PhotoManifestStore")
struct PhotoManifestStoreTests {

    private func manifest(_ entries: [String: (hash: String, credit: String?)]) -> PhotoManifest {
        let files = entries.map { slug, value -> String in
            let credit = value.credit.map { "\"\($0)\"" } ?? "null"
            return """
            "\(slug)": {"hash":"\(value.hash)","credit":\(credit),
                        "license":"CC BY-SA 4.0","pageURL":"https://example.org/\(slug)","code":"\(slug)1"}
            """
        }.joined(separator: ",")
        return PhotoManifest(data: Data("{\"files\":{\(files)}}".utf8))!
    }

    private func store(_ scratch: ScratchDirectory) -> PhotoManifestStore {
        PhotoManifestStore(directory: scratch.url)
    }

    // MARK: discovery

    @Test("a first manifest reports every slug as new and records its hash")
    func firstApplyIsAllNew() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        let result = subject.apply(manifest([
            "cardinalis_cardinalis": ("h1", "Alice"),
            "turdus_migratorius": ("h2", "Bob"),
        ]))
        #expect(Set(result.newSlugs) == ["cardinalis_cardinalis", "turdus_migratorius"])
        #expect(result.changedSlugs.isEmpty)
        #expect(result.removedSlugs.isEmpty)
        #expect(subject.recordedHash(forSlug: "cardinalis_cardinalis") == "h1")
    }

    @Test("re-applying the same manifest reports nothing")
    func reapplyIsQuiet() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        let m = manifest(["a": ("h1", "Alice")])
        _ = subject.apply(m)
        let second = subject.apply(m)
        #expect(second.newSlugs.isEmpty)
        #expect(second.changedSlugs.isEmpty)
        #expect(second.removedSlugs.isEmpty)
    }

    /// A changed slug's new hash is **not** committed here. Advancing it before
    /// the replacement bytes have landed would leave a failed refresh looking up
    /// to date, so nothing would ever come back for it.
    @Test("a changed hash is reported but not recorded until the bytes land")
    func changedHashNotAdvanced() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        _ = subject.apply(manifest(["a": ("h1", "Alice")]))
        let result = subject.apply(manifest(["a": ("h2", "Alice")]))

        #expect(result.changedSlugs == ["a"])
        #expect(result.newSlugs.isEmpty)
        #expect(subject.recordedHash(forSlug: "a") == "h1",
                "the old hash stands until the new photo is actually downloaded")

        // The caller commits it only after a successful refresh.
        subject.markValidated([], advancedHashes: ["a": "h2"])
        #expect(subject.recordedHash(forSlug: "a") == "h2")
    }

    // MARK: attribution follows the bytes

    /// A *correction* — the same photo, a fixed credit — has to land on the pass
    /// that finds it. The bytes on disk are the ones the new credit describes, so
    /// there is nothing to wait for, and waiting would leave the app knowingly
    /// showing an attribution it has already been told is wrong.
    @Test("a credit fix on an unchanged photo lands immediately")
    func creditFixAppliesAtOnce() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        _ = subject.apply(manifest(["a": ("h1", "Alice")]))
        let result = subject.apply(manifest(["a": ("h1", "Alice Corrected")]))

        #expect(result.changedSlugs.isEmpty, "same hash, so the photo itself hasn't moved")
        #expect(subject.info(forSlug: "a")?.credit == "Alice Corrected")
    }

    /// A *republished* photo is the opposite case, and it used to be handled the
    /// same way. The cached bytes go on being served until a Wi-Fi-and-power pass
    /// re-downloads them — days, on a phone that is rarely both — and writing the
    /// incoming credit in on sight captioned photo v1 with photo v2's
    /// photographer and license for that entire window. That is the same failure
    /// `isAttributed` exists to prevent, wearing a plausible name instead of a
    /// blank one.
    @Test("a republished photo keeps its old credit until the new bytes land")
    func republishedCreditWaitsForItsBytes() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        _ = subject.apply(manifest(["a": ("h1", "Alice")]))
        let result = subject.apply(manifest(["a": ("h2", "Bob")]))

        #expect(result.changedSlugs == ["a"])
        #expect(subject.info(forSlug: "a")?.credit == "Alice",
                "the cached bytes are still Alice's photo, so the caption still says Alice")
        #expect(subject.recordedHash(forSlug: "a") == "h1")

        // The refresh landed: hash and credit turn over together.
        subject.markValidated([], advancedHashes: ["a": "h2"])
        #expect(subject.recordedHash(forSlug: "a") == "h2")
        #expect(subject.info(forSlug: "a")?.credit == "Bob")
    }

    /// The held-back credit is *held*, not dropped. A foreground pass finds the
    /// change, does nothing about the bytes (that's the metered-network rule),
    /// and the app is relaunched before the high-power pass ever runs.
    @Test("a held-back credit survives a relaunch and still promotes")
    func heldBackCreditSurvivesRelaunch() {
        let scratch = ScratchDirectory()
        do {
            let subject = store(scratch)
            _ = subject.apply(manifest(["a": ("h1", "Alice")]))
            _ = subject.apply(manifest(["a": ("h2", "Bob")]))
            subject.persistNow()
        }
        let reopened = store(scratch)
        #expect(reopened.info(forSlug: "a")?.credit == "Alice", "still crediting the cached bytes")

        reopened.markValidated([], advancedHashes: ["a": "h2"])
        #expect(reopened.info(forSlug: "a")?.credit == "Bob",
                "and the parked credit was still there to promote")
    }

    /// A slug republished twice before either refresh lands: the newest credit is
    /// the one that eventually promotes, because it is the one describing the
    /// bytes a refresh would actually fetch.
    @Test("a second republish supersedes the first held-back credit")
    func laterRepublishSupersedesTheHeldCredit() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        _ = subject.apply(manifest(["a": ("h1", "Alice")]))
        _ = subject.apply(manifest(["a": ("h2", "Bob")]))
        _ = subject.apply(manifest(["a": ("h3", "Carol")]))

        #expect(subject.info(forSlug: "a")?.credit == "Alice")
        subject.markValidated([], advancedHashes: ["a": "h3"])
        #expect(subject.info(forSlug: "a")?.credit == "Carol")
    }

    /// A republish that is *reverted* upstream before the app ever pulls it. The
    /// hash comes back to what we hold, so the slug stops being changed — and the
    /// parked credit has to be dropped with it, or a later unrelated hash bump
    /// would promote a credit for bytes that were never published.
    @Test("a reverted republish drops the credit it had parked")
    func revertedRepublishDiscardsTheHeldCredit() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        _ = subject.apply(manifest(["a": ("h1", "Alice")]))
        _ = subject.apply(manifest(["a": ("h2", "Bob")]))
        _ = subject.apply(manifest(["a": ("h1", "Alice")]))

        #expect(subject.info(forSlug: "a")?.credit == "Alice")
        subject.markValidated([], advancedHashes: ["a": "hLater"])
        #expect(subject.info(forSlug: "a")?.credit == "Alice",
                "Bob's credit was never published for any bytes we hold")
    }

    /// Wiping the cache is the one thing that makes waiting *wrong*. Every asset
    /// URL is unversioned, so with no bytes on disk the next load fetches the
    /// republished photo — and holding its credit back past that point produces
    /// the identical mis-crediting in the opposite direction.
    @Test("clearing the cache promotes every held-back credit")
    func clearingStampsPromotesHeldCredits() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        _ = subject.apply(manifest(["a": ("h1", "Alice")]))
        subject.markValidated(["a"])
        _ = subject.apply(manifest(["a": ("h2", "Bob")]))
        #expect(subject.info(forSlug: "a")?.credit == "Alice")

        subject.clearValidationStamps()
        #expect(subject.info(forSlug: "a")?.credit == "Bob",
                "the bytes Alice's credit described are gone")
    }

    /// The one case that must *not* wait: a hash on record with no credit beside
    /// it — what an upgrade from the bundled-metadata build leaves behind. There
    /// is nothing to keep showing, so withholding wouldn't preserve a correct
    /// caption, it would leave the species unattributed and therefore invisible
    /// (see `RemoteSpeciesImageStore.isAttributed`) and pin `needsMetadataBackfill`
    /// on forever.
    @Test("a changed slug with no credit at all is attributed at once")
    func bareHashIsAttributedWithoutWaiting() throws {
        let scratch = ScratchDirectory()
        try Data("""
        {"hashes":{"a":"h1"},"metadata":{},"validatedAt":{}}
        """.utf8).write(to: scratch.url.appendingPathComponent("photos_manifest_local.json"))

        let subject = store(scratch)
        #expect(subject.needsMetadataBackfill)

        let result = subject.apply(manifest(["a": ("h2", "Alice")]))
        #expect(result.changedSlugs == ["a"], "the published photo really has moved on")
        #expect(subject.info(forSlug: "a")?.credit == "Alice", "and yet it is attributed now")
        #expect(!subject.needsMetadataBackfill, "so the backfill terminates")
    }

    /// A photo withdrawn while its republish was still parked takes the parked
    /// credit with it — nothing is left to promote it onto.
    @Test("withdrawing a slug drops the credit it had parked")
    func withdrawalDropsTheHeldCredit() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        var entries: [String: (hash: String, credit: String?)] = [:]
        for i in 0..<80 { entries["slug\(i)"] = ("h\(i)", "Alice") }
        _ = subject.apply(manifest(entries))

        entries["slug0"] = ("changed", "Bob")
        _ = subject.apply(manifest(entries))
        #expect(subject.info(forSlug: "slug0")?.credit == "Alice")

        entries.removeValue(forKey: "slug0")
        let result = subject.apply(manifest(entries))
        #expect(result.removedSlugs == ["slug0"])
        #expect(subject.info(forSlug: "slug0") == nil)

        // Nothing to promote onto, so a stray advance can't resurrect it.
        subject.markValidated([], advancedHashes: ["slug0": "changed"])
        #expect(subject.info(forSlug: "slug0") == nil)
    }

    @Test("an unknown slug has no metadata")
    func unknownSlugHasNoMetadata() {
        let scratch = ScratchDirectory()
        #expect(store(scratch).info(forSlug: "never_published") == nil)
    }

    @Test("a malformed manifest is rejected rather than half-applied")
    func malformedManifestRejected() {
        #expect(PhotoManifest(data: Data("not json".utf8)) == nil)
        #expect(PhotoManifest(data: Data("{}".utf8)) == nil)
        #expect(PhotoManifest(data: Data()) == nil)
    }

    // MARK: withdrawal and the prune floor

    @Test("a slug the manifest stops listing is dropped")
    func withdrawnSlugDropped() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        var entries: [String: (hash: String, credit: String?)] = [:]
        for i in 0..<80 { entries["slug\(i)"] = ("h\(i)", "Alice") }
        _ = subject.apply(manifest(entries))

        entries.removeValue(forKey: "slug0")
        let result = subject.apply(manifest(entries))
        #expect(result.removedSlugs == ["slug0"])
        #expect(subject.recordedHash(forSlug: "slug0") == nil)
        #expect(subject.info(forSlug: "slug0") == nil)
    }

    /// Pruning is the one thing `apply` does that *removes* knowledge, and it
    /// takes cached image bytes with it. A manifest that decodes cleanly but was
    /// published short — a half-run build script, a bad deploy — would otherwise
    /// wipe most of the photo set off the device and make the app re-download it,
    /// possibly over cellular.
    @Test("a manifest that lost most of the set does not prune")
    func shortManifestDoesNotPrune() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        var entries: [String: (hash: String, credit: String?)] = [:]
        for i in 0..<100 { entries["slug\(i)"] = ("h\(i)", "Alice") }
        _ = subject.apply(manifest(entries))

        // A "manifest" carrying a tenth of the set is far more likely to be wrong
        // than the local copy is.
        var truncated: [String: (hash: String, credit: String?)] = [:]
        for i in 0..<10 { truncated["slug\(i)"] = ("h\(i)", "Alice") }
        let result = subject.apply(manifest(truncated))

        #expect(result.removedSlugs.isEmpty, "a suspiciously short manifest is not authority to delete")
        #expect(subject.recordedHash(forSlug: "slug99") == "h99")
    }

    @Test("a manifest that lost only a few entries does prune")
    func modestLossDoesPrune() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        var entries: [String: (hash: String, credit: String?)] = [:]
        for i in 0..<100 { entries["slug\(i)"] = ("h\(i)", "Alice") }
        _ = subject.apply(manifest(entries))

        for i in 0..<3 { entries.removeValue(forKey: "slug\(i)") }
        let result = subject.apply(manifest(entries))
        #expect(Set(result.removedSlugs) == ["slug0", "slug1", "slug2"],
                "photos do get withdrawn a few at a time")
    }

    /// The baseline the completeness check measures against is what the app knew
    /// *before* this manifest, not after.
    ///
    /// `apply` records every newly-published slug's hash on its way through, so
    /// reading the count afterwards sized the check against a number this same
    /// manifest had just inflated — which made the guard progressively stricter
    /// the more the photo set grew. Here the manifest lists 70 species against a
    /// baseline of 100: it has not lost half the set, so the 75 it stopped
    /// listing are genuinely withdrawn and their bytes should go.
    @Test("the completeness check is measured against the pre-apply baseline")
    func completenessUsesPreApplyBaseline() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        var known: [String: (hash: String, credit: String?)] = [:]
        for i in 0..<100 { known["slug\(i)"] = ("h\(i)", "Alice") }
        _ = subject.apply(manifest(known))

        // 25 of the originals survive; 45 species are newly published alongside.
        var next: [String: (hash: String, credit: String?)] = [:]
        for i in 0..<25 { next["slug\(i)"] = ("h\(i)", "Alice") }
        for i in 0..<45 { next["new\(i)"] = ("n\(i)", "Bob") }
        let result = subject.apply(manifest(next))

        #expect(result.newSlugs.count == 45)
        #expect(result.removedSlugs.count == 75,
                "70 listed against a baseline of 100 is not a short manifest")
        #expect(subject.recordedHash(forSlug: "slug99") == nil)
        #expect(subject.info(forSlug: "slug99") == nil)
    }

    /// The same confusion at the floor. An install knowing 49 slugs is below it
    /// and prunes unconditionally — but counting after the loop let a manifest's
    /// own additions carry the total over 50 and switch the ratio check on.
    @Test("newly published slugs cannot push a below-floor install over it")
    func additionsDoNotCrossTheFloor() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        var known: [String: (hash: String, credit: String?)] = [:]
        for i in 0..<49 { known["slug\(i)"] = ("h\(i)", "Alice") }
        _ = subject.apply(manifest(known))

        var next: [String: (hash: String, credit: String?)] = ["slug0": ("h0", "Alice")]
        for i in 0..<24 { next["new\(i)"] = ("n\(i)", "Bob") }
        let result = subject.apply(manifest(next))

        #expect(result.removedSlugs.count == 48,
                "49 known is below the floor, whatever this manifest also added")
    }

    /// Below the floor there is no baseline worth defending — an install that
    /// knows about a dozen photos shouldn't refuse to prune.
    @Test("a small local set prunes without the completeness check")
    func smallSetAlwaysPrunes() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        _ = subject.apply(manifest(["a": ("h1", "Alice"), "b": ("h2", "Bob")]))
        let result = subject.apply(manifest(["a": ("h1", "Alice")]))
        #expect(result.removedSlugs == ["b"])
    }

    // MARK: freshness

    @Test("a never-confirmed slug counts as stale")
    func neverConfirmedIsStale() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        _ = subject.apply(manifest(["a": ("h1", "Alice")]))
        #expect(subject.staleSlugs(["a"], maxAge: 86_400) == ["a"],
                "an install upgrading from a build without this record revalidates once")
    }

    @Test("a freshly confirmed slug is not stale, and goes stale on the clock")
    func freshnessWindow() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        let now = Date()
        subject.markValidated(["a"], now: now)

        #expect(subject.staleSlugs(["a"], maxAge: 86_400, now: now).isEmpty)
        #expect(subject.staleSlugs(["a"], maxAge: 86_400, now: now.addingTimeInterval(86_399)).isEmpty)
        #expect(subject.staleSlugs(["a"], maxAge: 86_400, now: now.addingTimeInterval(86_401)) == ["a"])
    }

    @Test("a freshly downloaded slug starts its freshness window")
    func downloadStampsFreshness() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        let now = Date()
        subject.markDownloaded("a", now: now)
        #expect(subject.staleSlugs(["a"], maxAge: 86_400, now: now).isEmpty,
                "bytes just off the CDN are current by definition")
    }

    @Test("advancing a hash also restarts the freshness window")
    func advancingHashStampsFreshness() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        let now = Date()
        subject.markValidated([], advancedHashes: ["a": "h2"], now: now)
        #expect(subject.recordedHash(forSlug: "a") == "h2")
        #expect(subject.staleSlugs(["a"], maxAge: 86_400, now: now).isEmpty)
    }

    @Test("clearing the stamps makes everything stale again")
    func clearStamps() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        subject.markValidated(["a", "b"])
        #expect(subject.staleSlugs(["a", "b"], maxAge: 86_400).isEmpty)
        subject.clearValidationStamps()
        #expect(Set(subject.staleSlugs(["a", "b"], maxAge: 86_400)) == ["a", "b"])
    }

    @Test("staleSlugs only reports slugs it was asked about")
    func staleSlugsIsScoped() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        subject.markValidated(["a"])
        #expect(subject.staleSlugs(["a"], maxAge: 86_400).isEmpty)
        #expect(subject.staleSlugs(["b"], maxAge: 86_400) == ["b"])
        #expect(subject.staleSlugs([], maxAge: 86_400).isEmpty)
    }

    // MARK: metadata backfill

    /// The state an install is left in by upgrading from a build that bundled its
    /// metadata: hashes on record, no metadata beside them. Those species show no
    /// photo until the next fetch, so the foreground check skips its throttle
    /// while this is true.
    @Test("a hash with no metadata beside it asks for a backfill")
    func backfillFlag() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        #expect(!subject.needsMetadataBackfill, "a fresh install knows about nothing")

        _ = subject.apply(manifest(["a": ("h1", "Alice")]))
        #expect(!subject.needsMetadataBackfill,
                "a slug whose hash apply records gets its metadata in the same breath")
    }

    /// A withdrawn photo's hash sitting in local state forever with no metadata
    /// beside it pinned this flag true and made every single foreground refetch
    /// the manifest.
    @Test("withdrawing a slug does not leave the backfill flag stuck on")
    func withdrawalClearsBackfill() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        var entries: [String: (hash: String, credit: String?)] = [:]
        for i in 0..<80 { entries["slug\(i)"] = ("h\(i)", "Alice") }
        _ = subject.apply(manifest(entries))
        entries.removeValue(forKey: "slug0")
        _ = subject.apply(manifest(entries))
        #expect(!subject.needsMetadataBackfill)
    }

    /// The backfill flag is what lets the foreground check skip its six-hour
    /// throttle, so it has to be a migration that finishes — not a state the app
    /// can be stuck in, refetching the manifest on every single foreground.
    ///
    /// The way it got stuck: bare hashes are only cleared by the withdrawal prune,
    /// and `isPlausiblyComplete` vetoes that prune whenever the incoming manifest
    /// has lost more than half the set. An upgrade from the bundled-metadata build
    /// leaves the local set full of bare hashes, and the *first* manifest it
    /// applies is very likely to trip that veto — at which point the prune never
    /// runs, the bare hashes never go, and the flag never clears.
    ///
    /// Bare hashes are now dropped outside the guard. Nothing there deletes image
    /// bytes (that's `removedSlugs`, which they stay out of), and a slug with no
    /// metadata can't be shown or downloaded anyway, so the guard has nothing to
    /// protect from it.
    @Test("a vetoed prune still clears the backfill flag")
    func vetoedPruneClearsBackfill() throws {
        let scratch = ScratchDirectory()
        // A snapshot in the shape the old build left behind: hashes on record,
        // no metadata beside them.
        let hashes = (0..<80).map { "\"legacy\($0)\": \"h\($0)\"" }.joined(separator: ",")
        try Data("{\"hashes\":{\(hashes)},\"metadata\":{},\"validatedAt\":{}}".utf8)
            .write(to: scratch.url.appendingPathComponent("photos_manifest_local.json"))

        let subject = store(scratch)
        #expect(subject.needsMetadataBackfill, "80 hashes, no metadata")

        // A manifest naming none of them, and far too short to prune against.
        let result = subject.apply(manifest(["cardinalis_cardinalis": ("h1", "Alice")]))
        #expect(result.removedSlugs.isEmpty, "the completeness check vetoed the prune")

        #expect(!subject.needsMetadataBackfill, "and yet the bare hashes are gone")
        #expect(subject.recordedHash(forSlug: "legacy0") == nil)
        #expect(subject.recordedHash(forSlug: "cardinalis_cardinalis") == "h1")
    }

    /// The clearing is scoped to hashes with *no* metadata. A slug that a previous
    /// manifest described and this one omits is a withdrawal, and withdrawals stay
    /// behind the completeness guard — that guard is the thing standing between a
    /// half-published manifest and the user's cached photos.
    @Test("clearing bare hashes doesn't smuggle attributed slugs past the prune guard")
    func attributedSlugsStillNeedTheGuard() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        var entries: [String: (hash: String, credit: String?)] = [:]
        for i in 0..<80 { entries["slug\(i)"] = ("h\(i)", "Alice") }
        _ = subject.apply(manifest(entries))

        let result = subject.apply(manifest(["slug0": ("h0", "Alice")]))
        #expect(result.removedSlugs.isEmpty, "a manifest that lost most of the set does not prune")
        #expect(subject.recordedHash(forSlug: "slug1") == "h1", "still on record")
        #expect(subject.info(forSlug: "slug1") != nil, "and still attributed")
    }

    // MARK: persistence

    /// The encode and the disk write happen on the IO queue, outside the lock —
    /// only the (O(1), copy-on-write) dictionary snapshot is taken under it.
    ///
    /// The lock is the same one `info(forSlug:)` takes, and that is read from view
    /// bodies and `.task`s on every photo the app draws (via
    /// `RemoteSpeciesImageStore.isAttributed`). Encoding a manifest describing
    /// every photographed species while holding it stalled the main thread for the
    /// length of the encode, so a manifest apply landing mid-scroll hitched the
    /// scroll.
    ///
    /// Measured as "does the mutating call return before its own encode finishes",
    /// which is the same statement: nothing can return early while still encoding
    /// inside the lock. The bound is *relative* — the same write, waited on via
    /// `persistNow` — so it calibrates itself to whatever machine it runs on
    /// rather than hard-coding a duration.
    @Test("a mutation does not hold the lock through its own encode")
    func mutationDoesNotEncodeUnderTheLock() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        var entries: [String: (hash: String, credit: String?)] = [:]
        for i in 0..<10_000 {
            entries["slug\(i)"] = ("hash\(i)", "A photographer with a reasonably long name \(i)")
        }
        _ = subject.apply(manifest(entries))
        subject.persistNow()   // settle, so the timings below start from quiet

        let keys = Array(entries.keys)
        let queuedStart = Date()
        subject.markValidated(keys)
        let queued = Date().timeIntervalSince(queuedStart)

        // The same work, waited on. `persistNow` is a barrier by construction, so
        // this necessarily includes an encode and a file write.
        let flushedStart = Date()
        subject.persistNow()
        let flushed = Date().timeIntervalSince(flushedStart)

        #expect(
            queued * 4 < flushed,
            "markValidated took \(queued)s against a \(flushed)s flush — it is encoding under the lock"
        )
    }

    /// The write being asynchronous must not make the in-memory state lag: what
    /// `apply` recorded is readable the instant it returns, whatever the file is
    /// doing.
    @Test("state applied is readable before the write has landed")
    func appliedStateIsImmediatelyVisible() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        _ = subject.apply(manifest(["a": ("h1", "Alice")]))
        #expect(subject.recordedHash(forSlug: "a") == "h1")
        #expect(subject.info(forSlug: "a")?.credit == "Alice")
    }

    /// `persistNow` has to be a barrier, not just a nudge — a test that reads the
    /// file back needs the write to have finished, and the write is queued now.
    @Test("persistNow waits for the write it queued")
    func persistNowIsABarrier() {
        let scratch = ScratchDirectory()
        let subject = store(scratch)
        _ = subject.apply(manifest(["a": ("h1", "Alice")]))
        subject.persistNow()
        #expect(
            scratch.data("photos_manifest_local.json") != nil,
            "the snapshot is on disk by the time persistNow returns"
        )
    }


    @Test("hashes, metadata and stamps survive a relaunch")
    func snapshotPersists() {
        let scratch = ScratchDirectory()
        let now = Date()
        do {
            let subject = store(scratch)
            _ = subject.apply(manifest(["a": ("h1", "Alice"), "b": ("h2", nil)]))
            subject.markValidated(["a"], now: now)
            subject.persistNow()
        }
        let reopened = store(scratch)
        #expect(reopened.recordedHash(forSlug: "a") == "h1")
        #expect(reopened.info(forSlug: "a")?.credit == "Alice")
        #expect(reopened.info(forSlug: "b") != nil, "a photo with no named contributor is still attributed")
        #expect(reopened.staleSlugs(["a"], maxAge: 86_400, now: now).isEmpty)
        #expect(reopened.staleSlugs(["b"], maxAge: 86_400, now: now) == ["b"])
    }

    /// A snapshot written before per-slug freshness existed has no stamps map. A
    /// missing map means nothing has been validated, which correctly makes the
    /// whole cache stale on the first launch of this build.
    @Test("a pre-freshness snapshot decodes with everything stale")
    func legacySnapshotDecodes() throws {
        let scratch = ScratchDirectory()
        try Data("""
        {"hashes":{"a":"h1"},
         "metadata":{"a":{"credit":"Alice","license":"CC BY-SA 4.0","pageURL":null,"code":null}}}
        """.utf8).write(to: scratch.url.appendingPathComponent("photos_manifest_local.json"))

        let subject = store(scratch)
        #expect(subject.recordedHash(forSlug: "a") == "h1")
        #expect(subject.info(forSlug: "a")?.credit == "Alice")
        #expect(subject.staleSlugs(["a"], maxAge: 86_400) == ["a"])
    }

    @Test("a corrupt snapshot leaves the store empty rather than crashing")
    func corruptSnapshotTolerated() throws {
        let scratch = ScratchDirectory()
        try Data("{ not json".utf8).write(to: scratch.url.appendingPathComponent("photos_manifest_local.json"))
        let subject = store(scratch)
        #expect(subject.recordedHash(forSlug: "a") == nil)
    }
}

/// The revalidation result's own reporting.
@Suite("RevalidationResult")
struct RevalidationResultTests {

    /// A pass that only turned up newly published species did real work. A caller
    /// treating it as empty both swallows the log line and — worse — skips the
    /// prefetch those species depend on, leaving them to trickle in one lazy load
    /// at a time.
    @Test("a pass that only discovered new species is not empty")
    func discoveriesCount() {
        var result = RemoteSpeciesImageStore.RevalidationResult()
        #expect(result.isEmpty)

        result.discoveredSlugs = ["newly_published_bird"]
        #expect(!result.isEmpty)
    }

    @Test("every other kind of work also counts as non-empty")
    func otherWorkCounts() {
        for mutate in [
            { (r: inout RemoteSpeciesImageStore.RevalidationResult) in r.confirmed = 1 },
            { r in r.refreshed = 1 },
            { r in r.failed = 1 },
            { r in r.withdrawn = 1 },
        ] {
            var result = RemoteSpeciesImageStore.RevalidationResult()
            mutate(&result)
            #expect(!result.isEmpty)
        }
    }

    @Test("a genuinely idle pass is empty")
    func idlePassIsEmpty() {
        #expect(RemoteSpeciesImageStore.RevalidationResult().isEmpty)
    }
}

/// URL construction for the photo CDN.
@Suite("Photo asset URLs")
struct PhotoAssetURLTests {

    /// Un-versioned by design: the set grows and is corrected in place, and the
    /// app notices by diffing the manifest at the same base.
    @Test("asset URLs are base/folder/slug.jpg with no version pin")
    func assetURLShape() {
        let url = RemoteSpeciesImageStore.assetURL(slug: "cardinalis_cardinalis", folder: "thumb")
        #expect(url?.absoluteString ==
                "\(RemoteSpeciesImageStore.assetBaseURL)/thumb/cardinalis_cardinalis.jpg")
        #expect(url?.absoluteString.contains("@") == false, "nothing pins a tag")
    }

    @Test("each size folder resolves separately")
    func perSizeFolders() {
        #expect(ImageSize.thumb.folder == "thumb")
        #expect(ImageSize.medium.folder == "hero")
        for folder in ["thumb", "hero", "full"] {
            #expect(RemoteSpeciesImageStore.assetURL(slug: "a_b", folder: folder)?
                .absoluteString.hasSuffix("/\(folder)/a_b.jpg") == true)
        }
    }

    @Test("the manifest sits at the base")
    func manifestURL() {
        #expect(RemoteSpeciesImageStore.manifestURL()?.absoluteString ==
                "\(RemoteSpeciesImageStore.assetBaseURL)/manifest.json")
    }

    @Test("launch targets put the life list first and deduplicate")
    func launchTargets() {
        let targets = RemoteSpeciesImageStore.launchTargets(
            lifeList: ["Cardinalis cardinalis", "Turdus migratorius", "Cardinalis cardinalis"]
        )
        #expect(targets.prefix(2) == ["Cardinalis cardinalis", "Turdus migratorius"])
        #expect(targets.count == Set(targets).count)
    }
}
