import Foundation

/// Read-only directory of every species BirdNET can recognize. Loaded once
/// at first access from the same labels file the classifier uses, with a
/// precomputed lowercase haystack per species so search is cheap.
///
/// `Sendable` + non-isolated so the suggestion-scoring loop can run on a
/// detached task without bouncing through the main actor per species.
final class SpeciesCatalog: @unchecked Sendable {
    static let shared = SpeciesCatalog()

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

    private init() {
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
}
