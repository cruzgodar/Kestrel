import Foundation

/// Maps scientific names a user may have on file (from eBird CSV imports
/// reflecting current AOS/Clements taxonomy) to the canonical BirdNET
/// scientific name used by the bundled image set and BirdNET's classifier.
///
/// Without this remap, an entry like "Northern Yellow Warbler" (eBird's
/// `Setophaga aestiva` after the 2024 split) would look up the slug
/// `setophaga_aestiva` and miss the bundled `setophaga_petechia.jpg`.
///
/// Keep keys in BirdNET-style binomial (Genus species). The migration in
/// `LifeListStore` applies this remap *before* attempting the common-name
/// canonicalization pass, so a hit here short-circuits both lookups.
///
/// Add new entries as users report missing images for common species.
enum TaxonomyAliases {
    static let ebirdToBirdNET: [String: String] = [
        // 2024 split of Yellow Warbler. eBird's "Northern Yellow Warbler"
        // (Setophaga aestiva) is what BirdNET trained on as plain
        // "Yellow Warbler" (Setophaga petechia).
        "Setophaga aestiva": "Setophaga petechia",
        // Herring Gull split: eBird's "American Herring Gull" is BirdNET's
        // plain "Herring Gull" (Larus argentatus, the pre-split combined name).
        "Larus smithsonianus": "Larus argentatus",
        // Warbling Vireo split: eBird's "Western Warbling Vireo" maps to
        // BirdNET's plain "Warbling Vireo" (Vireo gilvus, pre-split). Eastern
        // Warbling Vireo already uses Vireo gilvus, so no alias needed there.
        "Vireo swainsoni": "Vireo gilvus",
        // Cattle Egret split: eBird's "Western Cattle-Egret" (Ardea ibis)
        // maps to BirdNET's "Cattle Egret" under the older genus Bubulcus.
        "Ardea ibis": "Bubulcus ibis",
    ]

    /// Returns the BirdNET-canonical scientific name for `scientificName`,
    /// or `scientificName` unchanged if no alias is registered.
    static func canonical(_ scientificName: String) -> String {
        ebirdToBirdNET[scientificName] ?? scientificName
    }
}
