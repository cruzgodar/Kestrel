import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Produces and caches the small JPEGs sent to the watch for its "now hearing"
/// screen. Downscaling happens at most once per species; the result is cached
/// to disk so repeat detections — and repeat sessions — never re-render or
/// re-encode. The watch keeps its own cache, so each image is normally
/// transferred over WatchConnectivity exactly once.
///
/// `@unchecked Sendable`: stateless apart from the on-disk cache directory,
/// whose access is naturally serialized (one image is produced per request and
/// writes are atomic).
final class WatchImageProvider: @unchecked Sendable {
    static let shared = WatchImageProvider()

    /// Longest edge, in pixels, of the JPEG handed to the watch. The largest
    /// Apple Watch display is ~205 pt wide; at 2x that's ~410 px, but the
    /// image occupies well under the full width, so 320 is plenty and keeps
    /// payloads to a handful of KB.
    private let maxPixel = 320
    private let jpegQuality: CGFloat = 0.7

    private let dir: URL

    private init() {
        let base = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("WatchSpeciesImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func fileURL(forSlug slug: String) -> URL {
        dir.appendingPathComponent(slug + ".jpg")
    }

    /// Downscaled JPEG bytes for the species, or nil if no source image is
    /// available (e.g. embed mode with no network and nothing cached). Honors
    /// the active image source the same way `SpeciesPhoto` does. Caches the
    /// result on disk. Call off the main actor — embed mode can hit the network.
    func jpegData(for scientificName: String) async -> Data? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty else { return nil }

        // Already-produced downscaled copy.
        let cached = fileURL(forSlug: slug)
        if let data = try? Data(contentsOf: cached) { return data }

        let produced: Data?
        switch AppSettings.persistedImageSource() {
        case .bundled:
            // ImageIO thumbnails straight from the bundled file without ever
            // decoding the full-size image into memory.
            produced = SpeciesImage.largeURL(for: scientificName)
                .flatMap { Self.downscaledJPEG(fileURL: $0, maxPixel: maxPixel, quality: jpegQuality) }
        case .embed:
            // Pull through the remote store (memory → disk → network), then
            // downscale the decoded image.
            if let image = await RemoteSpeciesImageStore.shared.image(for: scientificName) {
                produced = Self.downscaledJPEG(image: image, maxPixel: maxPixel, quality: jpegQuality)
            } else {
                produced = nil
            }
        }

        if let produced { try? produced.write(to: cached, options: .atomic) }
        return produced
    }

    // MARK: - Downscaling

    /// Memory-efficient path: lets ImageIO decode the source directly at the
    /// target size rather than loading the whole image first.
    private static func downscaledJPEG(fileURL: URL, maxPixel: Int, quality: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return encodeJPEG(thumb, quality: quality)
    }

    /// Fallback for an already-decoded `UIImage` (embed source).
    private static func downscaledJPEG(image: UIImage, maxPixel: Int, quality: CGFloat) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0, let cg = image.cgImage else {
            return image.jpegData(compressionQuality: quality)
        }
        let scale = min(1, CGFloat(maxPixel) / longest)
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let scaled = renderer.image { _ in
            UIImage(cgImage: cg, scale: 1, orientation: image.imageOrientation)
                .draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.jpegData(compressionQuality: quality)
    }

    /// Encodes a `CGImage` to JPEG via ImageIO (no intermediate `UIImage`).
    private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
