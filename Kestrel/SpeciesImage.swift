import Foundation

/// Filename-slug helper for species photos. The slug keys both the remote
/// embed store's on-disk cache and the watch image transfer. The slugging
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
}
