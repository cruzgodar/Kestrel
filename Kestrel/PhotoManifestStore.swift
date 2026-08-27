import Foundation

/// The photo manifest: `files` maps each photographed species' slug to a content
/// hash plus its crediting/licensing metadata. `build_species_photos.py` (in the
/// Bird Image Selector repo) publishes it to the photo repo's default branch
/// alongside the rendered images, and the app fetches it at runtime. Nothing
/// about the photo set is bundled — this manifest is the app's only knowledge of
/// which species have photos and who took them, which is what lets the set (and
/// its attribution) be corrected or extended without an App Store submission.
/// `nonisolated`: decoded on whichever thread the fetch came back on, never the
/// main actor.
nonisolated struct PhotoManifest: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let hash: String
        let credit: String?
        let license: String?
        let pageURL: String?
        let code: String?
    }

    let files: [String: Entry]

    init?(data: Data) {
        guard let decoded = try? JSONDecoder().decode(PhotoManifest.self, from: data) else {
            return nil
        }
        self = decoded
    }
}

/// Runtime source of truth for the *growable* photo set: which species have a
/// published photo, each one's content hash (the change signal), and — for
/// species added after the app shipped — their attribution metadata. This is
/// what lets photos be added to the CDN over time and picked up **without an app
/// update**.
///
/// It holds four things, all persisted so they survive relaunch:
///   • **hashes** — recorded as published manifests are applied. Diffing an
///     incoming manifest's hashes against these is how new (unseen slug) and
///     changed (different hash) photos are found.
///   • **metadata** — the credit/license/page/code for the photo the app
///     actually holds for each species. This is the *only* source of photo
///     metadata in the app (`SpeciesPhotoMetadata` reads nothing else), so a
///     slug missing here has no photo as far as the rest of the app is
///     concerned.
///   • **pending metadata** — the credit for a photo that has been *republished*
///     upstream but whose new bytes haven't been pulled yet, held back so the
///     image and its attribution turn over together rather than the caption
///     running days ahead of the picture.
///   • **validation stamps** — when each slug's cached bytes were last confirmed
///     to match the published hash. Cached images go stale on a timer (see
///     `RemoteSpeciesImageStore.cacheFreshness`); confirming one costs a hash
///     comparison, not a download.
///
/// A fresh install therefore knows about no photos until its first successful
/// fetch. That's the intended trade: the images are remote anyway, so an install
/// that can't reach the network has nothing to show regardless, and in exchange
/// no photo, credit, or license is frozen into the app binary.
///
/// `@unchecked Sendable` + an internal lock: read from view / prefetch /
/// background paths, mutated as manifests are applied.
nonisolated final class PhotoManifestStore: @unchecked Sendable {
    static let shared = PhotoManifestStore()

    private let lock = NSLock()
    /// slug → content hash of the photo the app believes is current, advanced as
    /// manifests are applied.
    private var hashes: [String: String]
    /// slug → attribution **for the bytes the app currently holds**. Empty until
    /// the first successful fetch.
    private var metadata: [String: SpeciesPhotoInfo]
    /// slug → attribution for a *republished* photo whose bytes haven't been
    /// pulled yet, held back so the credit and the image it credits swap over
    /// together.
    ///
    /// A changed slug keeps serving its cached bytes until a Wi-Fi-and-power pass
    /// re-downloads them (see `RemoteSpeciesImageStore.checkForPhotoUpdates`),
    /// which can be days. Writing the incoming credit into `metadata` on sight
    /// meant that whole window rendered photo *v1* under photo *v2*'s
    /// photographer and license — the same failure `isAttributed` exists to
    /// prevent, wearing a plausible-looking name instead of a blank one. Parking
    /// it here and promoting it in `markValidated(_:advancedHashes:)`, the one
    /// place that knows the replacement bytes actually landed, keeps the pair
    /// atomic.
    private var pendingMetadata: [String: SpeciesPhotoInfo]
    /// slug → epoch seconds when the app last confirmed that slug's cached bytes
    /// match the published hash. A slug with no entry has never been confirmed
    /// and therefore counts as stale, which is the right default: it makes an
    /// install upgrading from a build without this record revalidate once.
    private var validatedAt: [String: Double]
    /// Serial queue for coalesced snapshot writes. See `persistSoonLocked`.
    private let persistQueue = DispatchQueue(
        label: "com.cruzgodar.Kestrel.manifest.persist", qos: .utility
    )
    /// Whether a coalesced write is already pending.
    private var persistScheduled = false

    /// Where the persisted snapshot lives. Injected rather than fixed so a test
    /// can point a store at a scratch directory: `shared` is a singleton over the
    /// app's real container, and exercising `apply` against it would rewrite the
    /// running install's record of which photos it has.
    private let snapshotURL: URL?

    private static func defaultSnapshotURL() -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("photos_manifest_local.json")
    }

    /// - Parameter directory: `nil` (the default) means the app's real
    ///   Application Support directory.
    init(directory: URL? = nil) {
        snapshotURL = directory.map { $0.appendingPathComponent("photos_manifest_local.json") }
            ?? Self.defaultSnapshotURL()
        // Persisted state from past applies, if any. There is no bundled seed:
        // everything the app knows about the photo set was fetched.
        var localHashes: [String: String] = [:]
        var localMetadata: [String: SpeciesPhotoInfo] = [:]
        var localPendingMetadata: [String: SpeciesPhotoInfo] = [:]
        var localValidatedAt: [String: Double] = [:]
        if let url = snapshotURL, let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder().decode(LocalSnapshot.self, from: data) {
            localHashes = snapshot.hashes
            localMetadata = snapshot.metadata.mapValues(\.info)
            localPendingMetadata = (snapshot.pendingMetadata ?? [:]).mapValues(\.info)
            localValidatedAt = snapshot.validatedAt ?? [:]
        }

        hashes = localHashes
        metadata = localMetadata
        pendingMetadata = localPendingMetadata
        validatedAt = localValidatedAt
    }

    // MARK: - Reads

    /// The attribution a fetched manifest supplied for a slug, if any. Nil means
    /// the app has no photo for that species — either none is published or no
    /// manifest has been fetched yet — and every image read path treats it that
    /// way (see `RemoteSpeciesImageStore.isAttributed`).
    func info(forSlug slug: String) -> SpeciesPhotoInfo? {
        lock.lock(); defer { lock.unlock() }
        return metadata[slug]
    }

    /// Whether any slug's hash is on record without its metadata — the state an
    /// install left in by upgrading from a build that bundled `species_photos.json`
    /// and seeded hashes from `photos_manifest.json`. Those species would show no
    /// photo until the next manifest fetch, so the foreground check skips its
    /// throttle while this is true and the gap closes on the first launch of the
    /// new build.
    ///
    /// Guaranteed to go false after one successful `apply`, which is what keeps
    /// the skipped throttle a one-time migration rather than a standing state:
    /// every slug the manifest carries gets metadata, and every bare hash left
    /// over is dropped. See the end of `apply`.
    var needsMetadataBackfill: Bool {
        lock.lock(); defer { lock.unlock() }
        return hashes.keys.contains { metadata[$0] == nil }
    }

    /// The hash of the photo the app believes it has cached for a slug. Compared
    /// against a freshly fetched manifest to decide whether a stale cached image
    /// actually needs re-downloading, or is byte-identical and just needs its
    /// validation stamp moved forward.
    func recordedHash(forSlug slug: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return hashes[slug]
    }

    // MARK: - Freshness

    /// The subset of `slugs` whose cached bytes haven't been confirmed against
    /// the published manifest within `maxAge`. Never-confirmed slugs are stale.
    func staleSlugs(_ slugs: [String], maxAge: TimeInterval, now: Date = Date()) -> [String] {
        let cutoff = now.timeIntervalSince1970 - maxAge
        lock.lock(); defer { lock.unlock() }
        return slugs.filter { (validatedAt[$0] ?? 0) < cutoff }
    }

    /// Stamps one freshly-downloaded slug as current. Separate from
    /// `markValidated` because this fires once per image and a bulk prefetch runs
    /// hundreds of them: it takes the coalesced write path, since a stamp lost to
    /// a kill costs nothing worse than one extra revalidation later.
    func markDownloaded(_ slug: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        validatedAt[slug] = now.timeIntervalSince1970
        persistSoonLocked()
    }

    /// Stamps slugs as confirmed-current, restarting their freshness window.
    /// `advancedHashes` carries the new published hash for any slug whose bytes
    /// were actually re-downloaded — recorded only here, *after* the download
    /// landed, so a failed refresh leaves both the old bytes and the old hash in
    /// place and the slug stays stale for the next attempt.
    ///
    /// This is also where a republished photo's held-back credit is promoted (see
    /// `pendingMetadata`). Hash and attribution advance in the same breath,
    /// because they describe the same bytes: whichever pass proves the new image
    /// is on disk proves the new credit belongs to it.
    func markValidated(
        _ slugs: [String],
        advancedHashes: [String: String] = [:],
        now: Date = Date()
    ) {
        guard !slugs.isEmpty || !advancedHashes.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let stamp = now.timeIntervalSince1970
        for slug in slugs { validatedAt[slug] = stamp }
        for (slug, hash) in advancedHashes {
            hashes[slug] = hash
            validatedAt[slug] = stamp
            if let promoted = pendingMetadata.removeValue(forKey: slug) {
                metadata[slug] = promoted
            }
        }
        persistLocked()
    }

    /// Drops every validation stamp, so the next revalidation pass re-checks the
    /// whole cache. Used when the cached bytes are wiped out from under us.
    ///
    /// Any held-back credit is promoted at the same time. `pendingMetadata`
    /// exists to keep a republished photo's credit away from the *old bytes*
    /// still on disk — and there are none now. Every asset URL is unversioned, so
    /// the next load of one of these slugs fetches the republished image, and
    /// holding its credit back past this point would produce the identical
    /// mis-crediting in the opposite direction.
    func clearValidationStamps() {
        lock.lock(); defer { lock.unlock() }
        guard !validatedAt.isEmpty || !pendingMetadata.isEmpty else { return }
        validatedAt = [:]
        for (slug, info) in pendingMetadata { metadata[slug] = info }
        pendingMetadata = [:]
        persistLocked()
    }

    // MARK: - Apply

    struct ApplyResult: Sendable {
        var newSlugs: [String] = []
        var changedSlugs: [String] = []
        /// Slugs the app had on record that the published manifest no longer
        /// lists — their photo was withdrawn from the set. Dropped from local
        /// state here; the caller deletes whatever bytes they left behind.
        var removedSlugs: [String] = []
    }

    /// Diffs a freshly-fetched published manifest against local state and records
    /// what it found.
    ///
    /// **Metadata travels with the bytes it credits.** For a slug the app has
    /// never seen, and for one whose published hash still matches ours, the
    /// incoming credit is recorded on sight: the first has no bytes for it to
    /// disagree with, and the second is a *correction* to the photo already on
    /// disk, which is exactly the fix that has to propagate immediately. It has
    /// to be recorded for those, not merely may be — it is the app's only source
    /// of credit and license (`SpeciesPhotoMetadata` reads nothing else) and
    /// `RemoteSpeciesImageStore` refuses to show a photo without it, so
    /// withholding it there doesn't defer work, it blanks the species out.
    ///
    /// A **republished** slug is the one case that waits. Its cached bytes go on
    /// being served until a Wi-Fi-and-power pass replaces them, so writing the
    /// new photographer and license in now would caption the old photo with the
    /// new photo's credit for however many days that takes. The incoming credit
    /// is parked in `pendingMetadata` and promoted by
    /// `markValidated(_:advancedHashes:)` alongside the hash, so the image and
    /// its attribution change over together. The single exception is a slug that
    /// has a hash but no credit at all — the pre-manifest upgrade path — where
    /// there is nothing to keep showing and waiting would leave it invisible.
    ///
    /// **Hashes** are a different matter and are only advanced for slugs the app
    /// has never seen. A changed slug's new hash is committed by the caller,
    /// through `markValidated(_:advancedHashes:)`, and only once the replacement
    /// bytes have actually landed — advancing it here would leave a failed refresh
    /// looking up to date, so nothing would ever come back for it.
    ///
    /// **Slugs the manifest no longer lists** are dropped outright. Keeping them
    /// meant a withdrawn photo's hash sat in local state forever with no metadata
    /// beside it, which pinned `needsMetadataBackfill` true and made every single
    /// foreground refetch the manifest.
    func apply(_ remote: PhotoManifest) -> ApplyResult {
        lock.lock(); defer { lock.unlock() }
        var result = ApplyResult()
        // What the app knew *before* this manifest, captured up front: the loop
        // below inserts every newly-published slug into `hashes`, so reading the
        // count afterwards would size the completeness check against a baseline
        // this same manifest had just grown.
        let knownBefore = hashes.count
        for (slug, entry) in remote.files {
            let known = hashes[slug]
            if known == nil {
                // Never seen: there are no bytes on hand for the credit to
                // disagree with, and recording the hash is what makes the photo
                // downloadable at all.
                hashes[slug] = entry.hash
                metadata[slug] = entry.info
                pendingMetadata.removeValue(forKey: slug)
                result.newSlugs.append(slug)
            } else if known != entry.hash {
                result.changedSlugs.append(slug)
                if metadata[slug] == nil {
                    // Nothing on record to keep showing. Withholding here would
                    // leave the slug unattributed — and therefore invisible (see
                    // `RemoteSpeciesImageStore.isAttributed`) and pinned into
                    // `needsMetadataBackfill` — which is strictly worse than the
                    // drift being avoided. This is the pre-manifest upgrade path,
                    // where a hash was seeded without a credit beside it.
                    metadata[slug] = entry.info
                } else {
                    // Republished. Hold the new credit until the new bytes land.
                    pendingMetadata[slug] = entry.info
                }
            } else {
                // Same bytes as ours, so any metadata change is a *correction* to
                // the photo already on disk — exactly the fix that has to
                // propagate on sight.
                metadata[slug] = entry.info
                pendingMetadata.removeValue(forKey: slug)
            }
        }
        // Snapshot first: removing from `hashes` while iterating its own keys
        // view works only by accident of copy-on-write.
        let withdrawn = hashes.keys.filter { remote.files[$0] == nil }
        if !withdrawn.isEmpty, isPlausiblyComplete(remote, knownBefore: knownBefore) {
            for slug in withdrawn {
                hashes.removeValue(forKey: slug)
                metadata.removeValue(forKey: slug)
                pendingMetadata.removeValue(forKey: slug)
                validatedAt.removeValue(forKey: slug)
            }
            result.removedSlugs = withdrawn
        }
        // Hashes still sitting here with no metadata beside them, whatever the
        // prune above did or didn't do. These are the leftovers of an install that
        // upgraded from a build which bundled `species_photos.json` for
        // attribution and seeded hashes from `photos_manifest.json` — the loop at
        // the top has just given metadata to every slug this manifest carries, so
        // anything still bare is a slug no published manifest describes.
        //
        // Dropped *outside* the `isPlausiblyComplete` guard on purpose, because
        // this is the one thing that makes `needsMetadataBackfill` terminate. That
        // property is what lets the foreground check skip its six-hour throttle,
        // and it stays true for as long as one bare hash survives — so a prune
        // vetoed by a short manifest (or by a set that has genuinely shrunk past
        // the floor) left the app refetching the manifest on *every* single
        // foreground, forever. The guard exists to stop a bad deploy deleting
        // cached image bytes; nothing here deletes bytes, and a slug with no
        // metadata can't be shown or downloaded anyway (see
        // `RemoteSpeciesImageStore.isAttributed`), so there is nothing for it to
        // protect. Deliberately not reported in `removedSlugs`, which is the
        // caller's cue to delete files.
        //
        // Snapshotted before the loop, for the same reason `withdrawn` is above:
        // removing from `hashes` while iterating its own keys view only works by
        // accident of copy-on-write.
        let unattributed = hashes.keys.filter { metadata[$0] == nil }
        for slug in unattributed {
            hashes.removeValue(forKey: slug)
            pendingMetadata.removeValue(forKey: slug)
            validatedAt.removeValue(forKey: slug)
        }
        persistLocked()
        return result
    }

    /// Whether an incoming manifest is whole enough to be treated as the full
    /// published set, and therefore to prune against.
    ///
    /// Pruning is the one thing `apply` does that *removes* knowledge, and it
    /// takes cached image bytes with it (see
    /// `RemoteSpeciesImageStore.discardWithdrawn`). A manifest that decodes
    /// cleanly but was published short — a build script that half-ran, a bad
    /// deploy — would otherwise wipe most of the photo set off the device and
    /// make the app re-download it, possibly over cellular. Photos do get
    /// withdrawn a few at a time; they don't get withdrawn by the hundred, so a
    /// manifest that has lost half the set is far more likely to be wrong than
    /// the local copy is.
    ///
    /// Guarded rather than trusted, and deliberately loose: the cost of skipping
    /// a legitimate prune is that a handful of stale slugs linger one more cycle.
    ///
    /// `knownBefore` is the slug count as it stood *before* `apply` folded this
    /// manifest in, which is the only baseline the comparison means anything
    /// against — by the time this runs, `hashes` already holds every slug the
    /// incoming manifest just introduced.
    private func isPlausiblyComplete(_ remote: PhotoManifest, knownBefore: Int) -> Bool {
        guard knownBefore >= Self.pruneFloor else { return true }
        return remote.files.count * 2 >= knownBefore
    }

    /// Below this many known slugs the completeness check doesn't apply — an
    /// install that knows about a dozen photos has no baseline worth defending.
    private static let pruneFloor = 50

    /// Marks the snapshot dirty and schedules a single write shortly, collapsing
    /// a burst of stamps into one encode. Call with `lock` held.
    private func persistSoonLocked() {
        guard !persistScheduled else { return }
        persistScheduled = true
        persistQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.persistScheduled = false
            self.persistLocked()
            self.lock.unlock()
        }
    }

    /// Writes the snapshot right now, bypassing the coalescing delay, and waits
    /// for it to land.
    ///
    /// `markDownloaded` batches its stamps behind a two-second timer and
    /// `persistLocked` hands even its immediate writes to the IO queue, so there
    /// is otherwise no moment at which a caller can say "the file reflects this."
    /// Tests reading the snapshot back need exactly that.
    ///
    /// Not part of the app's own flow, and shouldn't be — the whole point of the
    /// queue is that nothing blocks on the write.
    func persistNow() {
        lock.lock()
        persistLocked()
        lock.unlock()
        // Behind the write just queued. The queue is serial, so a `sync` barrier
        // can only run once it has.
        persistQueue.sync { }
    }

    /// Queues a write of the current state. Call with `lock` held.
    ///
    /// **Only the snapshot is taken under the lock; the encode and the disk write
    /// happen on the IO queue.** Copying three dictionaries is O(1) — they are
    /// value types, so this is a retain, not a walk — whereas encoding them is a
    /// JSON pass over every species the photo set has ever described, and the
    /// write is a full atomic file replace.
    ///
    /// Doing that work inside the lock blocked the main thread, which reads
    /// `info(forSlug:)` through `RemoteSpeciesImageStore.isAttributed` from view
    /// bodies and `.task`s on every photo the app draws. A manifest apply landing
    /// while a list scrolled would stall the scroll for the length of the encode.
    /// `LifeListStore.save()` has always snapshotted-then-encoded for exactly this
    /// reason; this is the same shape.
    private func persistLocked() {
        guard let url = snapshotURL else { return }
        // Three dictionary copies: retains, not walks. Everything that actually
        // costs anything — the `CodableInfo` remap, the encode, the write — is
        // deferred to the queue below, outside the lock.
        let hashes = self.hashes
        let metadata = self.metadata
        let pendingMetadata = self.pendingMetadata
        let validatedAt = self.validatedAt
        persistQueue.async {
            let snapshot = LocalSnapshot(
                hashes: hashes,
                metadata: metadata.mapValues(CodableInfo.init),
                pendingMetadata: pendingMetadata.mapValues(CodableInfo.init),
                validatedAt: validatedAt
            )
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// On-disk shape for the persisted local manifest state. `nonisolated` because
/// it is encoded on the store's own persist queue and decoded during `init`,
/// neither of which is the main actor.
private nonisolated struct LocalSnapshot: Codable {
    let hashes: [String: String]
    let metadata: [String: CodableInfo]
    /// Optional so snapshots written before deferred attribution existed still
    /// decode. A missing map means nothing is being held back, which is exactly
    /// what such an install's state means: it wrote every credit on sight.
    let pendingMetadata: [String: CodableInfo]?
    /// Optional so snapshots written before per-slug freshness existed still
    /// decode; a missing map means nothing has been validated, which correctly
    /// makes the whole cache stale on the first launch of this build.
    let validatedAt: [String: Double]?
}

/// Codable mirror of `SpeciesPhotoInfo` (which is decode-only from JSON) so the
/// metadata overlay can round-trip through the persisted snapshot.
private nonisolated struct CodableInfo: Codable {
    let credit: String?
    let license: String?
    let pageURL: String?
    let code: String?

    init(_ info: SpeciesPhotoInfo) {
        credit = info.credit
        license = info.license
        pageURL = info.pageURL
        code = info.code
    }

    var info: SpeciesPhotoInfo {
        SpeciesPhotoInfo(credit: credit, license: license, pageURL: pageURL, code: code)
    }
}

private nonisolated extension PhotoManifest.Entry {
    var info: SpeciesPhotoInfo {
        SpeciesPhotoInfo(credit: credit, license: license, pageURL: pageURL, code: code)
    }
}
