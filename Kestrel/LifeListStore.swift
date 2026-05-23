import Foundation
import Observation

@Observable
@MainActor
final class LifeListStore {
    struct ImportSummary {
        let added: Int
        let updated: Int
        let skipped: Int
    }

    private(set) var entries: [LifeListEntry] = []

    init() {
        load()
    }

    /// Reads the CSV at `url`, parses it as an eBird export, and merges into the life list.
    /// Caller is responsible for `startAccessingSecurityScopedResource()` if needed.
    func importEBird(from url: URL) async throws -> ImportSummary {
        let data = try Data(contentsOf: url)
        let rows = try EBirdCSVParser.parse(data)
        return merge(rows: rows)
    }

    /// Adds a single species to the life list with `now` as the first-seen
    /// date. No-op if the species is already in the list. Used by the
    /// Identify tab's "swipe to add" gesture on detected birds.
    @discardableResult
    func add(scientificName: String, commonName: String, location: String? = nil) -> Bool {
        guard !entries.contains(where: { $0.scientificName == scientificName }) else {
            return false
        }
        let entry = LifeListEntry(
            scientificName: scientificName,
            commonName: commonName,
            firstSeen: Date(),
            firstLocation: location
        )
        entries.append(entry)
        entries.sort { $0.firstSeen > $1.firstSeen }
        save()
        return true
    }

    /// Quick membership check by scientific name.
    func contains(scientificName: String) -> Bool {
        entries.contains(where: { $0.scientificName == scientificName })
    }

    /// Sets or clears the "alert me" star on an existing entry.
    func setStarred(scientificName: String, isStarred: Bool) {
        guard let idx = entries.firstIndex(where: { $0.scientificName == scientificName }),
              entries[idx].isStarred != isStarred else { return }
        entries[idx].isStarred = isStarred
        save()
    }

    /// Scientific names of every starred entry. Recomputed on access — cheap
    /// at life-list sizes and saves us from having to keep a side cache in sync.
    var starredNames: Set<String> {
        Set(entries.lazy.filter(\.isStarred).map(\.scientificName))
    }

    /// Removes a species from the life list. No-op if it isn't present.
    func remove(scientificName: String) {
        guard let idx = entries.firstIndex(where: { $0.scientificName == scientificName }) else {
            return
        }
        entries.remove(at: idx)
        save()
    }

    private func merge(rows: [EBirdRawRow]) -> ImportSummary {
        var map: [String: LifeListEntry] = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.scientificName, $0) }
        )
        var added = 0
        var updated = 0
        var skipped = 0

        for row in rows {
            if let existing = map[row.scientificName] {
                if row.date < existing.firstSeen {
                    var copy = existing
                    copy.firstSeen = row.date
                    copy.firstLocation = row.location
                    copy.commonName = row.commonName
                    map[row.scientificName] = copy
                    updated += 1
                } else {
                    skipped += 1
                }
            } else {
                map[row.scientificName] = LifeListEntry(
                    scientificName: row.scientificName,
                    commonName: row.commonName,
                    firstSeen: row.date,
                    firstLocation: row.location
                )
                added += 1
            }
        }

        entries = map.values.sorted { $0.firstSeen > $1.firstSeen }
        save()
        return ImportSummary(added: added, updated: updated, skipped: skipped)
    }

    // MARK: Persistence

    private static func storeURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("life_list.json")
    }

    private func load() {
        do {
            let url = try Self.storeURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([LifeListEntry].self, from: data)
            let collapsed = Self.collapseByCommonName(Self.collapseToSpecies(decoded))
            entries = collapsed.sorted { $0.firstSeen > $1.firstSeen }
            // If collapsing actually merged rows, persist the cleaned-up list
            // so we don't redo the work on every launch.
            if collapsed.count != decoded.count {
                save()
            }
        } catch {
            print("LifeListStore: load failed — \(error)")
        }
    }

    /// Merge entries whose scientific names differ only in a trinomial subspecies
    /// token (e.g. "Dryobates villosus villosus" + "Dryobates villosus harrisi" →
    /// "Dryobates villosus"). Keeps the earliest first-seen date, OR-merges the
    /// star flag, and prefers a parenthetical-free common name when picking which
    /// row's display fields to keep.
    private static func collapseToSpecies(_ entries: [LifeListEntry]) -> [LifeListEntry] {
        var byBinomial: [String: LifeListEntry] = [:]
        for entry in entries {
            let key = speciesBinomial(entry.scientificName)
            guard let existing = byBinomial[key] else {
                var copy = entry
                if copy.scientificName != key {
                    copy = LifeListEntry(
                        scientificName: key,
                        commonName: copy.commonName,
                        firstSeen: copy.firstSeen,
                        firstLocation: copy.firstLocation,
                        isStarred: copy.isStarred
                    )
                }
                byBinomial[key] = copy
                continue
            }
            // Earlier sighting wins firstSeen + firstLocation.
            let useNew = entry.firstSeen < existing.firstSeen
            let firstSeen = useNew ? entry.firstSeen : existing.firstSeen
            let firstLocation = useNew ? entry.firstLocation : existing.firstLocation
            // Prefer a common name without a parenthetical clarifier.
            let existingHasParen = existing.commonName.contains("(")
            let candidateHasParen = entry.commonName.contains("(")
            let commonName: String
            if existingHasParen && !candidateHasParen {
                commonName = entry.commonName
            } else {
                commonName = existing.commonName
            }
            byBinomial[key] = LifeListEntry(
                scientificName: key,
                commonName: commonName,
                firstSeen: firstSeen,
                firstLocation: firstLocation,
                isStarred: existing.isStarred || entry.isStarred
            )
        }
        return Array(byBinomial.values)
    }

    /// Second-pass merge: collapse entries that share the same common name but
    /// have different scientific names — this catches taxonomic revisions where
    /// a species moved genera (e.g. "Leuconotopicus villosus" → "Dryobates villosus"
    /// for Hairy Woodpecker). Prefers the scientific name that matches BirdNET's
    /// catalog so detection-driven lookups resolve to the canonical entry.
    private static func collapseByCommonName(_ entries: [LifeListEntry]) -> [LifeListEntry] {
        let catalogNames: Set<String> = Set(SpeciesCatalog.shared.all.map(\.scientificName))
        var byCommon: [String: LifeListEntry] = [:]
        for entry in entries {
            let key = entry.commonName.lowercased()
            guard let existing = byCommon[key] else {
                byCommon[key] = entry
                continue
            }
            let useNew = entry.firstSeen < existing.firstSeen
            let firstSeen = useNew ? entry.firstSeen : existing.firstSeen
            let firstLocation = useNew ? entry.firstLocation : existing.firstLocation
            // Prefer the scientific name BirdNET emits so detections map to this row.
            let existingInCatalog = catalogNames.contains(existing.scientificName)
            let candidateInCatalog = catalogNames.contains(entry.scientificName)
            let scientificName: String
            if candidateInCatalog && !existingInCatalog {
                scientificName = entry.scientificName
            } else {
                scientificName = existing.scientificName
            }
            byCommon[key] = LifeListEntry(
                scientificName: scientificName,
                commonName: existing.commonName,
                firstSeen: firstSeen,
                firstLocation: firstLocation,
                isStarred: existing.isStarred || entry.isStarred
            )
        }
        return Array(byCommon.values)
    }

    private static func speciesBinomial(_ s: String) -> String {
        let parts = s.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2 else { return s }
        return "\(parts[0]) \(parts[1])"
    }

    private func save() {
        do {
            let url = try Self.storeURL()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            print("LifeListStore: save failed — \(error)")
        }
    }
}
