import UIKit

/// Disk + memory cache for the small species photos the phone pushes for the
/// "now hearing" screen. Once an image arrives it's kept so the same bird heard
/// again — this session or a later one — never needs another transfer. Capped
/// by file count so a long, varied birding session can't grow it without bound.
///
/// `@unchecked Sendable`: writes are atomic and the cache is hit from the
/// WatchConnectivity delegate and the main actor; the worst case of a race is a
/// redundant decode, never corruption.
final class WatchSpeciesImageCache: @unchecked Sendable {
    static let shared = WatchSpeciesImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private let maxFiles = 200

    private init() {
        let base = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("WatchSpeciesImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.countLimit = 64
    }

    /// Stable, filesystem-safe key for a scientific name. Independent of the
    /// phone's slug — the protocol carries the scientific name, so the two
    /// sides only need their own internally-consistent mapping.
    private func key(_ scientificName: String) -> String {
        var out = ""
        var lastUnderscore = false
        for scalar in scientificName.lowercased().unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c.isNumber {
                out.append(c)
                lastUnderscore = false
            } else if !lastUnderscore {
                out.append("_")
                lastUnderscore = true
            }
        }
        while out.hasPrefix("_") { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        return out
    }

    private func fileURL(_ key: String) -> URL {
        dir.appendingPathComponent(key + ".jpg")
    }

    /// Cached image for the species, memory → disk, or nil if not yet received.
    func image(for scientificName: String) -> UIImage? {
        let k = key(scientificName)
        guard !k.isEmpty else { return nil }
        if let mem = memory.object(forKey: k as NSString) { return mem }
        guard let data = try? Data(contentsOf: fileURL(k)),
              let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: k as NSString)
        return img
    }

    /// Stores image bytes received from the phone. Returns the decoded image so
    /// the caller can update the display in one step.
    @discardableResult
    func store(_ data: Data, for scientificName: String) -> UIImage? {
        let k = key(scientificName)
        guard !k.isEmpty else { return nil }
        try? data.write(to: fileURL(k), options: .atomic)
        let img = UIImage(data: data)
        if let img { memory.setObject(img, forKey: k as NSString) }
        trimIfNeeded()
        return img
    }

    /// Evicts the oldest files once the cache exceeds `maxFiles`. Cheap — runs
    /// only on store and the directory is small.
    private func trimIfNeeded() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), urls.count > maxFiles else { return }

        let sorted = urls.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
        for url in sorted.prefix(urls.count - maxFiles) {
            try? fm.removeItem(at: url)
        }
    }
}
