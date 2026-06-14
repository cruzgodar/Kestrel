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
    func add(
        scientificName: String,
        commonName: String,
        location: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> Bool {
        guard !entries.contains(where: { $0.scientificName == scientificName }) else {
            return false
        }
        let entry = LifeListEntry(
            scientificName: scientificName,
            commonName: commonName,
            firstSeen: Date(),
            firstLocation: location,
            firstLatitude: latitude,
            firstLongitude: longitude
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

    /// Back-fills the first-seen coordinate on an existing entry. Used by
    /// the manual-add flows when the device hadn't yet resolved a location
    /// at the moment of the tap; the resolved fix arrives shortly after via
    /// `LocationCache.current()` and is written here.
    func updateFirstLocation(scientificName: String, latitude: Double, longitude: Double) {
        guard let idx = entries.firstIndex(where: { $0.scientificName == scientificName }) else {
            return
        }
        entries[idx].firstLatitude = latitude
        entries[idx].firstLongitude = longitude
        save()
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

    func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        save()
    }

    private func merge(rows: [EBirdRawRow]) -> ImportSummary {
        var map: [String: LifeListEntry] = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.scientificName, $0) }
        )
        // Species already on the life list before this import began. The
        // counts below are tracked as distinct-species sets keyed off this,
        // so multiple CSV rows for the same species (every sighting is its
        // own row) don't inflate the "already known" tally — and a fresh
        // import into an empty list reports zero already-known.
        let originalKeys = Set(entries.map(\.scientificName))
        var addedKeys: Set<String> = []
        var updatedKeys: Set<String> = []
        var knownKeys: Set<String> = []

        for row in rows {
            if originalKeys.contains(row.scientificName) {
                knownKeys.insert(row.scientificName)
            } else if map[row.scientificName] != nil {
                // Already added earlier in this same import — a duplicate CSV
                // row for a brand-new species. Counted once via addedKeys.
                addedKeys.insert(row.scientificName)
            }
            if let existing = map[row.scientificName] {
                var copy = existing
                var changed = false
                if row.date < existing.firstSeen {
                    copy.firstSeen = row.date
                    copy.firstLocation = row.location
                    copy.firstLatitude = row.latitude
                    copy.firstLongitude = row.longitude
                    copy.commonName = row.commonName
                    changed = true
                } else if row.date == existing.firstSeen {
                    // Same earliest-seen date: fill in any field the
                    // existing entry is missing. Coords stay tied to the
                    // earliest sighting; this just heals entries that
                    // pre-date coord tracking (the previous import didn't
                    // read Latitude/Longitude) so the matching row in the
                    // CSV would otherwise be skipped outright.
                    if copy.firstLocation == nil, let loc = row.location {
                        copy.firstLocation = loc
                        changed = true
                    }
                    if copy.firstLatitude == nil, let lat = row.latitude {
                        copy.firstLatitude = lat
                        changed = true
                    }
                    if copy.firstLongitude == nil, let lon = row.longitude {
                        copy.firstLongitude = lon
                        changed = true
                    }
                }
                if changed {
                    map[row.scientificName] = copy
                    if originalKeys.contains(row.scientificName) {
                        updatedKeys.insert(row.scientificName)
                    }
                }
            } else {
                map[row.scientificName] = LifeListEntry(
                    scientificName: row.scientificName,
                    commonName: row.commonName,
                    firstSeen: row.date,
                    firstLocation: row.location,
                    firstLatitude: row.latitude,
                    firstLongitude: row.longitude
                )
                addedKeys.insert(row.scientificName)
            }
        }

        // "Already known" = pre-existing species the import touched but didn't
        // change. Updated ones are reported separately, so subtract them out.
        let added = addedKeys.count
        let updated = updatedKeys.count
        let skipped = knownKeys.subtracting(updatedKeys).count

        // Canonicalize the same way `load()` does so freshly imported entries
        // pick up BirdNET-canonical scientific names immediately — otherwise an
        // eBird name like "Astur cooperii" (Cooper's Hawk) or "Spilopelia
        // chinensis" (Spotted Dove) would slug to a missing image and show the
        // placeholder until the next launch.
        entries = Self.canonicalize(Array(map.values)).sorted { $0.firstSeen > $1.firstSeen }
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
            let collapsed = Self.canonicalize(decoded)
            entries = collapsed.sorted { $0.firstSeen > $1.firstSeen }
            // Persist if anything actually changed — either rows merged or a
            // scientific name was rewritten to its catalog-canonical form.
            let mutated = collapsed.count != decoded.count
                || zip(
                    decoded.sorted { $0.scientificName < $1.scientificName },
                    collapsed.sorted { $0.scientificName < $1.scientificName }
                ).contains { $0.scientificName != $1.scientificName }
            if mutated {
                save()
            }
        } catch {
            print("LifeListStore: load failed — \(error)")
        }
    }

    /// Full canonicalization pipeline shared by `load()` and the import
    /// `merge()`: rewrite stale eBird scientific names through the alias table,
    /// collapse trinomial subspecies into their binomial, then collapse
    /// same-common-name synonyms onto the BirdNET-canonical scientific name so
    /// image-slug and detection lookups resolve to the bundled assets.
    private static func canonicalize(_ entries: [LifeListEntry]) -> [LifeListEntry] {
        collapseByCommonName(collapseToSpecies(applyAliases(entries)))
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
                        firstLatitude: copy.firstLatitude,
                        firstLongitude: copy.firstLongitude,
                        isStarred: copy.isStarred
                    )
                }
                byBinomial[key] = copy
                continue
            }
            // Earlier sighting wins firstSeen + firstLocation + coords.
            let useNew = entry.firstSeen < existing.firstSeen
            let firstSeen = useNew ? entry.firstSeen : existing.firstSeen
            let firstLocation = useNew ? entry.firstLocation : existing.firstLocation
            let firstLatitude = useNew ? entry.firstLatitude : existing.firstLatitude
            let firstLongitude = useNew ? entry.firstLongitude : existing.firstLongitude
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
                firstLatitude: firstLatitude,
                firstLongitude: firstLongitude,
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
        // Lowercased common name → catalog scientific name. Used to rewrite
        // singleton entries whose stored scientific name is a stale synonym
        // (e.g. "Leuconotopicus villosus" → "Dryobates villosus"), so the
        // image-slug lookup matches the bundled file.
        let catalogByCommon: [String: String] = Dictionary(
            SpeciesCatalog.shared.all.map { ($0.commonName.lowercased(), $0.scientificName) },
            uniquingKeysWith: { first, _ in first }
        )
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
            let firstLatitude = useNew ? entry.firstLatitude : existing.firstLatitude
            let firstLongitude = useNew ? entry.firstLongitude : existing.firstLongitude
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
                firstLatitude: firstLatitude,
                firstLongitude: firstLongitude,
                isStarred: existing.isStarred || entry.isStarred
            )
        }
        // Final pass: rewrite singletons whose scientific name doesn't exist
        // in the catalog but whose common name does. This is the path that
        // fixes a lone Hairy Woodpecker entry stored under the old genus
        // (Leuconotopicus villosus) — the multi-entry merge above only fires
        // when there are two rows to collide.
        return byCommon.values.map { entry in
            if catalogNames.contains(entry.scientificName) { return entry }
            guard let canonical = catalogByCommon[entry.commonName.lowercased()] else {
                return entry
            }
            return LifeListEntry(
                scientificName: canonical,
                commonName: entry.commonName,
                firstSeen: entry.firstSeen,
                firstLocation: entry.firstLocation,
                firstLatitude: entry.firstLatitude,
                firstLongitude: entry.firstLongitude,
                isStarred: entry.isStarred
            )
        }
    }

    /// First-pass migration: rewrite scientific names through the alias
    /// table so downstream collapses and image lookups see the BirdNET
    /// canonical form. Handles cases like "Setophaga aestiva" (eBird's
    /// post-split Northern Yellow Warbler) → "Setophaga petechia" (BirdNET's
    /// Yellow Warbler) where neither the sci nor common name matches the
    /// catalog directly.
    private static func applyAliases(_ entries: [LifeListEntry]) -> [LifeListEntry] {
        entries.map { entry in
            let canonical = TaxonomyAliases.canonical(entry.scientificName)
            guard canonical != entry.scientificName else { return entry }
            return LifeListEntry(
                scientificName: canonical,
                commonName: entry.commonName,
                firstSeen: entry.firstSeen,
                firstLocation: entry.firstLocation,
                firstLatitude: entry.firstLatitude,
                firstLongitude: entry.firstLongitude,
                isStarred: entry.isStarred
            )
        }
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
