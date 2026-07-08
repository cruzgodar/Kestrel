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
///   • **full** (cropped original) — from the `full/` folder, memory-only and
///     never persisted. Fetched only on demand when a card opens full-screen, so
///     a pinch-zoom is crisp.
///
/// Downloads are ordered and coalesced by `ImageDownloadQueue`: a wake (app
/// launch or session start) prefetches 320-nearby, then 320-life-list, then
/// 900-nearby, then 900-life-list, while on-demand loads jump the queue. The
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
    /// jsDelivr CDN from the GitHub photo repo. Pinned to an immutable release
    /// tag so jsDelivr caches it permanently — **bump the tag whenever you
    /// publish a new build of the photo set** (see
    /// `scripts/README_species_photos.md`). Each size lives under its own folder
    /// (`thumb/`, `hero/`, `full/`), and every file is named `<slug>.jpg`.
    static let assetBaseURL = "https://cdn.jsdelivr.net/gh/cruzgodar/Kestrel@v1"

    /// Path component of the on-demand full-resolution tier — the cropped
    /// original, used only when a card opens full-screen for a crisp pinch-zoom.
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

    /// Synchronous in-memory lookup only (no disk, no network). Safe + instant
    /// on the main actor — used to avoid a placeholder flash for photos already
    /// decoded this session.
    func memoryImage(for scientificName: String) -> UIImage? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty else { return nil }
        return memory.object(forKey: slug as NSString)
    }

    /// Synchronous in-memory thumbnail lookup only (no disk, no network). The
    /// thumbnail counterpart of `memoryImage(for:)` — used by small photo contexts
    /// to render an already-decoded thumbnail with no placeholder flash.
    func memoryThumbnail(for scientificName: String) -> UIImage? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty else { return nil }
        return thumbnailMemory.object(forKey: slug as NSString)
    }

    /// Synchronous in-memory full-resolution lookup only (no network). Lets the
    /// viewer show an already-fetched full-res image immediately when re-opening a
    /// card, with no medium→full swap flash.
    func memoryFullResolutionImage(for scientificName: String) -> UIImage? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty else { return nil }
        return fullResImageMemory.object(forKey: slug as NSString)
    }

    /// Returns the medium photo, loading from memory → disk → network as needed,
    /// and promoting the result up the tiers. Returns nil when there's no
    /// metadata URL for the species or the download fails. On a network miss the
    /// download jumps the prefetch queue. Call off the main actor.
    func image(for scientificName: String) async -> UIImage? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty else { return nil }
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
        guard !slug.isEmpty else { return nil }
        let key = slug as NSString

        if let cached = fullResImageMemory.object(forKey: key) { return cached }

        guard SpeciesPhotoMetadata.shared.info(for: scientificName) != nil,
              let url = Self.assetURL(slug: slug, folder: Self.fullResFolder),
              let data = await download(url),
              let img = UIImage(data: data) else {
            return nil
        }
        let prepared = img.preparingForDisplay() ?? img
        fullResImageMemory.setObject(prepared, forKey: key, cost: prepared.decodedByteCost)
        return prepared
    }

    /// Returns the small (320 px) thumbnail, loading from memory → disk → CDN
    /// `/320` as needed and promoting up the tiers. Far cheaper to decode and hold
    /// than the medium image — use it for lists, map pins, cluster grids, and the
    /// hero's first paint. On a network miss the download jumps the prefetch
    /// queue. Returns nil when there's no metadata URL or loading fails. Call off
    /// the main actor.
    func thumbnailImage(for scientificName: String) async -> UIImage? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty else { return nil }
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

    /// Raw JPEG bytes of the 320 px thumbnail — disk if present, otherwise
    /// fetched from the CDN (jumping the prefetch queue). Handed straight to the
    /// watch, which caches and decodes them itself, so the phone never decodes or
    /// re-encodes. Call off the main actor.
    func thumbnailData(for scientificName: String) async -> Data? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty else { return nil }
        if let data = try? Data(contentsOf: thumbFileURL(forSlug: slug)) { return data }
        return await queue.fetch(slug: slug, name: scientificName, size: .thumb)
    }

    /// Builds the jsDelivr URL for one species photo at a given size folder
    /// (`thumb`/`hero`/`full`) from its slug: `{base}/{folder}/{slug}.jpg`.
    static func assetURL(slug: String, folder: String) -> URL? {
        URL(string: "\(assetBaseURL)/\(folder)/\(slug).jpg")
    }

    /// Downloads (if not already on disk) and persists the bytes for one
    /// prefetchable size, returning them. This is the single primitive the
    /// download queue drives; it does no in-memory caching (bulk prefetch
    /// shouldn't decode thousands of images), leaving that to the on-demand tier
    /// methods. Medium downloads count toward the "other images" cap; thumbnails
    /// don't. Safe to call concurrently.
    private func downloadAndStore(slug: String, name: String, size: ImageSize) async -> Data? {
        let dest = fileURL(forSlug: slug, size: size)
        if let data = try? Data(contentsOf: dest) { return data }

        guard SpeciesPhotoMetadata.shared.info(for: name) != nil,
              let url = Self.assetURL(slug: slug, folder: size.folder),
              let data = await download(url),
              UIImage(data: data) != nil else {
            return nil
        }
        try? data.write(to: dest, options: .atomic)
        if size == .medium { didCacheImage(slug: slug) }
        return data
    }

    /// Ensures the medium species photo is on disk (downloading if needed) and
    /// returns its local file URL, or nil if unavailable. Used by the
    /// notification attachment, which needs a real file to hand to the system.
    /// Call off the main actor.
    func localFileURL(for scientificName: String) async -> URL? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty else { return nil }
        let dest = fileURL(forSlug: slug)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        _ = await queue.fetch(slug: slug, name: scientificName, size: .medium)
        return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
    }

    // MARK: - Prefetch

    /// Warms the caches on a wake (app launch or session start). Enqueues four
    /// tiers, drained strictly in order: every nearby species' 320 thumbnail
    /// first, then the rest of the life list's 320 thumbnails, then nearby 900
    /// medium, then the rest of the life list's 900 medium. 2400 is never
    /// prefetched. Already-on-disk sizes and duplicates are filtered out, so this
    /// is cheap to call on every launch and whenever the region list changes.
    ///
    /// `nearby` may already include life-list species (that's expected — nearby
    /// lifers get their thumbnails first); `lifeList` is fetched for the species
    /// *not* already covered by `nearby` so nothing is queued twice.
    func prefetchWake(lifeList: [String], nearby: [String]) {
        let nearbySlugs = Set(nearby.map { SpeciesImage.slug(for: $0) })
        let lifeListOnly = lifeList.filter { !nearbySlugs.contains(SpeciesImage.slug(for: $0)) }

        Task { [queue] in
            guard let queue else { return }
            await queue.resetPrefetch()
            await queue.enqueue(requests(nearby, .thumb), tier: .nearbyThumb)
            await queue.enqueue(requests(lifeListOnly, .thumb), tier: .lifeListThumb)
            await queue.enqueue(requests(nearby, .medium), tier: .nearbyMedium)
            await queue.enqueue(requests(lifeListOnly, .medium), tier: .lifeListMedium)
        }
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
            guard !slug.isEmpty, seen.insert(slug).inserted,
                  SpeciesPhotoMetadata.shared.info(for: name) != nil,
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
                  SpeciesPhotoMetadata.shared.info(for: name) != nil else { continue }
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

    /// Mirrors the user's "Limit Cached Images" setting. Enforces immediately
    /// when turned on so existing over-cap images are pruned right away.
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
