import Foundation

/// Filename-slug + Bundle URL helper for the species thumbnails bundled into
/// the app under `Kestrel/Models/SpeciesImages/<slug>.jpg`. The slugging
/// algorithm is identical to the one in `scripts/fetch_species_images.py`
/// (`slug_for`) so the two stay in sync.
enum SpeciesImage {
    /// Converts a scientific name into the filename slug used by the
    /// ingestion script. Lowercased, ASCII-only, runs of non-alphanumerics
    /// collapsed to `_`. Must mirror `slug_for` in fetch_species_images.py.
    static func slug(for scientificName: String) -> String {
        let lowered = scientificName.lowercased()
        // Strip diacritics. `applyingTransform(.stripDiacritics)` returns an
        // optional but always succeeds for Latin text.
        let stripped = lowered.applyingTransform(.stripDiacritics, reverse: false)
            ?? lowered

        var result = ""
        var lastUnderscore = false
        for scalar in stripped.unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c.isNumber {
                result.append(c)
                lastUnderscore = false
            } else if !lastUnderscore {
                result.append("_")
                lastUnderscore = true
            }
        }
        // Trim leading/trailing underscores.
        while result.hasPrefix("_") { result.removeFirst() }
        while result.hasSuffix("_") { result.removeLast() }
        return result
    }

    /// Returns the bundle URL of the thumbnail for this species, or nil if
    /// no image is bundled. The Xcode sync group flattens all bundled
    /// resources into the bundle root, so we look up by slug + `.jpg`.
    static func url(for scientificName: String) -> URL? {
        let slug = slug(for: scientificName)
        guard !slug.isEmpty else { return nil }
        return Bundle.main.url(forResource: slug, withExtension: "jpg")
    }
}
