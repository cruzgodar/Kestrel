import UIKit

/// In-memory cache for bundled species thumbnails. NSCache auto-evicts under
/// memory pressure so we don't have to manage it.
///
/// The cache is locked internally and intentionally not isolated to MainActor
/// so the preheat path can decode + display-prepare images on a background
/// queue without bouncing every entry through main.
final class SpeciesImageCache: @unchecked Sendable {
    static let shared = SpeciesImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 512   // generous; UIImage instances are small
    }

    func image(for scientificName: String) -> UIImage? {
        let key = scientificName as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = SpeciesImage.largeURL(for: scientificName),
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        // Force the decode + colorspace conversion to happen here on whatever
        // thread called us, instead of lazily at draw time on main when the
        // image first appears in a row. This is the difference between a
        // tab-switch lag spike and a smooth first paint.
        let prepared = image.preparingForDisplay() ?? image
        cache.setObject(prepared, forKey: key)
        return prepared
    }

    /// Decodes + display-prepares the images for the given species names in
    /// the background. Safe to call from any thread; idempotent (existing
    /// cache entries are skipped).
    func preheat(scientificNames: [String]) {
        DispatchQueue.global(qos: .utility).async { [cache] in
            for name in scientificNames {
                let key = name as NSString
                if cache.object(forKey: key) != nil { continue }
                guard let url = SpeciesImage.largeURL(for: name),
                      let image = UIImage(contentsOfFile: url.path) else {
                    continue
                }
                let prepared = image.preparingForDisplay() ?? image
                cache.setObject(prepared, forKey: key)
            }
        }
    }
}
