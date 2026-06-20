import UIKit

/// Persistent store for the remote ("Official embed") species photos.
///
/// Three tiers: an in-memory `NSCache` of decoded images, an on-disk JPEG cache
/// in Application Support (which the system does *not* purge — once downloaded a
/// photo stays forever), and the network as the source of truth. The on-disk
/// copy is keyed by the `SpeciesImage` filename slug.
///
/// `@unchecked Sendable` + nonisolated: callers hit it from view bodies,
/// background prefetch tasks, and the full-screen viewer.
final class RemoteSpeciesImageStore: @unchecked Sendable {
    static let shared = RemoteSpeciesImageStore()

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private let session: URLSession

    /// Ceiling for cached "other" images — anything neither on the life list
    /// nor in the current nearby list — enforced only while the user's "Limit
    /// Cached Images" setting is on.
    static let otherImagesLimitBytes: Int64 = 50 * 1024 * 1024

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

    // MARK: - Reads

    /// Synchronous in-memory lookup only (no disk, no network). Safe + instant
    /// on the main actor — used to avoid a placeholder flash for photos already
    /// decoded this session.
    func memoryImage(for scientificName: String) -> UIImage? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty else { return nil }
        return memory.object(forKey: slug as NSString)
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
        let prepared = img.preparingForDisplay() ?? img
        memory.setObject(prepared, forKey: key)
        return prepared
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
            let slug = url.deletingPathExtension().lastPathComponent
            if protectedSlugs.contains(slug) { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentModificationDate ?? .distantPast
            others.append(Cached(url: url, slug: slug, size: size, date: date))
            total += size
        }
        guard total > Self.otherImagesLimitBytes else { return }

        // Oldest first, evicting until back under the cap.
        others.sort { $0.date < $1.date }
        for entry in others {
            if total <= Self.otherImagesLimitBytes { break }
            try? fm.removeItem(at: entry.url)
            memory.removeObject(forKey: entry.slug as NSString)
            total -= entry.size
        }
    }
}
