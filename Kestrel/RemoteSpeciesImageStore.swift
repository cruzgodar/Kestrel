import UIKit

/// Persistent store for the remote ("Official embed") species photos.
///
/// Three tiers: an in-memory `NSCache` of decoded images, an on-disk JPEG cache
/// in Application Support (which the system does *not* purge — once downloaded a
/// photo stays forever), and the network as the source of truth. The on-disk
/// copy is keyed by the same filename slug the bundled images use.
///
/// `@unchecked Sendable` + nonisolated like `SpeciesImageCache`: callers hit it
/// from view bodies, background prefetch tasks, and the full-screen viewer.
final class RemoteSpeciesImageStore: @unchecked Sendable {
    static let shared = RemoteSpeciesImageStore()

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private let session: URLSession

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
        let prepared = img.preparingForDisplay() ?? img
        memory.setObject(prepared, forKey: key)
        return prepared
    }

    // MARK: - Prefetch

    /// Downloads + persists every not-yet-cached species in the list, in the
    /// background, with bounded concurrency. No-ops unless the embed source is
    /// active. Idempotent — already-downloaded photos are skipped, so this is
    /// cheap to call on every launch and whenever the region list changes.
    func prefetch(scientificNames: [String]) {
        guard AppSettings.persistedImageSource() == .embed else { return }
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
        if let allowed = SpeciesRangeFilter.cachedAllowedIndices() {
            let all = SpeciesCatalog.shared.all
            for i in allowed where all.indices.contains(i) {
                names.append(all[i].scientificName)
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
