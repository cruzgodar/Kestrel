import ImageIO
import UIKit

/// Persistent store for the remote ("Official embed") species photos.
///
/// Three tiers: an in-memory `NSCache` of decoded images, an on-disk JPEG cache
/// in Application Support (which the system does *not* purge — once downloaded a
/// photo stays forever), and the network as the source of truth. The on-disk
/// copy is keyed by the `SpeciesImage` filename slug.
///
/// A parallel **thumbnail tier** mirrors all three: a small (`thumbnailMaxPixelSize`
/// max dimension) downsample of each photo, cached in memory and on disk as
/// `{slug}_thumb.jpg`. Lists, map pins, and cluster grids show *many* photos at a
/// small size; decoding the full ~900px image for each is what made scrolling them
/// sluggish. The thumbnail is generated with ImageIO (which decode-downsamples
/// without ever allocating the full bitmap) the first time it's needed and when a
/// photo is freshly downloaded, then served from the cheap caches thereafter. The
/// full-screen viewer keeps using the full-resolution tier (`image(for:)`).
///
/// `@unchecked Sendable` + nonisolated: callers hit it from view bodies,
/// background prefetch tasks, and the full-screen viewer.
nonisolated final class RemoteSpeciesImageStore: @unchecked Sendable {
    static let shared = RemoteSpeciesImageStore()

    private let memory = NSCache<NSString, UIImage>()
    /// In-memory cache of downsampled thumbnails (see the thumbnail tier note).
    /// Separate from `memory` so a thumbnail and its full image can both be
    /// resident without evicting each other.
    private let thumbnailMemory = NSCache<NSString, UIImage>()
    /// In-memory-only cache of the **true full-resolution** photos (the largest
    /// size the Macaulay CDN exposes). The full-screen viewer fetches one in the
    /// background when a card opens and swaps it in for the medium-res image so a
    /// pinch-zoom is crisp. Bounded by total decoded byte cost (see
    /// `fullResImageMemory.totalCostLimit`) rather than count, and never persisted —
    /// the medium 900px disk copy stays the protected/offline source of truth.
    private let fullResImageMemory = NSCache<NSString, UIImage>()
    private let dir: URL
    private let session: URLSession

    /// Longest edge, in pixels, of a cached thumbnail. Deliberately small — every
    /// small-photo context (list rows, map pins, cluster-grid cells) shows the
    /// photo at a modest size, so a downsample decodes and holds for almost
    /// nothing. The hero (Identify) and full-screen viewer use the full-resolution
    /// tier instead, so they're unaffected by how small this is.
    static let thumbnailMaxPixelSize: CGFloat = 300

    /// Ceiling for cached "other" images — anything neither on the life list
    /// nor in the current nearby list — enforced only while the user's "Limit
    /// Cached Images" setting is on.
    static let otherImagesLimitBytes: Int64 = 50 * 1024 * 1024

    /// In-memory budget (decoded bytes) for the full-resolution viewer tier.
    /// `NSCache` evicts the least-recently-used full-res images once the resident
    /// set's total cost exceeds this.
    static let fullResMemoryLimitBytes = 50 * 1024 * 1024

    /// The Macaulay CDN size component requested for the full-resolution tier.
    /// The stored metadata URLs use `/900`; `/2400` is the largest size the asset
    /// endpoint serves (`large`/`original` 404). Swapped into the URL's trailing
    /// numeric path component by `fullResolutionURL(from:)`.
    private static let fullResSizeComponent = "2400"

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

    /// Returns the photo, loading from memory → disk → network as needed, and
    /// promoting the result up the tiers. Returns nil when there's no metadata
    /// URL for the species or the download fails. Call off the main actor.
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

        // Network.
        guard let info = SpeciesPhotoMetadata.shared.info(for: scientificName),
              let url = URL(string: info.url),
              let data = await download(url),
              let img = UIImage(data: data) else {
            return nil
        }
        try? data.write(to: fileURL(forSlug: slug), options: .atomic)
        didCacheImage(slug: slug)
        // Generate the thumbnail off the bytes we already have in hand, so a small
        // context that loads this species next gets it from cache.
        _ = makeAndCacheThumbnail(slug: slug, from: data)
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

        guard let info = SpeciesPhotoMetadata.shared.info(for: scientificName),
              let url = Self.fullResolutionURL(from: info.url),
              let data = await download(url),
              let img = UIImage(data: data) else {
            return nil
        }
        let prepared = img.preparingForDisplay() ?? img
        fullResImageMemory.setObject(prepared, forKey: key, cost: prepared.decodedByteCost)
        return prepared
    }

    /// Rewrites a Macaulay asset URL to request the full-resolution size by
    /// swapping its trailing numeric path component (e.g. `…/asset/123/900`) for
    /// `fullResSizeComponent`. Returns nil if the URL doesn't end in a numeric size
    /// component (so we never fabricate a bad URL) or already requests it.
    static func fullResolutionURL(from urlString: String) -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        let last = url.lastPathComponent
        // Only upgrade URLs whose final component is a bare size number, matching
        // the shape of the stored metadata URLs.
        guard !last.isEmpty, last.allSatisfy(\.isNumber) else { return nil }
        if last == fullResSizeComponent { return url }
        let upgraded = url.deletingLastPathComponent()
            .appendingPathComponent(fullResSizeComponent)
        return upgraded
    }

    /// Returns a small downsampled thumbnail of the species photo, loading from
    /// memory → disk-thumbnail → (full-resolution bytes, downsampled) → network as
    /// needed and promoting the result up the tiers. Far cheaper to decode and
    /// hold than the full image — use it for lists, map pins, and cluster grids.
    /// Returns nil when there's no metadata URL for the species or loading fails.
    /// Call off the main actor.
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

        // No thumbnail yet: downsample from the full image's bytes (cached on disk
        // if we have it, otherwise fetched from the network — which also persists
        // the full image and seeds its own thumbnail).
        guard let fullData = await fullImageData(slug: slug, scientificName: scientificName) else {
            return nil
        }
        return makeAndCacheThumbnail(slug: slug, from: fullData)
    }

    /// Full-resolution image bytes for a species — from the on-disk cache if
    /// present, otherwise downloaded and persisted (so the viewer and a later
    /// thumbnail request both benefit). Returns nil when unavailable.
    private func fullImageData(slug: String, scientificName: String) async -> Data? {
        if let data = try? Data(contentsOf: fileURL(forSlug: slug)) {
            return data
        }
        guard let info = SpeciesPhotoMetadata.shared.info(for: scientificName),
              let url = URL(string: info.url),
              let data = await download(url),
              UIImage(data: data) != nil else {
            return nil
        }
        try? data.write(to: fileURL(forSlug: slug), options: .atomic)
        didCacheImage(slug: slug)
        return data
    }

    /// Downsamples the given image bytes to a thumbnail, writes it to disk, and
    /// caches it in memory. Returns the decoded thumbnail (nil if downsampling
    /// fails). Safe to call from any actor.
    @discardableResult
    private func makeAndCacheThumbnail(slug: String, from data: Data) -> UIImage? {
        guard let thumb = Self.downsample(data, maxPixelSize: Self.thumbnailMaxPixelSize) else {
            return nil
        }
        if let jpeg = thumb.jpegData(compressionQuality: 0.8) {
            try? jpeg.write(to: thumbFileURL(forSlug: slug), options: .atomic)
        }
        thumbnailMemory.setObject(thumb, forKey: slug as NSString)
        return thumb
    }

    /// Decode-downsamples JPEG/PNG bytes to a thumbnail whose longest edge is at
    /// most `maxPixelSize`, using ImageIO so the full-size bitmap is never
    /// allocated. `ShouldCacheImmediately` returns a ready-to-draw image.
    private static func downsample(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Ensures the species photo is on disk (downloading if needed) and returns
    /// its local file URL, or nil if unavailable. Used by the notification
    /// attachment, which needs a real file to hand to the system. Call off the
    /// main actor.
    func localFileURL(for scientificName: String) async -> URL? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty else { return nil }
        let dest = fileURL(forSlug: slug)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        await ensureDownloaded(scientificName)
        return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
    }

    // MARK: - Prefetch

    /// Downloads + persists every not-yet-cached species in the list, in the
    /// background, with bounded concurrency. Idempotent — already-downloaded
    /// photos are skipped, so this is cheap to call on every launch and
    /// whenever the region list changes.
    func prefetch(scientificNames: [String]) {
        let targets = scientificNames.filter { name in
            let slug = SpeciesImage.slug(for: name)
            return !slug.isEmpty
                && !FileManager.default.fileExists(atPath: fileURL(forSlug: slug).path)
                && SpeciesPhotoMetadata.shared.info(for: name) != nil
        }
        guard !targets.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let maxConcurrent = 6
            var iterator = targets.makeIterator()
            await withTaskGroup(of: Void.self) { group in
                func addNext() {
                    guard let name = iterator.next() else { return }
                    group.addTask { await self.ensureDownloaded(name) }
                }
                for _ in 0..<maxConcurrent { addNext() }
                while await group.next() != nil { addNext() }
            }
        }
    }

    /// Downloads a single species' photo to disk if missing. Skips the memory
    /// cache + display prep — prefetch only needs the bytes on disk, decoding
    /// thousands of images up front would waste memory.
    private func ensureDownloaded(_ scientificName: String) async {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty else { return }
        let dest = fileURL(forSlug: slug)
        if FileManager.default.fileExists(atPath: dest.path) { return }
        guard let info = SpeciesPhotoMetadata.shared.info(for: scientificName),
              let url = URL(string: info.url),
              let data = await download(url),
              UIImage(data: data) != nil else {
            return
        }
        try? data.write(to: dest, options: .atomic)
        didCacheImage(slug: slug)
        // Seed the thumbnail while we have the bytes, so the first time this
        // species scrolls into a list/map it's served straight from cache.
        makeAndCacheThumbnail(slug: slug, from: data)
    }

    /// Scans the on-disk cache and generates a thumbnail for every full image
    /// that doesn't already have one. Run once at launch so the first scroll
    /// through a large multi-bird card doesn't pay the per-thumbnail downsample
    /// cost (which is what made that first scroll sluggish). Writes straight to
    /// disk without touching the memory cache, so seeding thousands of thumbnails
    /// up front doesn't balloon memory — they decode cheaply from disk on demand.
    func generateMissingThumbnails() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            for url in urls where url.pathExtension == "jpg" {
                let filename = url.deletingPathExtension().lastPathComponent
                if filename.hasSuffix("_thumb") { continue }
                let thumbURL = thumbFileURL(forSlug: filename)
                if fm.fileExists(atPath: thumbURL.path) { continue }
                guard let data = try? Data(contentsOf: url),
                      let thumb = Self.downsample(data, maxPixelSize: Self.thumbnailMaxPixelSize),
                      let jpeg = thumb.jpegData(compressionQuality: 0.8) else { continue }
                try? jpeg.write(to: thumbURL, options: .atomic)
            }
        }
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
            // regenerate them while scrolling. Skip them entirely (neither counted
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

        // Oldest first, evicting until back under the cap. Only the full image is
        // removed; its thumbnail (disk + memory) is intentionally left resident.
        others.sort { $0.date < $1.date }
        for entry in others {
            if total <= Self.otherImagesLimitBytes { break }
            try? fm.removeItem(at: entry.url)
            memory.removeObject(forKey: entry.slug as NSString)
            total -= entry.size
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
