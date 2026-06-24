import Foundation

/// Per-species remote photo info used by the `.embed` image source. Sourced
/// from `Kestrel/Models/species_photos.json`, which the
/// `scripts/fetch_species_images.py` run emits alongside the bundled JPEGs
/// (keyed by the same filename slug). Maps a species to the Macaulay Library
/// CDN URL of its featured photo plus, when the page exposed it, the
/// photographer credit for attribution.
struct SpeciesPhotoInfo: Decodable {
    let url: String
    /// Photographer / contributor name, when the eBird page exposed one.
    let credit: String?
    /// eBird species code (e.g. "rufwar1"), used to link to the species page.
    let code: String?

    /// Macaulay attribution line. Follows the Macaulay Library crediting
    /// format ("… © Contributor; Cornell Lab of Ornithology | Macaulay
    /// Library"), degrading to the institutional credit when we have no name.
    var attribution: String {
        if let credit, !credit.isEmpty {
            return "© \(credit); Cornell Lab of Ornithology | Macaulay Library"
        }
        return "Cornell Lab of Ornithology | Macaulay Library"
    }

    /// Link to the species' eBird page, when we have its species code.
    var ebirdURL: URL? {
        guard let code, !code.isEmpty else { return nil }
        return URL(string: "https://ebird.org/species/\(code)")
    }
}

/// Loads + caches the bundled `species_photos.json` once. Absent file (e.g. the
/// fetch script hasn't been re-run to emit it yet) yields an empty map, so the
/// `.embed` source simply falls back to the placeholder.
nonisolated final class SpeciesPhotoMetadata: @unchecked Sendable {
    nonisolated static let shared = SpeciesPhotoMetadata()

    private let bySlug: [String: SpeciesPhotoInfo]

    private init() {
        guard let url = Bundle.main.url(forResource: "species_photos", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: SpeciesPhotoInfo].self, from: data)
        else {
            bySlug = [:]
            return
        }
        bySlug = decoded
    }

    func info(for scientificName: String) -> SpeciesPhotoInfo? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty else { return nil }
        return bySlug[slug]
    }
}
