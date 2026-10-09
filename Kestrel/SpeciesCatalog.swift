import Foundation

/// Read-only directory of every species BirdNET can recognize. Loaded once
/// at first access from the same labels file the classifier uses, with a
/// precomputed lowercase haystack per species so search is cheap.
///
/// `Sendable` + non-isolated so the suggestion-scoring loop can run on a
/// detached task without bouncing through the main actor per species.
final class SpeciesCatalog: @unchecked Sendable {
    // `nonisolated` so the shared catalog can be read from the nonisolated
    // suggestion-scoring loop (`LifeListView.computeSuggestions`) without an
    // actor hop — under the project's MainActor default isolation a plain
    // `static let` would otherwise be inferred main-actor isolated.
    nonisolated static let shared = SpeciesCatalog()

    struct Species: Hashable, Sendable {
        let scientificName: String
        let commonName: String
        /// Precomputed `"<common> <scientific>"` lowercased, used as the
        /// matching haystack so the search loop doesn't re-allocate per
        /// keystroke per row.
        let searchHay: String
    }

    let all: [Species]

    /// Maps a scientific name to its index in `all` — which is the same index
    /// the geo range filter uses (both derive from the BirdNET labels file in
    /// the same order). Lets the life list ask "is this species in range?"
    /// against `SpeciesRangeFilter`'s cached allowed-index set.
    let indexByScientificName: [String: Int]

    /// eBird's species code for each entry of `all`, by index — "carwre" for
    /// Carolina Wren. From `BirdNET_GLOBAL_6K_V2.4_eBirdCodes.txt`, one code
    /// per line in the labels file's order, generated from BirdNET-Analyzer's
    /// `eBird_taxonomy_codes_2024E.json`. Empty if the file is missing.
    private let eBirdCodes: [String]

    private init() {
        self.eBirdCodes = Bundle.main.url(
            forResource: "BirdNET_GLOBAL_6K_V2.4_eBirdCodes",
            withExtension: "txt"
        )
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map { $0.split(whereSeparator: { $0.isNewline }).map(String.init) } ?? []
        guard
            let url = Bundle.main.url(
                forResource: "BirdNET_GLOBAL_6K_V2.4_Labels",
                withExtension: "txt"
            ),
            let raw = try? String(contentsOf: url, encoding: .utf8)
        else {
            self.all = []
            self.indexByScientificName = [:]
            return
        }
        self.all = raw.split(whereSeparator: { $0.isNewline }).map { line in
            let parts = line.split(separator: "_", maxSplits: 1).map(String.init)
            let sci = parts.first ?? String(line)
            let com = parts.count == 2 ? parts[1] : sci
            return Species(
                scientificName: sci,
                commonName: com,
                searchHay: "\(com) \(sci)".lowercased()
            )
        }
        var index: [String: Int] = [:]
        index.reserveCapacity(all.count)
        for (i, sp) in all.enumerated() { index[sp.scientificName] = i }
        self.indexByScientificName = index
    }

    /// Common name for a scientific name, or nil if it isn't in the catalog
    /// (e.g. a life-list entry recorded under an older taxonomic name).
    func commonName(for scientificName: String) -> String? {
        guard let i = indexByScientificName[scientificName] else { return nil }
        return all[i].commonName
    }

    /// eBird's species code for a bird, for linking to its pages on eBird.
    /// Found by scientific name, then through `TaxonomyAliases` for a name
    /// eBird has since changed, then by common name. `nil` for the labels
    /// file's noise and human classes, which have no eBird page.
    func eBirdCode(scientificName: String, commonName: String? = nil) -> String? {
        let index = indexByScientificName[scientificName]
            ?? TaxonomyAliases.ebirdToBirdNET[scientificName].flatMap { indexByScientificName[$0] }
            ?? commonName.flatMap { name in
                all.firstIndex { $0.commonName.caseInsensitiveCompare(name) == .orderedSame }
            }
        guard let index, eBirdCodes.indices.contains(index),
              !BirdNETClassifier.nonBirdLabels.contains(all[index].scientificName)
        else { return nil }
        return eBirdCodes[index]
    }
}
