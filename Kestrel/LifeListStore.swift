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

    /// Deterministic "newest first" ordering with a stable tiebreaker, mirroring
    /// the map's `BirdCluster.ordersBefore`: most-recent `firstSeen` first, then
    /// scientific name ascending so entries sharing an exact timestamp (e.g. a
    /// batch import that stamps them all at once) always land in the same order.
    /// `Array.sort` isn't guaranteed stable on equal keys, so without the
    /// tiebreaker same-date rows could shuffle between recomputations.
    nonisolated static func ordersBefore(_ a: LifeListEntry, _ b: LifeListEntry) -> Bool {
        if a.firstSeen != b.firstSeen { return a.firstSeen > b.firstSeen }
        return a.scientificName < b.scientificName
    }

    /// Authoritative set of starred ("alert me") scientific names, persisted
    /// *separately* from the life list (see `starsURL`). Keeping it independent
    /// of `entries` is what lets stars survive a wipe-and-reimport: clearing the
    /// life list leaves this set untouched, and `load`/`merge` re-stamp the
    /// matching entries from it. Each `LifeListEntry.isStarred` is kept in sync
    /// with this set for the UI; this set is the source of truth.
    private(set) var starredNames: Set<String> = []

    init() {
        if let saved = Self.loadStars() {
            starredNames = saved
            load()
            // Re-stamp entries from the authoritative set (their decoded flags
            // may be stale relative to it).
            applyStarsToEntries()
        } else {
            // First run after this feature shipped: no separate stars file yet.
            // Seed it from whatever stars the entries already carry, then it
            // becomes the source of truth going forward.
            load()
            starredNames = Set(entries.lazy.filter(\.isStarred).map(\.scientificName))
            saveStars()
        }
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
        entries.sort(by: Self.ordersBefore)
        save()
        return true
    }

    /// Quick membership check by scientific name.
    func contains(scientificName: String) -> Bool {
        entries.contains(where: { $0.scientificName == scientificName })
    }

    /// Coordinate of the earliest recorded sighting of a species, if it's on
    /// the life list and that sighting carries coordinates. Drives the
    /// full-screen photo viewer's "Show on Map" button — returns `nil` when the
    /// species has never been seen (so the button is hidden) or was logged
    /// without a location.
    func firstObservationCoordinate(for scientificName: String) -> (latitude: Double, longitude: Double)? {
        guard let entry = entries.first(where: { $0.scientificName == scientificName }),
              let lat = entry.firstLatitude, let lon = entry.firstLongitude else {
            return nil
        }
        return (lat, lon)
    }

    /// The displayed place name + date of the earliest recorded sighting of a
    /// species, if it's on the life list. Drives the full-screen photo viewer's
    /// observation section when a photo is opened from the Life List tab (which
    /// always shows the earliest sighting). `nil` for species not on the list
    /// (non-lifers), which have no recorded sighting to show.
    func firstObservation(for scientificName: String) -> (location: String?, date: Date)? {
        guard let entry = entries.first(where: { $0.scientificName == scientificName }) else {
            return nil
        }
        return (entry.firstLocation, entry.firstSeen)
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

    /// Sets or clears the "alert me" star. Writes through to the persistent
    /// `starredNames` set (so it survives a wipe-and-reimport) and mirrors the
    /// flag onto the entry, if present, for the UI.
    func setStarred(scientificName: String, isStarred: Bool) {
        let setChanged: Bool
        if isStarred {
            setChanged = starredNames.insert(scientificName).inserted
        } else {
            setChanged = starredNames.remove(scientificName) != nil
        }
        if setChanged { saveStars() }

        if let idx = entries.firstIndex(where: { $0.scientificName == scientificName }),
           entries[idx].isStarred != isStarred {
            entries[idx].isStarred = isStarred
            save()
        }
    }

    /// Re-stamps every entry's `isStarred` flag from the authoritative
    /// `starredNames` set, persisting the life list only if anything changed.
    private func applyStarsToEntries() {
        var changed = false
        for i in entries.indices {
            let want = starredNames.contains(entries[i].scientificName)
            if entries[i].isStarred != want {
                entries[i].isStarred = want
                changed = true
            }
        }
        if changed { save() }
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
        // Accumulate the *full* observation set per species — every CSV row is
        // kept, not just the earliest. Seeded from the existing entries' own
        // observations so a re-import folds new sightings in alongside the old.
        var observationsBySci: [String: [LifeListEntry.Observation]] = [:]
        // Common name tracked at its earliest-seen date so an earlier row can
        // override it, matching the old "earliest sighting wins display fields"
        // behavior.
        var commonBySci: [String: (name: String, date: Date)] = [:]
        var starredBySci: [String: Bool] = [:]
        for e in entries {
            observationsBySci[e.scientificName] = e.allObservations
            commonBySci[e.scientificName] = (e.commonName, e.firstSeen)
            starredBySci[e.scientificName] = e.isStarred
        }

        // Species already on the life list before this import began, and a
        // snapshot of their displayed fields so we can tell afterward which
        // ones the import actually changed (= "updated") vs. merely re-stated
        // (= "already known"). Keyed by scientific name; multiple CSV rows for
        // one species collapse into a single tally.
        let originalKeys = Set(entries.map(\.scientificName))
        let originalBySci: [String: LifeListEntry] = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.scientificName, $0) }
        )
        var knownKeys: Set<String> = []

        for row in rows {
            let sci = row.scientificName
            if originalKeys.contains(sci) { knownKeys.insert(sci) }
            observationsBySci[sci, default: []].append(
                LifeListEntry.Observation(
                    date: row.date,
                    location: row.location,
                    latitude: row.latitude,
                    longitude: row.longitude
                )
            )
            if let existing = commonBySci[sci] {
                if row.date < existing.date { commonBySci[sci] = (row.commonName, row.date) }
            } else {
                commonBySci[sci] = (row.commonName, row.date)
            }
            if starredBySci[sci] == nil { starredBySci[sci] = false }
        }

        // Reconstitute one entry per species from its full observation set —
        // `make` promotes the earliest to the displayed fields and parks the
        // rest in `otherObservations`.
        let prelim = observationsBySci.map { sci, observations in
            LifeListEntry.make(
                scientificName: sci,
                commonName: commonBySci[sci]?.name ?? sci,
                isStarred: starredBySci[sci] ?? false,
                observations: observations
            )
        }
        let prelimBySci = Dictionary(uniqueKeysWithValues: prelim.map { ($0.scientificName, $0) })

        // Counts mirror the previous behavior: a brand-new species is "added";
        // a pre-existing one whose displayed earliest sighting shifted (earlier
        // date, or a healed location/coordinate) is "updated"; the rest of the
        // touched pre-existing species are "already known". Computed on the
        // pre-canonicalization keys, which the parser has already reduced to
        // BirdNET-canonical binomials.
        var updatedKeys: Set<String> = []
        for sci in knownKeys {
            guard let before = originalBySci[sci], let after = prelimBySci[sci] else { continue }
            if before.firstSeen != after.firstSeen
                || before.firstLocation != after.firstLocation
                || before.firstLatitude != after.firstLatitude
                || before.firstLongitude != after.firstLongitude {
                updatedKeys.insert(sci)
            }
        }
        let added = Set(observationsBySci.keys).subtracting(originalKeys).count
        let updated = updatedKeys.count
        let skipped = knownKeys.subtracting(updatedKeys).count

        // Canonicalize the same way `load()` does so freshly imported entries
        // pick up BirdNET-canonical scientific names immediately — otherwise an
        // eBird name like "Astur cooperii" (Cooper's Hawk) or "Spilopelia
        // chinensis" (Spotted Dove) would slug to a missing image and show the
        // placeholder until the next launch.
        entries = Self.canonicalize(prelim).sorted(by: Self.ordersBefore)
        // Re-stamp stars from the persistent set so a wipe-and-reimport (or any
        // import) restores the user's "alert me" choices even though the cleared
        // entries no longer carried them.
        applyStarsToEntries()
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

    /// Separate file for the starred ("alert me") set, intentionally decoupled
    /// from `life_list.json` so the stars outlive a wipe-and-reimport.
    private static func starsURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("starred_species.json")
    }

    /// Loads the persisted star set. Returns `nil` (not empty) when the file
    /// has never been written, so `init` can tell "no stars" apart from
    /// "pre-feature install, migrate from the entries."
    private static func loadStars() -> Set<String>? {
        do {
            let url = try starsURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Set<String>.self, from: data)
        } catch {
            print("LifeListStore: stars load failed — \(error)")
            return nil
        }
    }

    private func saveStars() {
        do {
            let url = try Self.starsURL()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(starredNames.sorted())
            try data.write(to: url, options: .atomic)
        } catch {
            print("LifeListStore: stars save failed — \(error)")
        }
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
            entries = collapsed.sorted(by: Self.ordersBefore)
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
                // Rebuild via `make` so the binomial rename carries the full
                // observation set (and earliest-sighting promotion) intact.
                byBinomial[key] = LifeListEntry.make(
                    scientificName: key,
                    commonName: entry.commonName,
                    isStarred: entry.isStarred,
                    observations: entry.allObservations
                )
                continue
            }
            // Prefer a common name without a parenthetical clarifier.
            let existingHasParen = existing.commonName.contains("(")
            let candidateHasParen = entry.commonName.contains("(")
            let commonName = (existingHasParen && !candidateHasParen) ? entry.commonName : existing.commonName
            // Union both rows' observations; `make` re-picks the earliest as
            // the displayed sighting and keeps the rest.
            byBinomial[key] = LifeListEntry.make(
                scientificName: key,
                commonName: commonName,
                isStarred: existing.isStarred || entry.isStarred,
                observations: existing.allObservations + entry.allObservations
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
            // Prefer the scientific name BirdNET emits so detections map to this row.
            let existingInCatalog = catalogNames.contains(existing.scientificName)
            let candidateInCatalog = catalogNames.contains(entry.scientificName)
            let scientificName: String
            if candidateInCatalog && !existingInCatalog {
                scientificName = entry.scientificName
            } else {
                scientificName = existing.scientificName
            }
            byCommon[key] = LifeListEntry.make(
                scientificName: scientificName,
                commonName: existing.commonName,
                isStarred: existing.isStarred || entry.isStarred,
                observations: existing.allObservations + entry.allObservations
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
            return LifeListEntry.make(
                scientificName: canonical,
                commonName: entry.commonName,
                isStarred: entry.isStarred,
                observations: entry.allObservations
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
            return LifeListEntry.make(
                scientificName: canonical,
                commonName: entry.commonName,
                isStarred: entry.isStarred,
                observations: entry.allObservations
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
