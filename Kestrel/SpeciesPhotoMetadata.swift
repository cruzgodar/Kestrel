import Foundation

/// Per-species photo metadata for the CC-licensed image set. Sourced from
/// `Kestrel/Models/species_photos.json`, which `scripts/build_species_photos.py`
/// emits (keyed by filename slug). The image bytes themselves are *not*
/// referenced here — `RemoteSpeciesImageStore` derives each size's URL from the
/// slug and a jsDelivr base — so this holds only the crediting/licensing info an
/// entry needs: photographer, license, and the source page for verification.
struct SpeciesPhotoInfo: Decodable {
    /// Photographer / contributor name, when the source page exposed one.
    let credit: String?
    /// License string as published at the source (e.g. "CC BY-SA 4.0", "CC0").
    let license: String?
    /// Source page (Wikimedia Commons / iNaturalist), where the license and
    /// attribution can be verified.
    let pageURL: String?
    /// eBird species code (e.g. "rufwar1"), used to link to the species page.
    let code: String?

    /// Attribution line for the CC-licensed photo: photographer and license,
    /// degrading gracefully when either is missing.
    var attribution: String {
        switch (credit?.nilIfEmpty, license?.nilIfEmpty) {
        case let (credit?, license?): return "\(credit) · \(license)"
        case let (credit?, nil): return credit
        case let (nil, license?): return license
        case (nil, nil): return "Public domain"
        }
    }

    /// Link to the photo's source page, so a tap can verify the license and
    /// attribution.
    var sourceURL: URL? {
        guard let pageURL, !pageURL.isEmpty else { return nil }
        return URL(string: pageURL)
    }

    /// Link to the species' eBird page, when we have its species code.
    var ebirdURL: URL? {
        guard let code, !code.isEmpty else { return nil }
        return URL(string: "https://ebird.org/species/\(code)")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Loads + caches the bundled `species_photos.json` once. Absent file (e.g. the
/// build script hasn't been re-run to emit it yet) yields an empty map, so
/// species with no metadata simply fall back to the placeholder.
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
