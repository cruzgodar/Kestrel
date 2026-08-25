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
/// It holds two things, both persisted so they survive relaunch:
///   • **hashes** — recorded as published manifests are applied. Diffing an
///     incoming manifest's hashes against these is how new (unseen slug) and
///     changed (different hash) photos are found.
///   • **metadata** — the credit/license/page/code for every species a fetched
///     manifest has told us about. This is the *only* source of photo metadata
///     in the app (`SpeciesPhotoMetadata` reads nothing else), so a slug missing
///     here has no photo as far as the rest of the app is concerned.
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
    /// slug → attribution, for every species a fetched manifest has described.
    /// Empty until the first successful fetch.
    private var metadata: [String: SpeciesPhotoInfo]
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
        var localValidatedAt: [String: Double] = [:]
        if let url = snapshotURL, let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder().decode(LocalSnapshot.self, from: data) {
            localHashes = snapshot.hashes
            localMetadata = snapshot.metadata.mapValues(\.info)
            localValidatedAt = snapshot.validatedAt ?? [:]
        }

        hashes = localHashes
        metadata = localMetadata
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
        }
        persistLocked()
    }

    /// Drops every validation stamp, so the next revalidation pass re-checks the
    /// whole cache. Used when the cached bytes are wiped out from under us.
    func clearValidationStamps() {
        lock.lock(); defer { lock.unlock() }
        guard !validatedAt.isEmpty else { return }
        validatedAt = [:]
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
    /// **Metadata is always recorded**, for every slug in the manifest, whatever
    /// else is or isn't committed. It costs a dictionary write, it is the app's
    /// only source of credit and license (`SpeciesPhotoMetadata` reads nothing
    /// else), and `RemoteSpeciesImageStore` refuses to show a photo without it —
    /// so withholding it doesn't defer work, it blanks the species out. Holding it
    /// back for changed slugs is what made every species whose photo had been
    /// re-published since the install's build show no photo at all until a
    /// Wi-Fi-and-power background pass happened to run.
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
        for (slug, entry) in remote.files {
            metadata[slug] = entry.info
            let known = hashes[slug]
            if known == nil {
                hashes[slug] = entry.hash
                result.newSlugs.append(slug)
            } else if known != entry.hash {
                result.changedSlugs.append(slug)
            }
        }
        // Snapshot first: removing from `hashes` while iterating its own keys
        // view works only by accident of copy-on-write.
        let withdrawn = hashes.keys.filter { remote.files[$0] == nil }
        if !withdrawn.isEmpty, isPlausiblyComplete(remote) {
            for slug in withdrawn {
                hashes.removeValue(forKey: slug)
                metadata.removeValue(forKey: slug)
                validatedAt.removeValue(forKey: slug)
            }
            result.removedSlugs = withdrawn
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
    private func isPlausiblyComplete(_ remote: PhotoManifest) -> Bool {
        guard hashes.count >= Self.pruneFloor else { return true }
        return remote.files.count * 2 >= hashes.count
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

    /// Writes the snapshot right now, bypassing the coalescing delay.
    ///
    /// `markDownloaded` batches its stamps behind a two-second timer, so there is
    /// otherwise no moment at which a caller can say "the file reflects this."
    /// Tests reading the snapshot back need exactly that.
    func persistNow() {
        lock.lock(); defer { lock.unlock() }
        persistLocked()
    }

    private func persistLocked() {
        guard let url = snapshotURL else { return }
        let snapshot = LocalSnapshot(
            hashes: hashes,
            metadata: metadata.mapValues(CodableInfo.init),
            validatedAt: validatedAt
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// On-disk shape for the persisted local manifest state. `nonisolated` because
/// it is encoded on the store's own persist queue and decoded during `init`,
/// neither of which is the main actor.
private nonisolated struct LocalSnapshot: Codable {
    let hashes: [String: String]
    let metadata: [String: CodableInfo]
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
