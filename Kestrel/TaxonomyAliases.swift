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
nonisolated enum TaxonomyAliases {
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
        // Cooper's Hawk moved to genus Astur (2024 AOS/Clements); BirdNET
        // trained on the older Accipiter cooperii.
        "Astur cooperii": "Accipiter cooperii",
        // Spotted Dove: eBird's Spilopelia chinensis vs BirdNET's older
        // Streptopelia chinensis.
        "Spilopelia chinensis": "Streptopelia chinensis",
        // Hairy Woodpecker under eBird's former genera (Picoides /
        // Leuconotopicus) → BirdNET's Dryobates villosus.
        "Picoides villosus": "Dryobates villosus",
        "Leuconotopicus villosus": "Dryobates villosus",
    ]

    /// Returns the BirdNET-canonical scientific name for `scientificName`,
    /// or `scientificName` unchanged if no alias is registered.
    static func canonical(_ scientificName: String) -> String {
        ebirdToBirdNET[scientificName] ?? scientificName
    }

    /// Collapses a scientific name to its species-level binomial —
    /// `"Genus species"`. Names with fewer than two tokens pass through.
    ///
    /// eBird exports subspecies groups as trinomials
    /// (`"Dryobates villosus harrisi"`), which would otherwise show up as
    /// duplicate species rows once the parenthetical common-name suffix is
    /// stripped. BirdNET and the rest of the app key off the binomial.
    ///
    /// **One definition, because this is one decision.** It was two — a private
    /// copy in `EBirdCSVParser`, where an import decides what a row's species
    /// *is*, and another in `LifeListStore.collapseToSpecies`, where a launch
    /// decides which stored entries are the same species. The two agreeing was
    /// load-bearing and unenforced: a trinomial the parser collapsed one way and
    /// the store collapsed another would file the imported row under a name no
    /// entry holds, and the merge that was supposed to fold them together would
    /// simply not fire. The rest of this area already works this way — the
    /// export's `sanitize` and `canonicalCoordinate` each have exactly one home,
    /// for exactly this reason.
    static func speciesBinomial(_ scientificName: String) -> String {
        let parts = scientificName.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2 else { return scientificName }
        return "\(parts[0]) \(parts[1])"
    }
}
