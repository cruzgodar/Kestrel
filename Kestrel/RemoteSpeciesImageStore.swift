import ImageIO
import UIKit

/// Persistent store for the CC-licensed species photos, served through the free
/// jsDelivr CDN from a GitHub photo repo (see `assetBaseURL`).
///
/// Three network tiers, each a pre-rendered size folder, mirrored across
/// memory + disk caches:
///   • **thumbnail** (300 px tall) — `{slug}_thumb.jpg`, fetched from the CDN's
///     `thumb/` folder. Lists, map pins, cluster grids, the Identify hero's
///     first paint, and the watch's "now hearing" screen all use it.
///   • **medium** (900 px tall) — `{slug}.jpg`, from the `hero/` folder and the
///     offline source of truth. The Identify hero upgrades to it, and the
///     full-screen viewer opens on it.
///   • **full** (cropped original, longest edge ≤ 2700 px) — from the `full/`
///     folder, memory-only and never persisted. Fetched only on demand when a
///     card opens full-screen, so a pinch-zoom is crisp.
///
/// Downloads are ordered and coalesced by `ImageDownloadQueue`: a wake (app
/// launch or session start) prefetches nearby thumbnails, then life-list
/// thumbnails, then nearby medium, then life-list medium, while on-demand loads
/// jump the queue. The
/// thumbnail is fetched from the server rather than downsampled locally, so the
/// watch and the small photo contexts get their bytes with no decode/encode on
/// the phone.
///
/// `@unchecked Sendable` + nonisolated: callers hit it from view bodies,
/// background prefetch tasks, the watch bridge, and the full-screen viewer.
nonisolated final class RemoteSpeciesImageStore: @unchecked Sendable {
    /// Built once, then wired to its download queue before the instance is
    /// handed out (the queue calls back into `downloadAndStore`, so it can't be
    /// constructed in the initializer's property phase).
    static let shared: RemoteSpeciesImageStore = {
        let store = RemoteSpeciesImageStore()
        store.queue = ImageDownloadQueue { slug, name, size in
            await store.downloadAndStore(slug: slug, name: name, size: size)
        }
        return store
    }()

    private let memory = NSCache<NSString, UIImage>()
    /// In-memory cache of the small thumbnails (see the thumbnail tier note).
    /// Separate from `memory` so a thumbnail and its medium image can both be
    /// resident without evicting each other.
    private let thumbnailMemory = NSCache<NSString, UIImage>()
    /// In-memory-only cache of the **true full-resolution** photos (the cropped
    /// original from the `full/` folder). The full-screen viewer fetches one in the
    /// background when a card opens and swaps it in for the medium-res image so a
    /// pinch-zoom is crisp. Bounded by total decoded byte cost (see
    /// `fullResImageMemory.totalCostLimit`) rather than count, and never persisted —
    /// the medium 900px disk copy stays the protected/offline source of truth.
    private let fullResImageMemory = NSCache<NSString, UIImage>()
    private let dir: URL
    private let session: URLSession

    /// Set once by `shared` before the instance escapes; an ordered,
    /// concurrency-bounded, coalescing download pipeline.
    private var queue: ImageDownloadQueue!

    /// Ceiling for cached "other" images — anything neither on the life list
    /// nor in the current nearby list — enforced only while the user's "Limit
    /// Cached Images" setting is on.
    static let otherImagesLimitBytes: Int64 = 50 * 1024 * 1024

    /// In-memory budget (decoded bytes) for the full-resolution viewer tier.
    /// `NSCache` evicts the least-recently-used full-res images once the resident
    /// set's total cost exceeds this.
    static let fullResMemoryLimitBytes = 50 * 1024 * 1024

    /// Base URL for the CC-licensed species-photo set, served through the free
    /// jsDelivr CDN from the GitHub photo repo.
    ///
    /// **Un-versioned, deliberately**: every URL points at the repo's default
    /// branch, and nothing — not this constant, not `assetURL` — pins a tag. The
    /// photo set grows and is corrected in place, and the app notices by diffing
    /// `manifest.json` at this same base (see `checkForPhotoUpdates`), so a
    /// re-publish needs no app change at all. Each size lives under its own
    /// folder (`thumb/`, `hero/`, `full/`), every file named `<slug>.jpg`.
    static let assetBaseURL = "https://cdn.jsdelivr.net/gh/cruzgodar/kestrel-species-photos"

    /// Path component of the on-demand full-resolution tier — the cropped
    /// original (longest edge capped at 2700 px by the build script), used only
    /// when a card opens full-screen for a crisp pinch-zoom.
    private static let fullResFolder = "full"

    /// Guards `protectedSlugs` + `limitOtherImages`, which are read/written from
    /// the main actor (settings, launch) and background prefetch/eviction.
    private let protectedLock = NSLock()
    /// Slugs that must never be evicted: life-list + current nearby species.
    /// Kept current as the life list and region filter change.
    private var protectedSlugs = Set<String>()
    /// When on, caching a new non-protected image prunes the oldest
    /// non-protected images past the cap. Enabled at launch.
    private var limitOtherImages = false

    private init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("SpeciesPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.countLimit = 512
        // Thumbnails are tiny, so we can keep far more of them resident — enough
        // to cover a full life list without churn.
        thumbnailMemory.countLimit = 2048
        // Full-res images are large; bound the tier by total decoded bytes so it
        // never holds more than ~50 MB regardless of how many cards are opened.
        fullResImageMemory.totalCostLimit = Self.fullResMemoryLimitBytes

        let cfg = URLSessionConfiguration.default
        // We manage our own permanent disk cache, so don't double-store in
        // URLSession's purgeable URLCache.
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
    }

    private func fileURL(forSlug slug: String) -> URL {
        dir.appendingPathComponent(slug + ".jpg")
    }

    private func thumbFileURL(forSlug slug: String) -> URL {
        dir.appendingPathComponent(slug + "_thumb.jpg")
    }

    /// Local disk path for a cached size (thumbnail or medium). The full-res
    /// tier is memory-only, so it has none.
    private func fileURL(forSlug slug: String, size: ImageSize) -> URL {
        switch size {
        case .thumb: return thumbFileURL(forSlug: slug)
        case .medium: return fileURL(forSlug: slug)
        }
    }

    // MARK: - Reads

    /// Whether the photo set currently describes this species — i.e. a fetched
    /// manifest has supplied its credit and license (see `SpeciesPhotoMetadata`,
    /// which has no bundled fallback).
    ///
    /// Every read path checks this *before* touching memory or disk, not merely
    /// before downloading. Attribution now arrives only with the manifest, so a
    /// species whose metadata we don't have must not render a photo even when
    /// its bytes are still cached from an earlier build: a CC BY image shown
    /// without its credit line is a license violation, not a cosmetic gap. The
    /// block lifts on its own the moment a manifest fetch lands.
    private func isAttributed(_ scientificName: String) -> Bool {
        SpeciesPhotoMetadata.shared.info(for: scientificName) != nil
    }

    /// Synchronous in-memory lookup only (no disk, no network). Safe + instant
    /// on the main actor — used to avoid a placeholder flash for photos already
    /// decoded this session.
    func memoryImage(for scientificName: String) -> UIImage? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty, isAttributed(scientificName) else { return nil }
        return memory.object(forKey: slug as NSString)
    }

    /// Synchronous in-memory thumbnail lookup only (no disk, no network). The
    /// thumbnail counterpart of `memoryImage(for:)` — used by small photo contexts
    /// to render an already-decoded thumbnail with no placeholder flash.
    func memoryThumbnail(for scientificName: String) -> UIImage? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty, isAttributed(scientificName) else { return nil }
        return thumbnailMemory.object(forKey: slug as NSString)
    }

    /// Synchronous in-memory full-resolution lookup only (no network). Lets the
    /// viewer show an already-fetched full-res image immediately when re-opening a
    /// card, with no medium→full swap flash.
    func memoryFullResolutionImage(for scientificName: String) -> UIImage? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty, isAttributed(scientificName) else { return nil }
        return fullResImageMemory.object(forKey: slug as NSString)
    }

    /// Returns the medium photo, loading from memory → disk → network as needed,
    /// and promoting the result up the tiers. Returns nil when there's no
    /// metadata URL for the species or the download fails. On a network miss the
    /// download jumps the prefetch queue. Call off the main actor.
    func image(for scientificName: String) async -> UIImage? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty, isAttributed(scientificName) else { return nil }
        let key = slug as NSString

        if let cached = memory.object(forKey: key) { return cached }

        // Disk.
        if let data = try? Data(contentsOf: fileURL(forSlug: slug)),
           let img = UIImage(data: data) {
            let prepared = img.preparingForDisplay() ?? img
            memory.setObject(prepared, forKey: key)
            return prepared
        }

        // Network (coalesced + queue-jumping).
        guard let data = await queue.fetch(slug: slug, name: scientificName, size: .medium),
              let img = UIImage(data: data) else {
            return nil
        }
        let prepared = img.preparingForDisplay() ?? img
        memory.setObject(prepared, forKey: key)
        return prepared
    }

    /// Returns the **true full-resolution** photo for the viewer, loading from the
    /// capped in-memory tier or, on a miss, downloading the largest CDN size and
    /// caching it (in memory only). Returns nil when there's no metadata URL, the
    /// URL can't be upgraded to the full size, or the download fails. Call off the
    /// main actor. The viewer shows the medium image first and swaps this in when
    /// it resolves.
    func fullResolutionImage(for scientificName: String) async -> UIImage? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty, isAttributed(scientificName) else { return nil }
        let key = slug as NSString

        if let cached = fullResImageMemory.object(forKey: key) { return cached }

        guard let url = Self.assetURL(slug: slug, folder: Self.fullResFolder),
              let data = await download(url),
              let img = UIImage(data: data) else {
            return nil
        }
        let prepared = img.preparingForDisplay() ?? img
        fullResImageMemory.setObject(prepared, forKey: key, cost: prepared.decodedByteCost)
        return prepared
    }

    /// Returns the small (300 px tall) thumbnail, loading from memory → disk →
    /// the CDN's `thumb` folder as needed and promoting up the tiers. Far cheaper to decode and hold
    /// than the medium image — use it for lists, map pins, cluster grids, and the
    /// hero's first paint. On a network miss the download jumps the prefetch
    /// queue. Returns nil when there's no metadata URL or loading fails. Call off
    /// the main actor.
    func thumbnailImage(for scientificName: String) async -> UIImage? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty, isAttributed(scientificName) else { return nil }
        let key = slug as NSString

        if let cached = thumbnailMemory.object(forKey: key) { return cached }

        // Disk thumbnail.
        if let data = try? Data(contentsOf: thumbFileURL(forSlug: slug)),
           let img = UIImage(data: data) {
            let prepared = img.preparingForDisplay() ?? img
            thumbnailMemory.setObject(prepared, forKey: key)
            return prepared
        }

        // Network (coalesced + queue-jumping).
        guard let data = await queue.fetch(slug: slug, name: scientificName, size: .thumb),
              let img = UIImage(data: data) else {
            return nil
        }
        let prepared = img.preparingForDisplay() ?? img
        thumbnailMemory.setObject(prepared, forKey: key)
        return prepared
    }

    /// Raw JPEG bytes of the 300 px-tall thumbnail — disk if present, otherwise
    /// fetched from the CDN (jumping the prefetch queue). Handed straight to the
    /// watch, which caches and decodes them itself, so the phone never decodes or
    /// re-encodes. Call off the main actor.
    func thumbnailData(for scientificName: String) async -> Data? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty, isAttributed(scientificName) else { return nil }
        if let data = try? Data(contentsOf: thumbFileURL(forSlug: slug)) { return data }
        return await queue.fetch(slug: slug, name: scientificName, size: .thumb)
    }

    /// Builds the jsDelivr URL for one species photo at a given size folder
    /// (`thumb`/`hero`/`full`) from its slug: `{base}/{folder}/{slug}.jpg`, served
    /// straight off the photo repo's default branch. No version pinning — the set
    /// grows in place, and the app finds new/changed photos by diffing the
    /// manifest (see `checkForPhotoUpdates`). A *newly added* photo is at a URL
    /// jsDelivr has never cached, so it appears immediately; a *changed* photo at
    /// an existing URL can be served stale from the CDN edge for up to jsDelivr's
    /// branch-cache window unless the publish purges it (see the README).
    static func assetURL(slug: String, folder: String) -> URL? {
        URL(string: "\(assetBaseURL)/\(folder)/\(slug).jpg")
    }

    /// URL of the published photo manifest on the repo's default branch — the
    /// growable list of every species that has a photo, with per-species content
    /// hashes and metadata. `checkForPhotoUpdates` fetches and diffs it.
    static func manifestURL() -> URL? {
        URL(string: "\(assetBaseURL)/manifest.json")
    }

    /// Downloads (if not already on disk) and persists the bytes for one
    /// prefetchable size, returning them. This is the single primitive the
    /// download queue drives; it does no in-memory caching (bulk prefetch
    /// shouldn't decode thousands of images), leaving that to the on-demand tier
    /// methods. Medium downloads count toward the "other images" cap; thumbnails
    /// don't. Safe to call concurrently.
    private func downloadAndStore(slug: String, name: String, size: ImageSize) async -> Data? {
        guard isAttributed(name) else { return nil }
        let dest = fileURL(forSlug: slug, size: size)
        if let data = try? Data(contentsOf: dest) { return data }

        guard let url = Self.assetURL(slug: slug, folder: size.folder),
              let data = await download(url),
              UIImage(data: data) != nil else {
            return nil
        }
        try? data.write(to: dest, options: .atomic)
        // Bytes just off the CDN are current by definition, so start the slug's
        // freshness window now (see `revalidateStaleImages`).
        PhotoManifestStore.shared.markDownloaded(slug)
        if size == .medium { didCacheImage(slug: slug) }
        return data
    }

    /// Ensures the medium species photo is on disk (downloading if needed) and
    /// returns its local file URL, or nil if unavailable. Used by the
    /// notification attachment, which needs a real file to hand to the system.
    /// Call off the main actor.
    func localFileURL(for scientificName: String) async -> URL? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty, isAttributed(scientificName) else { return nil }
        let dest = fileURL(forSlug: slug)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        _ = await queue.fetch(slug: slug, name: scientificName, size: .medium)
        return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
    }

    // MARK: - Prefetch

    /// Warms the caches on a wake (app launch or session start). Enqueues four
    /// tiers, drained strictly in order: every nearby species' `thumb` (300 px
    /// tall) first, then the rest of the life list's, then nearby `hero` (900 px
    /// tall), then the rest of the life list's. The full-resolution tier is never
    /// prefetched. Already-on-disk sizes and duplicates are filtered out, so this
    /// is cheap to call on every launch and whenever the region list changes.
    ///
    /// `nearby` may already include life-list species (that's expected — nearby
    /// lifers get their thumbnails first); `lifeList` is fetched for the species
    /// *not* already covered by `nearby` so nothing is queued twice.
    func prefetchWake(lifeList: [String], nearby: [String]) {
        Task { await enqueuePrefetch(lifeList: lifeList, nearby: nearby) }
    }

    /// Same as `prefetchWake` but suspends until the queue has fully drained.
    /// Used by the background prefetch task, which must keep its runtime
    /// assertion open until the downloads actually finish (see
    /// `ImageDownloadQueue.waitUntilIdle`). Call off the main actor.
    func prefetchWakeAwaitingDrain(lifeList: [String], nearby: [String]) async {
        await enqueuePrefetch(lifeList: lifeList, nearby: nearby)
        await queue.waitUntilIdle()
    }

    /// Resets and repopulates the four prefetch tiers. Shared by the fire-and-
    /// forget `prefetchWake` and the drain-awaiting background variant.
    private func enqueuePrefetch(lifeList: [String], nearby: [String]) async {
        let nearbySlugs = Set(nearby.map { SpeciesImage.slug(for: $0) })
        let lifeListOnly = lifeList.filter { !nearbySlugs.contains(SpeciesImage.slug(for: $0)) }

        // One call, not a reset plus four enqueues: two prefetch waves can be in
        // flight at once (the background refresh task and the foreground photo
        // check both start one), and interleaving their resets left a wave
        // watching a queue the other had emptied. See `replacePrefetch`.
        await queue.replacePrefetch([
            (.nearbyThumb, requests(nearby, .thumb)),
            (.lifeListThumb, requests(lifeListOnly, .thumb)),
            (.nearbyMedium, requests(nearby, .medium)),
            (.lifeListMedium, requests(lifeListOnly, .medium)),
        ])
    }

    /// Builds the download requests for a group at one size: de-duplicated by
    /// slug, only species that have photo metadata, and only those not already on
    /// disk at that size.
    private func requests(_ scientificNames: [String], _ size: ImageSize) -> [ImageDownloadQueue.Request] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [ImageDownloadQueue.Request] = []
        for name in scientificNames {
            let slug = SpeciesImage.slug(for: name)
            guard !slug.isEmpty, seen.insert(slug).inserted, isAttributed(name),
                  !fm.fileExists(atPath: fileURL(forSlug: slug, size: size).path) else { continue }
            out.append(ImageDownloadQueue.Request(slug: slug, name: name, size: size))
        }
        return out
    }

    private func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else {
            return nil
        }
        return data
    }

    /// Life-list + currently-cached region species: the set prefetched at
    /// launch. Deduplicated, life list first.
    static func launchTargets(lifeList: [String]) -> [String] {
        var names = lifeList
        names.append(contentsOf: nearbyNames())
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// Scientific names of the species in the currently-cached nearby-region
    /// filter, or empty when no location filter has been computed yet.
    static func nearbyNames() -> [String] {
        guard let allowed = SpeciesRangeFilter.cachedAllowedIndices() else { return [] }
        let all = SpeciesCatalog.shared.all
        return allowed.compactMap { all.indices.contains($0) ? all[$0].scientificName : nil }
    }

    // MARK: - Photo updates (growable manifest)

    /// UserDefaults key for the last successful manifest fetch, used to throttle
    /// the foreground discovery check.
    private static let lastManifestCheckKey = "photoManifestLastCheck"

    struct PhotoUpdateResult: Sendable {
        /// Species the app had never heard of before this manifest.
        var newCount = 0
        /// Species whose published hash has moved on since the app last recorded
        /// it. Reported on **every** pass, whatever `includeChanged` says —
        /// finding them is the diff's job and costs nothing; re-pulling their
        /// bytes is what the cellular path defers. This used to be incremented
        /// only inside the `includeChanged` branch, so the foreground path
        /// reported a flat zero while its own doc comment said changed species
        /// "are reported and left alone."
        var changedCount = 0
        /// Of those, how many actually had their bytes re-pulled. Always 0 on a
        /// pass that didn't ask for changed photos.
        var refreshedCount = 0
        /// The manifest this pass fetched, so a caller running a second pass in
        /// the same breath can hand it back instead of downloading the same file
        /// again — see `revalidateStaleImages(using:)`. Nil when the fetch failed.
        var manifest: PhotoManifest?
    }

    /// Whether enough time has passed since the last manifest fetch to do another
    /// foreground discovery check. Background tasks ignore this (the OS already
    /// rate-limits them); only the on-foreground path throttles so opening the app
    /// repeatedly doesn't refetch every time.
    func manifestCheckDue(minInterval: TimeInterval) -> Bool {
        let last = UserDefaults.standard.double(forKey: Self.lastManifestCheckKey)
        return Date().timeIntervalSince1970 - last >= minInterval
    }

    /// Fetches the published manifest and reconciles it against what the app
    /// knows — the single entry point for discovering photos added or changed on
    /// the CDN, no app update required. Call off the main actor.
    ///
    /// Every fetch records the manifest's metadata in full, so credits and
    /// licenses are always current and no species is left unattributed (and
    /// therefore invisible — see `isAttributed`). **New** species also have their
    /// hash recorded immediately, which is what makes them downloadable; the
    /// caller then prefetches whichever of them are nearby / on the life list.
    ///
    /// **Changed** species are only re-pulled when `includeChanged` is set (the
    /// high-power, Wi-Fi + power pass). On the cellular / foreground path they are
    /// reported and left alone, so metered data isn't spent re-fetching images the
    /// user already has, and a later high-power pass still sees them as changed.
    ///
    /// The exception is a changed species the app holds **no bytes** for, which is
    /// settled on every pass — see `settleUncachedChanges`, which is why that call
    /// sits above the `includeChanged` guard rather than inside the refresh loop.
    ///
    /// A refresh is all-or-nothing and non-destructive: the replacement bytes are
    /// downloaded and only then written over the old ones, and the slug's hash
    /// advances only once they have. A failure leaves the species with the photo
    /// it had and still marked as changed, rather than with no photo and a hash
    /// saying it is up to date — which is what dropping the bytes up front and
    /// advancing the hash in the same breath used to produce.
    ///
    /// Returns how many species were newly discovered / refreshed.
    @discardableResult
    func checkForPhotoUpdates(includeChanged: Bool) async -> PhotoUpdateResult {
        guard let url = Self.manifestURL(),
              let data = await download(url),
              let remote = PhotoManifest(data: data) else {
            return PhotoUpdateResult()
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastManifestCheckKey)

        let applied = PhotoManifestStore.shared.apply(remote)
        discardWithdrawn(applied.removedSlugs)
        var result = PhotoUpdateResult(
            newCount: applied.newSlugs.count,
            changedCount: applied.changedSlugs.count,
            manifest: remote
        )

        // Before the guard below, and on every pass: a changed species with
        // nothing cached costs no network to settle, and leaving it parked is
        // actively wrong. See `settleUncachedChanges`.
        let settled = settleUncachedChanges(applied.changedSlugs, in: remote)

        guard includeChanged else { return result }

        var advanced: [String: String] = [:]
        for slug in applied.changedSlugs where !settled.contains(slug) {
            guard let published = remote.files[slug]?.hash else { continue }
            if await refreshCachedSizes(slug: slug) {
                advanced[slug] = published
                result.refreshedCount += 1
            }
        }
        PhotoManifestStore.shared.markValidated([], advancedHashes: advanced)
        return result
    }

    /// Records the published hash — and with it the held-back credit — for every
    /// changed slug the app holds no bytes for. Returns the slugs it settled, so
    /// a caller's refresh loop can skip them.
    ///
    /// **Runs on every pass, cellular included**, because it downloads nothing:
    /// there are no cached bytes for the incoming credit to mis-describe, so the
    /// reason a republished photo's attribution is normally held back (see
    /// `PhotoManifestStore.pendingMetadata`) simply doesn't apply.
    ///
    /// Leaving these parked is not the neutral choice it looks like. Every asset
    /// URL is unversioned (see `assetBaseURL`), so the *next* load of one of these
    /// slugs fetches the **republished** image — and `downloadAndStore` then
    /// stamps it fresh for a full `cacheFreshness` window, so the revalidation
    /// pass won't look at it for a day. With the credit still parked, the app
    /// spends that day showing photo v2 under photo v1's photographer and license.
    ///
    /// That next load is not hypothetical: `BackgroundRefreshCoordinator`'s
    /// prefetch task runs `checkForPhotoUpdates(includeChanged: false)` and then
    /// immediately prefetches the life list and the nearby region, which downloads
    /// exactly the changed slugs that had no bytes. And it is the same
    /// mis-crediting `PhotoManifestStore.clearValidationStamps` promotes to avoid
    /// — reached one slug at a time rather than all at once.
    @discardableResult
    private func settleUncachedChanges(
        _ changedSlugs: [String],
        in remote: PhotoManifest
    ) -> Set<String> {
        guard !changedSlugs.isEmpty else { return [] }
        // Only the changed slugs' hashes, not the whole manifest's: this runs on
        // every pass and the manifest carries an entry per photographed species.
        var publishedHashes: [String: String] = [:]
        publishedHashes.reserveCapacity(changedSlugs.count)
        for slug in changedSlugs {
            publishedHashes[slug] = remote.files[slug]?.hash
        }
        let advanced = Self.uncachedChangeAdvances(
            changedSlugs: changedSlugs,
            publishedHashes: publishedHashes,
            hasCachedBytes: { self.hasCachedBytes(slug: $0) }
        )
        guard !advanced.isEmpty else { return [] }
        PhotoManifestStore.shared.markValidated([], advancedHashes: advanced)
        return Set(advanced.keys)
    }

    /// The rule behind `settleUncachedChanges`, as a pure function of the two
    /// facts it turns on: which slugs changed, and which of those the app holds
    /// bytes for.
    ///
    /// Extracted so the rule is pinned by a test rather than by a comment — the
    /// same shape `LifeListStore.recordsHandover` and
    /// `RecordingManager.shouldPromptForWatchWorkout` take, and for the same
    /// reason: the store itself is a singleton over the app's real container and
    /// the real CDN, so this is the only part of the decision a test can reach.
    nonisolated static func uncachedChangeAdvances(
        changedSlugs: [String],
        publishedHashes: [String: String],
        hasCachedBytes: (String) -> Bool
    ) -> [String: String] {
        var advanced: [String: String] = [:]
        for slug in changedSlugs where !hasCachedBytes(slug) {
            // A slug the manifest no longer lists isn't "changed" any more, it is
            // withdrawn — `apply` has already dropped it and `discardWithdrawn`
            // its bytes, so there is no hash to advance to.
            guard let published = publishedHashes[slug] else { continue }
            advanced[slug] = published
        }
        return advanced
    }

    /// Whether either persisted size of a slug is on disk.
    private func hasCachedBytes(slug: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: thumbFileURL(forSlug: slug).path)
            || fm.fileExists(atPath: fileURL(forSlug: slug).path)
    }

    /// Deletes the cached bytes of species the published manifest has stopped
    /// listing. Their attribution went with the manifest entry, so they can no
    /// longer be shown (see `isAttributed`) and the files are dead weight — and
    /// leaving them would keep `cachedSlugs()` handing the revalidation pass slugs
    /// it can never confirm.
    private func discardWithdrawn(_ slugs: [String]) {
        guard !slugs.isEmpty else { return }
        for slug in slugs { invalidateDiskImages(slug: slug) }
        Log.info("Photo set: \(slugs.count) species withdrawn upstream, cached bytes dropped")
    }

    /// Drops a species' cached bytes across the persisted tiers and their
    /// in-memory caches. Used by `discardWithdrawn` when a photo leaves the
    /// published set — the one case where deleting is right, because without the
    /// manifest entry there is no license to show the bytes under.
    private func invalidateDiskImages(slug: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: thumbFileURL(forSlug: slug))
        try? fm.removeItem(at: fileURL(forSlug: slug))
        let key = slug as NSString
        memory.removeObject(forKey: key)
        thumbnailMemory.removeObject(forKey: key)
        fullResImageMemory.removeObject(forKey: key)
    }

    // MARK: - Cache freshness

    /// How long a cached image is trusted before the app re-checks it against the
    /// published manifest. Expiry does **not** mean deletion: a stale image keeps
    /// being served (and stays on disk) until a replacement has actually been
    /// downloaded, so going offline never blanks out photos the user already has.
    static let cacheFreshness: TimeInterval = 24 * 60 * 60

    /// Floor on how often the revalidation pass may hit the network, so a slug
    /// that can never be validated — its photo was pulled from the published set,
    /// say — costs at most one small manifest fetch an hour rather than one per
    /// foreground.
    private static let revalidationRetryInterval: TimeInterval = 60 * 60

    /// UserDefaults key for the last revalidation attempt that reached the network.
    private static let lastRevalidationKey = "photoCacheLastRevalidation"

    struct RevalidationResult: Sendable {
        /// Confirmed current by hash comparison — nothing was downloaded.
        var confirmed = 0
        /// Re-downloaded because the published hash had moved on.
        var refreshed = 0
        /// Left stale: the manifest or an image download failed. Their cached
        /// bytes are untouched and retried later.
        var failed = 0
        /// Changed upstream but left alone because this pass wasn't allowed to
        /// spend the bytes — see `revalidateStaleImages(includeChanged:using:)`.
        /// Not a failure and not a confirmation: they stay stale on purpose, so
        /// the next Wi-Fi-and-power pass picks them up.
        var deferred = 0
        /// Dropped because the published set no longer carries them. Not a
        /// failure — nothing will ever confirm them, so they stop being counted
        /// against the cache.
        var withdrawn = 0
        /// Species this pass learned about for the first time. A revalidation
        /// fetches the same manifest the discovery check does, so it can be the
        /// one that first sees a newly published photo — and once it has
        /// recorded that slug's hash, discovery will never report it as new
        /// again. Surfacing it here is what keeps those species from missing
        /// their prefetch and trickling in one lazy load at a time.
        var discoveredSlugs: [String] = []

        /// `discoveredSlugs` counts: a pass that only turned up newly published
        /// species did real work, and a caller that treats it as empty both
        /// swallows the log line and — worse — skips the prefetch those species
        /// depend on (see `KestrelApp.refreshPhotosOnForeground`).
        var isEmpty: Bool {
            confirmed == 0 && refreshed == 0 && failed == 0 && withdrawn == 0
                && deferred == 0 && discoveredSlugs.isEmpty
        }
    }

    /// What a revalidation pass should do with one stale cached slug.
    nonisolated enum StaleOutcome: Hashable {
        /// The published manifest no longer lists it — `apply` has already
        /// dropped its record and `discardWithdrawn` its bytes.
        case withdrawn
        /// Byte-identical to what's published; stamp it fresh, download nothing.
        case confirmed
        /// Changed upstream and this pass may spend the bytes: re-pull it.
        case refresh
        /// Changed upstream, but this pass is metered. Left stale on purpose.
        case deferred
    }

    /// The rule behind `revalidateStaleImages`' loop, as a pure function of the
    /// three facts it turns on.
    ///
    /// Extracted so the rule is pinned by a test rather than by a comment — the
    /// same shape `uncachedChangeAdvances` and `LifeListStore.recordsHandover`
    /// take, and for the same reason: the store is a singleton over the app's real
    /// container and the real CDN, so this is the only part of the decision a test
    /// can reach.
    ///
    /// `.deferred` is the case that was missing. Without it every foreground pass
    /// re-pulled both persisted sizes of every changed slug on whatever connection
    /// the phone happened to be on, which is exactly the work
    /// `checkForPhotoUpdates(includeChanged: false)` exists to keep off cellular.
    /// A deferred slug is deliberately *not* confirmed, so it stays stale and the
    /// Wi-Fi-and-power pass still finds it.
    nonisolated static func staleOutcome(
        publishedHash: String?,
        recordedHash: String?,
        includeChanged: Bool
    ) -> StaleOutcome {
        guard let publishedHash else { return .withdrawn }
        guard recordedHash != publishedHash else { return .confirmed }
        return includeChanged ? .refresh : .deferred
    }

    /// Re-checks every cached image whose freshness window has lapsed.
    ///
    /// The check is a *hash* comparison, not a download: the published manifest
    /// carries a content hash per slug, so a cached image that hasn't changed
    /// upstream costs one shared manifest fetch for the whole cache and no image
    /// bytes at all. Only slugs whose hash actually moved are re-pulled.
    ///
    /// Every failure path is non-destructive. If the manifest can't be fetched, or
    /// a replacement image can't be downloaded, or only some of a slug's sizes
    /// arrive, the existing files stay exactly where they are and the slug keeps
    /// its old recorded hash — so it's still stale and the next pass tries again.
    /// Nothing is ever deleted on a schedule; bytes are only ever replaced by
    /// bytes. Call off the main actor.
    ///
    /// `prefetched` lets a caller that has *just* fetched the manifest hand it
    /// over rather than making this download the identical file a second time —
    /// which the high-power background pass did on every run, once through
    /// `checkForPhotoUpdates` and once here.
    ///
    /// **`includeChanged` is the same gate `checkForPhotoUpdates` carries, and it
    /// has to be.** The hash comparison is free, but a slug whose hash *moved*
    /// costs a re-download of both its persisted sizes — and this runs on every
    /// foreground, on whatever connection the phone happens to be on.
    /// `checkForPhotoUpdates(includeChanged: false)` exists precisely to keep
    /// that off cellular and hand it to the Wi-Fi-and-power `BGProcessingTask`;
    /// this pass fetched the same manifest, found the same changed slugs, and
    /// re-pulled them anyway, which quietly undid the deferral for every one of
    /// them that happened to be cached. Deferred slugs are left stale (they are
    /// not stamped `confirmed`), so the high-power pass still sees them.
    @discardableResult
    func revalidateStaleImages(
        includeChanged: Bool,
        using prefetched: PhotoManifest? = nil
    ) async -> RevalidationResult {
        let cached = cachedSlugs()
        guard !cached.isEmpty else { return RevalidationResult() }
        let stale = PhotoManifestStore.shared.staleSlugs(cached, maxAge: Self.cacheFreshness)
        guard !stale.isEmpty else { return RevalidationResult() }

        let now = Date().timeIntervalSince1970
        let lastAttempt = UserDefaults.standard.double(forKey: Self.lastRevalidationKey)
        guard now - lastAttempt >= Self.revalidationRetryInterval else {
            return RevalidationResult()
        }

        // A handed-over manifest skips the fetch but nothing else: the retry
        // floor above still applies, because the images this pass may re-pull
        // are the expensive part and they are unaffected by who fetched the
        // manifest.
        let fetched: PhotoManifest?
        if let prefetched {
            fetched = prefetched
        } else if let url = Self.manifestURL(), let data = await download(url) {
            fetched = PhotoManifest(data: data)
        } else {
            fetched = nil
        }
        guard let remote = fetched else {
            // Offline, or the CDN is unreachable. Everything stays cached and
            // stale; the retry floor keeps this from hammering the network.
            UserDefaults.standard.set(now, forKey: Self.lastRevalidationKey)
            return RevalidationResult(failed: stale.count)
        }
        UserDefaults.standard.set(now, forKey: Self.lastRevalidationKey)
        UserDefaults.standard.set(now, forKey: Self.lastManifestCheckKey)
        // Same bookkeeping the discovery check does — newly published species get
        // their hash + attribution recorded, and credit fixes propagate.
        let applied = PhotoManifestStore.shared.apply(remote)
        discardWithdrawn(applied.removedSlugs)
        // Including the settling of changed species with nothing cached. This
        // pass fetches the same manifest the discovery check does, so it parks
        // the same held-back credits and has to release the same ones — a slug
        // with no bytes is never in `stale` (which comes from `cachedSlugs()`),
        // so the loop below would otherwise never reach it. See
        // `settleUncachedChanges`.
        settleUncachedChanges(applied.changedSlugs, in: remote)

        var result = RevalidationResult()
        result.discoveredSlugs = applied.newSlugs
        var confirmed: [String] = []
        var advanced: [String: String] = [:]
        for slug in stale {
            let published = remote.files[slug]?.hash
            switch Self.staleOutcome(
                publishedHash: published,
                recordedHash: PhotoManifestStore.shared.recordedHash(forSlug: slug),
                includeChanged: includeChanged
            ) {
            case .withdrawn:
                // `apply` has already dropped its hash, metadata and stamp, and
                // `discardWithdrawn` its bytes. Nothing left to revalidate, and
                // it isn't a failure — the photo is simply gone.
                result.withdrawn += 1
            case .confirmed:
                confirmed.append(slug)
                result.confirmed += 1
            case .deferred:
                result.deferred += 1
            case .refresh:
                if let published, await refreshCachedSizes(slug: slug) {
                    advanced[slug] = published
                    result.refreshed += 1
                } else {
                    result.failed += 1
                }
            }
        }
        PhotoManifestStore.shared.markValidated(confirmed, advancedHashes: advanced)
        return result
    }

    /// Re-pulls whichever persisted sizes a slug currently has on disk, writing
    /// none of them until *all* of them have downloaded and decoded. That
    /// all-or-nothing step is what keeps a half-finished refresh from leaving a
    /// species with a new thumbnail and a stale medium image — or with nothing at
    /// all. Returns whether the replacement landed.
    private func refreshCachedSizes(slug: String) async -> Bool {
        let fm = FileManager.default
        var wanted: [ImageSize] = []
        if fm.fileExists(atPath: thumbFileURL(forSlug: slug).path) { wanted.append(.thumb) }
        if fm.fileExists(atPath: fileURL(forSlug: slug).path) { wanted.append(.medium) }
        guard !wanted.isEmpty else { return false }

        var fetched: [(size: ImageSize, data: Data)] = []
        for size in wanted {
            guard let url = Self.assetURL(slug: slug, folder: size.folder),
                  let data = await download(url),
                  UIImage(data: data) != nil else {
                return false
            }
            fetched.append((size, data))
        }
        for entry in fetched {
            try? entry.data.write(to: fileURL(forSlug: slug, size: entry.size), options: .atomic)
        }
        // The decoded copies are now of the old photo.
        let key = slug as NSString
        memory.removeObject(forKey: key)
        thumbnailMemory.removeObject(forKey: key)
        fullResImageMemory.removeObject(forKey: key)
        return true
    }

    /// Every slug with bytes on disk, at either persisted size.
    private func cachedSlugs() -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var slugs = Set<String>()
        for url in urls where url.pathExtension == "jpg" {
            var name = url.deletingPathExtension().lastPathComponent
            if name.hasSuffix("_thumb") { name.removeLast("_thumb".count) }
            slugs.insert(name)
        }
        return Array(slugs)
    }

    // MARK: - Cache stats (debug)

    /// Per-resolution count of how many of a group of species have an image
    /// cached: `thumb`/`medium` from disk, `full` from the in-memory viewer tier.
    /// `total` is how many of the group have photo metadata at all (the reachable
    /// maximum). Used by the More tab's debug readout.
    struct ResolutionCounts: Sendable {
        var thumb = 0
        var medium = 0
        var full = 0
        var total = 0
    }

    func cacheCounts(for scientificNames: [String]) -> ResolutionCounts {
        let fm = FileManager.default
        var seen = Set<String>()
        var counts = ResolutionCounts()
        for name in scientificNames {
            let slug = SpeciesImage.slug(for: name)
            guard !slug.isEmpty, seen.insert(slug).inserted,
                  isAttributed(name) else { continue }
            counts.total += 1
            if fm.fileExists(atPath: thumbFileURL(forSlug: slug).path) { counts.thumb += 1 }
            if fm.fileExists(atPath: fileURL(forSlug: slug).path) { counts.medium += 1 }
            if fullResImageMemory.object(forKey: slug as NSString) != nil { counts.full += 1 }
        }
        return counts
    }

    // MARK: - "Other" image cap

    /// Sets the species whose cached images are never evicted — the life list
    /// plus the nearby region. Pass scientific names; they're slugged here.
    /// Enforces the cap afterward in case the protected set shrank.
    func setProtectedSpecies(_ scientificNames: [String]) {
        let slugs = Set(scientificNames.map { SpeciesImage.slug(for: $0) }.filter { !$0.isEmpty })
        protectedLock.lock()
        protectedSlugs = slugs
        let enabled = limitOtherImages
        protectedLock.unlock()
        if enabled { enforceOtherImageLimit() }
    }

    /// Turns the "other images" cap on or off, enforcing it immediately when
    /// turned on so existing over-cap images are pruned right away. Set once, to
    /// `true`, at launch — it was a user-facing setting and is now simply how the
    /// cache behaves.
    func setLimitOtherImages(_ enabled: Bool) {
        protectedLock.lock()
        limitOtherImages = enabled
        protectedLock.unlock()
        if enabled { enforceOtherImageLimit() }
    }

    /// Called after a fresh image lands on disk. Triggers a prune only when the
    /// cap is on and the just-cached image is non-protected (so region/life-list
    /// prefetch, which is all protected, never thrashes the eviction pass).
    private func didCacheImage(slug: String) {
        protectedLock.lock()
        let shouldEnforce = limitOtherImages && !protectedSlugs.contains(slug)
        protectedLock.unlock()
        if shouldEnforce { enforceOtherImageLimit() }
    }

    private func enforceOtherImageLimit() {
        Task.detached(priority: .utility) { [weak self] in
            self?.pruneOtherImages()
        }
    }

    /// Evicts the oldest non-protected cached images until the "other" bucket is
    /// back under `otherImagesLimitBytes`. No-op when the cap is off.
    private func pruneOtherImages() {
        protectedLock.lock()
        guard limitOtherImages else { protectedLock.unlock(); return }
        let protectedSlugs = self.protectedSlugs
        protectedLock.unlock()

        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        struct Cached { let url: URL; let slug: String; let size: Int64; let date: Date }
        var others: [Cached] = []
        var total: Int64 = 0
        for url in urls where url.pathExtension == "jpg" {
            let filename = url.deletingPathExtension().lastPathComponent
            // Thumbnails (`{slug}_thumb.jpg`) are never evicted — they're tiny, and
            // keeping every one on disk means a large multi-bird card never has to
            // re-download them while scrolling. Skip them entirely (neither counted
            // toward the cap nor eligible for removal).
            if filename.hasSuffix("_thumb") { continue }
            let slug = filename
            if protectedSlugs.contains(slug) { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentModificationDate ?? .distantPast
            others.append(Cached(url: url, slug: slug, size: size, date: date))
            total += size
        }
        guard total > Self.otherImagesLimitBytes else { return }

        // Oldest first, evicting until back under the cap. Only the medium image is
        // removed; its thumbnail (disk + memory) is intentionally left resident.
        others.sort { $0.date < $1.date }
        for entry in others {
            if total <= Self.otherImagesLimitBytes { break }
            try? fm.removeItem(at: entry.url)
            memory.removeObject(forKey: entry.slug as NSString)
            total -= entry.size
        }
    }

    /// Debug helper (About screen, DEBUG builds): wipes every cached species
    /// image across all tiers — the in-memory medium, thumbnail, and
    /// full-resolution caches, plus every on-disk JPEG (medium images and
    /// thumbnails). Protected-slug bookkeeping is left intact; images simply
    /// re-download on next access.
    func clearAllCaches() {
        memory.removeAllObjects()
        thumbnailMemory.removeAllObjects()
        fullResImageMemory.removeAllObjects()
        let fm = FileManager.default
        if let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in urls where url.pathExtension == "jpg" {
                try? fm.removeItem(at: url)
            }
        }
        // The stamps described bytes that no longer exist.
        PhotoManifestStore.shared.clearValidationStamps()
    }
}

private extension UIImage {
    /// Approximate resident memory of the decoded bitmap (4 bytes per pixel),
    /// used as the `NSCache` cost so the full-res tier evicts by real footprint.
    /// `nonisolated` (the project defaults to MainActor isolation) so the store's
    /// off-main full-res loader can compute it.
    nonisolated var decodedByteCost: Int {
        if let cg = cgImage {
            return cg.width * cg.height * 4
        }
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        return Int(pixelWidth * pixelHeight * 4)
    }
}
