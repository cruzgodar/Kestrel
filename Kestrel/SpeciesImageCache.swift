import UIKit

/// In-memory cache for bundled species thumbnails. NSCache auto-evicts under
/// memory pressure so we don't have to manage it.
@MainActor
final class SpeciesImageCache {
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
        cache.setObject(image, forKey: key)
        return image
    }
}
