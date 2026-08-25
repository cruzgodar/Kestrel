import CoreLocation
import Foundation
import Observation

@Observable
@MainActor
final class LifeListStore {
    /// What an import actually did, split finely enough that the summary can
    /// state it without overstating it.
    ///
    /// "Gained sightings" and "had its earliest sighting replaced" were one
    /// bucket (`updated`) and are now two, because the summary needs them apart.
    /// Reporting `added + updated` as the species behind `newObservations`
    /// counted species that gained nothing, and a species whose first-seen date
    /// moved but gained no rows left `newObservations` at zero — which
    /// suppressed the whole clause and reported "Nothing new to import" over an
    /// import that had just rewritten the user's first-seen data.
    nonisolated struct ImportSummary {
        /// Species that weren't on the life list before this import.
        let added: Int
        /// Species already on the list that gained at least one sighting.
        let gained: Int
        /// Species already on the list whose displayed first sighting was
        /// displaced by an earlier one, *without* gaining any sightings.
        let revised: Int
        /// Species the CSV mentioned that it had nothing new to say about.
        let skipped: Int
        /// Sightings written across all of the above. Counted because a re-import
        /// of a CSV that has gone on accumulating is overwhelmingly *new
        /// observations of species you already have* — which the species-level
        /// tallies alone report as "already known", so the summary read as though
        /// nothing had happened while the map quietly grew pins.
        let newObservations: Int

        /// The species `newObservations` were spread across: the ones new to the
        /// list plus the ones that grew. Never counts a species that only had its
        /// earliest sighting revised, which contributed no rows.
        var speciesWithNewObservations: Int { added + gained }
    }

    private(set) var entries: [LifeListEntry] = []

    /// Scientific names of every species currently on the list, kept in step
    /// with `entries` by `refreshSpeciesNames()`.
    ///
    /// Maintained rather than derived on demand because the hot readers want an
    /// O(1) membership test and are called often: `RecordingManager.merge` asks
    /// once per detection window (on the audio path, where rebuilding a set of a
    /// few thousand strings every three seconds is real work), and the Life List
    /// re-asks on every render while searching.
    ///
    /// Refreshed only where membership can actually change — an add, a delete
    /// that took a species' last sighting, an import, a load, a wipe. Filing or
    /// editing an observation under a species already on the list doesn't move
    /// it, and neither does a star toggle, so those paths don't pay for it.
    private(set) var speciesNames: Set<String> = []

    private func refreshSpeciesNames() {
        speciesNames = Set(entries.lazy.map(\.scientificName))
    }

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

    /// Identity keys (see `EBirdCSVExporter.key`) of every observation that has
    /// already been written into an eBird export file. Persisted separately
    /// from the life list, like `starredNames`, so it survives a
    /// wipe-and-reimport — re-importing a CSV you already sent to eBird must not
    /// make those sightings look new again.
    ///
    /// This set exists because eBird's import tool does **no** deduplication:
    /// uploading the same records twice creates a second set of checklists.
    /// Remembering what has been handed over is the only way to let someone
    /// export repeatedly without duplicating their history.
    ///
    /// Keys are only ever added, never pruned — not when the sighting they
    /// describe is edited into a different key, deleted, or wiped by "Delete All
    /// Entries". This is intended. The key describes a *record eBird now holds*,
    /// not a row Kestrel still stores, and that stays true however the local copy
    /// changes; a sighting that reproduces a retired key is, by the key's own
    /// definition, an exact copy of something already uploaded, and sending it
    /// again would duplicate it on eBird's side. Anyone who does want the whole
    /// list written out regardless has "Export All Observations", which ignores
    /// this ledger entirely.
    private(set) var exportedObservationKeys: Set<String> = []

    /// Which observations an export should cover.
    nonisolated enum ExportScope {
        /// Only sightings eBird can't already have: recorded in Kestrel rather
        /// than imported from an eBird CSV, and not covered by a previous
        /// export. The safe choice for a repeat upload.
        case newOnly
        /// Every sighting on the life list, whatever its provenance and
        /// whether or not it has been exported before.
        case everything
    }

    /// Directory the three persisted files live in. Injected rather than fixed
    /// so a test can point a store at a scratch directory instead of the app's
    /// real container — without that, exercising load, migration, or persistence
    /// at all would mean reading and overwriting the running install's own life
    /// list.
    private let directory: URL?
    /// Where the one-shot date-migration flag lives, injected for the same
    /// reason: the flag is *once per install*, so a test that used the real
    /// defaults would consume the app's own migration and silently change what
    /// the next launch does.
    private let defaults: UserDefaults

    /// - Parameters:
    ///   - directory: `nil` (the default) means the app's Application Support
    ///     directory — the real store.
    ///   - defaults: `nil` (the default) means `UserDefaults.standard`.
    init(directory: URL? = nil, defaults: UserDefaults? = nil) {
        self.directory = directory ?? Self.applicationSupport()
        self.defaults = defaults ?? .standard
        if let saved = loadStars() {
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
        exportedObservationKeys = loadExportedKeys()
    }

    /// How many times an import will re-merge around a concurrent write before
    /// falling back to merging inline on the main actor. See `importEBird`.
    private static let maxImportMergeAttempts = 4

    /// Reads the CSV at `url`, parses it as an eBird export, and merges into the life list.
    /// Caller is responsible for `startAccessingSecurityScopedResource()` if needed.
    func importEBird(from url: URL) async throws -> ImportSummary {
        let data = try Data(contentsOf: url)
        // Parse + merge are CPU-heavy — a character-by-character CSV scan followed
        // by a full canonicalization pass against the ~6.5k-species catalog — so a
        // large eBird export would visibly freeze the UI if run inline on the main
        // actor (`async` alone doesn't move work off it). Parse once, then merge
        // on a detached task and apply only the cheap result back on main.
        let rows = try await Task.detached(priority: .userInitiated) {
            try EBirdCSVParser.parse(data)
        }.value

        // Moving the merge off the main actor is exactly what keeps the UI live
        // while a large import runs — which means the user can go on recording
        // sightings during it. A merge computed against a snapshot describes a
        // life list that no longer exists, and assigning it wholesale threw those
        // sightings away with no warning and no undo.
        //
        // So the snapshot is checked, and a merge that raced a write is redone
        // against what is actually there now. In the app this settles on the
        // first pass: a retry needs a write to land inside the re-merge itself,
        // and the add flow takes seconds of tapping to produce one.
        //
        // The last attempt runs **inline on the main actor**, where there is no
        // suspension point between reading `entries` and writing it back and so
        // nothing can interleave at all. That's what makes this terminate rather
        // than merely usually terminate — a caller writing faster than the merge
        // completes would otherwise retry forever. One brief hitch in a case that
        // shouldn't arise is a fair price for never silently dropping a record.
        let result: (entries: [LifeListEntry], summary: ImportSummary)
        var attempt = 1
        while true {
            let existing = entries
            guard attempt < Self.maxImportMergeAttempts else {
                result = Self.computeMergedEntries(rows: rows, existing: existing)
                break
            }
            let merged = await Task.detached(priority: .userInitiated) {
                Self.computeMergedEntries(rows: rows, existing: existing)
            }.value
            if entries == existing {
                result = merged
                break
            }
            Log.info("LifeListStore: life list changed during import, re-merging (attempt \(attempt))")
            attempt += 1
        }
        entries = result.entries
        refreshSpeciesNames()
        // Re-stamp stars from the persistent set so a wipe-and-reimport (or any
        // import) restores the user's "alert me" choices even though the cleared
        // entries no longer carried them.
        applyStarsToEntries()
        save()

        // Eagerly warm every imported species' photo right away rather than waiting
        // for its row to scroll into view. `prefetchWake` fetches the `thumb`
        // images first (so the list's small photos fill in fast), then the
        // medium images. Protect the freshly-grown life list from the cache cap
        // before prefetching (mirrors the launch wiring in `KestrelApp`).
        let names = entries.map(\.scientificName)
        RemoteSpeciesImageStore.shared.setProtectedSpecies(
            RemoteSpeciesImageStore.launchTargets(lifeList: names)
        )
        RemoteSpeciesImageStore.shared.prefetchWake(
            lifeList: names,
            nearby: RemoteSpeciesImageStore.nearbyNames()
        )

        return result.summary
    }

    // MARK: eBird export

    /// Every sighting on the life list, flattened into one row per observation
    /// and paired with its species. The unit of an eBird record is a single
    /// observation, not a species, so repeat sightings each get their own row.
    private var allExportRows: [EBirdCSVExporter.Row] {
        entries.flatMap { entry in
            entry.allObservations.map {
                EBirdCSVExporter.Row(
                    scientificName: entry.scientificName,
                    commonName: entry.commonName,
                    observation: $0
                )
            }
        }
    }

    /// The export ledger's key for one sighting. Wrapped so the export check and
    /// the edit path (which has to carry a key forward, see `replaceObservation`)
    /// can't drift apart on how a sighting is identified.
    private static func exportKey(
        scientificName: String,
        observation: LifeListEntry.Observation
    ) -> String {
        EBirdCSVExporter.key(scientificName: scientificName, observation: observation)
    }

    /// Whether a sighting belongs in a `.newOnly` export. Two ways eBird can
    /// already have it: it came *from* eBird on an import, or a previous export
    /// handed it over.
    private func isNewToEBird(_ row: EBirdCSVExporter.Row) -> Bool {
        guard !row.observation.isImported else { return false }
        return !hasBeenExported(
            scientificName: row.scientificName,
            observation: row.observation
        )
    }

    /// Whether the ledger already holds this sighting, under *either* key format.
    ///
    /// The place component of the key changed (see `EBirdCSVExporter.legacyKey`),
    /// and a ledger written by an earlier build is full of the old form. Nothing
    /// migrates it: this is the one piece of state whose loss can't be undone —
    /// eBird does no deduplication, so a key that stops matching means the user's
    /// next "Export New Observations" hands them a second copy of records they
    /// already uploaded. Reading both formats costs a set lookup and cannot fail.
    private func hasBeenExported(
        scientificName: String,
        observation: LifeListEntry.Observation
    ) -> Bool {
        let key = Self.exportKey(scientificName: scientificName, observation: observation)
        if exportedObservationKeys.contains(key) { return true }
        let legacy = EBirdCSVExporter.legacyKey(
            scientificName: scientificName,
            observation: observation
        )
        return exportedObservationKeys.contains(legacy)
    }

    /// Every recorded sighting on the life list, counted. A species contributes
    /// one per observation, not one flat — which is what "N observations" has to
    /// mean anywhere the user is told how much they are about to lose.
    var totalObservationCount: Int {
        entries.reduce(0) { $0 + 1 + $1.otherObservations.count }
    }

    /// How many rows an export of `scope` would produce. Drives the sheet's
    /// "nothing to export" check before any work starts.
    func observationCount(for scope: ExportScope) -> Int {
        switch scope {
        case .everything: return allExportRows.count
        case .newOnly:    return allExportRows.count(where: isNewToEBird)
        }
    }

    /// Builds the eBird Record Format CSV for `scope`, reporting completion
    /// through `progress` as it goes. Rendering runs on a detached task: a life
    /// list of any size is thousands of string joins, and doing that inline on
    /// the main actor would freeze the sheet mid-tap.
    ///
    /// Nothing is marked as exported here — the caller does that via
    /// `markExported` only after the file is actually saved, so a cancelled
    /// save panel doesn't quietly hide those sightings from the next export.
    func makeEBirdExport(
        scope: ExportScope,
        progress: ExportProgress? = nil
    ) async -> EBirdCSVExporter.Payload {
        let rows: [EBirdCSVExporter.Row]
        switch scope {
        case .everything:
            rows = allExportRows
        case .newOnly:
            rows = allExportRows.filter(isNewToEBird)
        }
        return await Task.detached(priority: .userInitiated) {
            EBirdCSVExporter.makeCSV(rows: rows) { done, total in
                guard let progress else { return }
                let fraction = total > 0 ? Double(done) / Double(total) : 1
                Task { @MainActor in progress.fraction = fraction }
            }
        }.value
    }

    /// Records that these observations are now in eBird's hands, so the next
    /// `.newOnly` export skips them. Call only on a successful save.
    func markExported(_ keys: Set<String>) {
        let before = exportedObservationKeys.count
        exportedObservationKeys.formUnion(keys)
        guard exportedObservationKeys.count != before else { return }
        saveExportedKeys()
    }

    /// Adds a single species to the life list. Defaults to today as the
    /// first-seen date; the add flow passes the date the user picked instead.
    /// No-op if the species is already in the list.
    ///
    /// Reached only through `recordObservation`: every add in the app runs the
    /// date → map → name flow first, so every sighting Kestrel records of
    /// its own carries a place name.
    ///
    /// `ObservationDate.today`, never `Date()`: a stored sighting is midnight UTC
    /// on the day it happened (see `ObservationDate`), and a default argument is
    /// exactly the kind of place a wall-clock instant slips in unnoticed — no
    /// caller has to opt into it for it to be wrong.
    @discardableResult
    func add(
        scientificName: String,
        commonName: String,
        firstSeen: Date = ObservationDate.today,
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
            firstSeen: firstSeen,
            firstLocation: location,
            firstLatitude: latitude,
            firstLongitude: longitude,
            // `starredNames` is the source of truth and outlives the entry: it
            // survives a wipe-and-reimport, a "Delete All Entries", and deleting
            // a species' last observation. Re-adding a bird that is still
            // starred therefore has to come back starred, or the row shows an
            // empty star while the classifier goes on alerting for it.
            isStarred: starredNames.contains(scientificName)
        )
        entries.append(entry)
        entries.sort(by: Self.ordersBefore)
        refreshSpeciesNames()
        save()
        return true
    }

    /// Records an *additional* sighting of a species already on the life list.
    /// The new observation is folded in with the existing ones via
    /// `LifeListEntry.make`, so an observation earlier than the current
    /// `firstSeen` is promoted to the displayed first-seen fields and the old
    /// one drops into `otherObservations`. Exact duplicates collapse, matching
    /// re-import behavior. No-op if the species isn't on the list — the Life
    /// List tab's add flow routes those through `add` instead.
    func addObservation(
        scientificName: String,
        date: Date,
        location: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        guard let idx = entries.firstIndex(where: { $0.scientificName == scientificName }) else {
            return
        }
        let existing = entries[idx]
        let added = LifeListEntry.Observation(
            date: date,
            location: location,
            latitude: latitude,
            longitude: longitude
        )
        entries[idx] = LifeListEntry.make(
            scientificName: existing.scientificName,
            commonName: existing.commonName,
            isStarred: existing.isStarred,
            observations: existing.allObservations + [added],
            // A sighting the user just recorded, never a merge of two sets of
            // records — so an exact repeat of one already on file is kept as a
            // second sighting rather than collapsed into the first.
            dedupe: false
        )
        // A promoted earlier sighting changes the entry's sort key.
        entries.sort(by: Self.ordersBefore)
        save()
    }

    /// The single write path for a manually recorded sighting: files it under
    /// the species' existing entry, or creates the entry when this is the first
    /// time it's been seen. Both tabs' add flows land here so the two can't
    /// drift apart on what "add" means.
    func recordObservation(
        scientificName: String,
        commonName: String,
        date: Date,
        location: String?,
        latitude: Double?,
        longitude: Double?
    ) {
        if contains(scientificName: scientificName) {
            addObservation(
                scientificName: scientificName,
                date: date,
                location: location,
                latitude: latitude,
                longitude: longitude
            )
        } else {
            add(
                scientificName: scientificName,
                commonName: commonName,
                firstSeen: date,
                location: location,
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    /// The place name of the nearest recorded observation to `coordinate`,
    /// within `meters`. Drives the naming step's default: a spot you've already
    /// named is almost certainly the same spot you're pinning again, and
    /// reusing your own wording beats a reverse-geocoded street address.
    /// Scans every observation of every species — the life list is at most a
    /// few thousand entries, so this stays well under a frame.
    func nearestObservationName(
        to coordinate: CLLocationCoordinate2D,
        within meters: CLLocationDistance
    ) -> String? {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var best: (distance: CLLocationDistance, name: String)?
        for entry in entries {
            for observation in entry.allObservations {
                guard let latitude = observation.latitude,
                      let longitude = observation.longitude,
                      let name = observation.location,
                      !name.isEmpty else { continue }
                let distance = target.distance(
                    from: CLLocation(latitude: latitude, longitude: longitude)
                )
                guard distance <= meters else { continue }
                if best == nil || distance < best!.distance {
                    best = (distance, name)
                }
            }
        }
        return best?.name
    }

    /// The common name the life list stores for a species, or `nil` when the
    /// species isn't on it. Prefer this over `SpeciesCatalog`'s name anywhere a
    /// recorded sighting is being named: an imported entry keeps eBird's wording,
    /// and a menu or confirmation that silently swapped in the catalog's would be
    /// naming a different bird than the row the user came from.
    func commonName(for scientificName: String) -> String? {
        entries.first(where: { $0.scientificName == scientificName })?.commonName
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

    /// Every recorded sighting of a species, newest first. Drives the pickers
    /// that ask *which* observation to act on — the full-screen viewer's
    /// observation list, and the Life List tab's edit/delete choosers — so all
    /// of them order and label sightings identically.  Empty for a species
    /// that isn't on the list.
    func observations(for scientificName: String) -> [LifeListEntry.Observation] {
        guard let entry = entries.first(where: { $0.scientificName == scientificName }) else {
            return []
        }
        return entry.allObservations.sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            return (a.location ?? "") < (b.location ?? "")
        }
    }

    /// Finds the stored sighting a user's edit or delete meant, in
    /// `allObservations` order. Exact value match first, `Identity` match only as
    /// a fallback.
    ///
    /// **Why both.** Two observations of one species are allowed to share an
    /// `Identity` — every path where the user writes a record passes
    /// `dedupe: false` to `LifeListEntry.make` precisely so an edit can't make
    /// one vanish by colliding with a sibling, and correcting an imported
    /// sighting's date onto a same-place neighbor's date produces exactly that
    /// collision. `Identity` deliberately excludes `isImported`, so a pair that
    /// collides that way can differ in provenance and in nothing else.
    ///
    /// Matching on identity alone took whichever of the pair came first, which
    /// is not the row the user swiped: editing the Kestrel-native one could
    /// resolve to the imported one and carry `isImported: true` onto the
    /// replacement, quietly dropping a genuine sighting out of "Export New
    /// Observations" — and deleting had the mirror problem, removing a record
    /// the user hadn't pointed at.
    ///
    /// The fallback still matters. The map builds its observations from
    /// `MapPoint`s, and the full-screen viewer from whatever it was opened with,
    /// so a caller can legitimately hold a value that differs from the stored one
    /// in a field identity ignores. Identity is the right answer there; it is
    /// only the wrong answer when an exact match was available and went unused.
    private nonisolated static func locate(
        _ observation: LifeListEntry.Observation,
        in observations: [LifeListEntry.Observation]
    ) -> Int? {
        observations.firstIndex(of: observation)
            ?? observations.firstIndex { $0.identity == observation.identity }
    }

    /// Rewrites one recorded sighting in place: the observation matching
    /// `original` is dropped and a new one with the given date/place takes its
    /// spot. The entry is rebuilt through `LifeListEntry.make`, so editing the
    /// earliest sighting to a later date correctly promotes whichever sighting
    /// is now earliest into the displayed `first*` fields.
    ///
    /// `isImported` rides along from the replaced observation: an edited eBird
    /// row still corresponds to a record that account already holds, so it must
    /// not start looking new to "Export New Observations."
    ///
    /// The export ledger entry rides along for the same reason. The ledger is
    /// keyed on the sighting's date, place, and coordinates (see
    /// `EBirdCSVExporter.key`), so correcting any of them would otherwise orphan
    /// the old key and make an already-uploaded sighting look new again — and
    /// eBird, which does no deduplication, would take the next export's copy as
    /// a second record rather than as a correction.
    ///
    /// Takes the whole `original` observation, not just its `Identity`, because
    /// identity is deliberately ambiguous here — see `locate`.
    func replaceObservation(
        scientificName: String,
        original: LifeListEntry.Observation,
        date: Date,
        location: String?,
        latitude: Double?,
        longitude: Double?
    ) {
        guard let idx = entries.firstIndex(where: { $0.scientificName == scientificName }) else {
            return
        }
        let existing = entries[idx]
        var remaining = existing.allObservations
        guard let hit = Self.locate(original, in: remaining) else { return }
        let wasImported = remaining[hit].isImported
        let wasExported = hasBeenExported(
            scientificName: scientificName,
            observation: remaining[hit]
        )
        remaining.remove(at: hit)
        let replacement = LifeListEntry.Observation(
            date: date,
            location: location,
            latitude: latitude,
            longitude: longitude,
            isImported: wasImported
        )
        remaining.append(replacement)
        if wasExported {
            markExported([
                Self.exportKey(scientificName: scientificName, observation: replacement)
            ])
        }
        entries[idx] = LifeListEntry.make(
            scientificName: existing.scientificName,
            commonName: existing.commonName,
            isStarred: existing.isStarred,
            observations: remaining,
            // Never dedupe an edit: the whole point of this call is to write
            // back what the user typed, and collapsing the result into a
            // same-identity sibling would make one of their records vanish.
            dedupe: false
        )
        // The edit may have moved the entry's earliest sighting, which is its
        // sort key.
        entries.sort(by: Self.ordersBefore)
        save()
    }

    /// Removes a single recorded sighting. The species itself drops off the
    /// life list when the sighting removed was its last one — a bird with no
    /// observations left is a bird that was never seen.
    ///
    /// Its star, deliberately, does *not* go with it. `starredNames` outlives
    /// every entry (see that property and `removeAll`), so a bird that leaves
    /// the list this way stays starred, keeps firing "alert me" notifications,
    /// and comes back starred if it is ever re-added. That is the intended
    /// trade: a star is a standing instruction about a species, not a property
    /// of one sighting, and losing it because the last record was deleted would
    /// be the more surprising outcome. The consequence to be aware of is that
    /// the star has no row to appear on while the species is off the list, it
    /// can only be cleared from the full-screen photo viewer's menu (which
    /// offers the star for any species, on the list or not) until the bird is
    /// recorded again.
    ///
    /// Takes the whole observation rather than just its `Identity` for the
    /// reason spelled out in `locate`.
    func removeObservation(
        scientificName: String,
        observation: LifeListEntry.Observation
    ) {
        guard let idx = entries.firstIndex(where: { $0.scientificName == scientificName }) else {
            return
        }
        let existing = entries[idx]
        var remaining = existing.allObservations
        guard let hit = Self.locate(observation, in: remaining) else { return }
        remaining.remove(at: hit)
        guard !remaining.isEmpty else {
            entries.remove(at: idx)
            refreshSpeciesNames()
            save()
            return
        }
        entries[idx] = LifeListEntry.make(
            scientificName: existing.scientificName,
            commonName: existing.commonName,
            isStarred: existing.isStarred,
            observations: remaining,
            // A delete must remove exactly one record and leave the rest alone.
            dedupe: false
        )
        entries.sort(by: Self.ordersBefore)
        save()
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        refreshSpeciesNames()
        save()
    }

    /// Pure merge: folds `rows` into `existing` and returns the canonicalized,
    /// sorted entry set plus the import tally. `nonisolated static` so the heavy
    /// work (full canonicalization against the ~6.5k-species catalog) can run off
    /// the main actor from `importEBird`. It does not touch instance state — the
    /// caller assigns the result, re-stamps stars, and saves on the main actor.
    private nonisolated static func computeMergedEntries(
        rows: [EBirdRawRow],
        existing: [LifeListEntry]
    ) -> (entries: [LifeListEntry], summary: ImportSummary) {
        // Accumulate the *full* observation set per species — every CSV row is
        // kept, not just the earliest. Seeded from the existing entries' own
        // observations so a re-import folds new sightings in alongside the old.
        var observationsBySci: [String: [LifeListEntry.Observation]] = [:]
        // Common name tracked at its earliest-seen date so an earlier row can
        // override it, matching the old "earliest sighting wins display fields"
        // behavior.
        var commonBySci: [String: (name: String, date: Date)] = [:]
        var starredBySci: [String: Bool] = [:]
        for e in existing {
            observationsBySci[e.scientificName] = e.allObservations
            commonBySci[e.scientificName] = (e.commonName, e.firstSeen)
            starredBySci[e.scientificName] = e.isStarred
        }

        // The life list as it stood before this import began, so the tally at the
        // bottom can say which species the import actually changed and how many
        // sightings it wrote.
        let originalBySci: [String: LifeListEntry] = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.scientificName, $0) }
        )
        // Every species the CSV said anything about, whether or not it was
        // already on the list. Only these can be reported as "already known" —
        // the rest of the life list is untouched and has nothing to report.
        var touchedKeys: Set<String> = []

        for row in rows {
            let sci = row.scientificName
            touchedKeys.insert(sci)
            observationsBySci[sci, default: []].append(
                LifeListEntry.Observation(
                    date: row.date,
                    location: row.location,
                    latitude: row.latitude,
                    longitude: row.longitude,
                    // Came from eBird, so the eBird export must not send it back.
                    isImported: true
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
                observations: observations,
                // Dedupe exactly the species this CSV said something about, and
                // no others.
                //
                // For a touched species `observations` really is two independent
                // record sets unioned — what was stored, plus this file's rows —
                // and collapsing the overlap is what keeps re-importing the same
                // export idempotent instead of doubling the user's history.
                //
                // For every *other* species on the list there is no second set:
                // `observations` is just what was already stored, rebuilt. Passing
                // `dedupe: true` there breaks this file's one rule (see
                // `canonicalize`) and silently drops records the user entered by
                // hand — two deliberate sightings of one bird at one spot became
                // one, because an import that never mentioned that bird happened
                // to run. Nothing warned them, and nothing could bring it back.
                dedupe: touchedKeys.contains(sci)
            )
        }
        // Canonicalize the same way `load()` does so freshly imported entries
        // pick up BirdNET-canonical scientific names immediately — otherwise an
        // eBird name like "Astur cooperii" (Cooper's Hawk) or "Spilopelia
        // chinensis" (Spotted Dove) would slug to a missing image and show the
        // placeholder until the next launch.
        let merged = Self.canonicalize(prelim).sorted(by: Self.ordersBefore)

        // The tally is measured against the *finished* set rather than against
        // the row names, because canonicalization can fold an eBird spelling onto
        // a species already on the list ("Astur cooperii" onto "Accipiter
        // cooperii"). Counting rows would report that as a species added when the
        // list didn't grow at all; comparing final entries to the ones we started
        // with gets it right without needing to know which names were rewritten.
        var added = 0
        var gained = 0
        var revised = 0
        var skipped = 0
        var newObservations = 0
        for entry in merged {
            guard let before = originalBySci[entry.scientificName] else {
                // New to the list: every sighting it carries is one we just wrote.
                added += 1
                newObservations += entry.allObservations.count
                continue
            }
            // Gaining sightings is the case that used to go unreported:
            // re-importing a CSV that has grown since last time files new rows
            // under species already on the list without touching their
            // first-seen fields, and every one of them was counted as "already
            // known" while the map quietly grew pins.
            let grew = entry.allObservations.count - before.allObservations.count
            let earliestChanged = before.firstSeen != entry.firstSeen
                || before.firstLocation != entry.firstLocation
                || before.firstLatitude != entry.firstLatitude
                || before.firstLongitude != entry.firstLongitude
            // Growing wins over a revised earliest when both happened: the
            // species is already accounted for by the "added N observations"
            // clause, and naming it twice would double-count it.
            if grew > 0 {
                gained += 1
                newObservations += grew
            } else if earliestChanged {
                revised += 1
            } else if touchedKeys.contains(entry.scientificName) {
                // The CSV named it and had nothing new to say. Species the import
                // never mentioned are simply not part of this tally.
                skipped += 1
            }
        }

        return (
            merged,
            ImportSummary(
                added: added,
                gained: gained,
                revised: revised,
                skipped: skipped,
                newObservations: newObservations
            )
        )
    }

    // MARK: Persistence

    /// The app's real home for all three files. `nil` only if Application
    /// Support can't be resolved at all, which nothing can recover from — the
    /// store then reads and writes nothing and the list stays empty in memory.
    private nonisolated static func applicationSupport() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    /// The life list itself.
    private var storeURL: URL? { directory?.appendingPathComponent("life_list.json") }

    /// Separate file for the starred ("alert me") set, intentionally decoupled
    /// from `life_list.json` so the stars outlive a wipe-and-reimport.
    private var starsURL: URL? { directory?.appendingPathComponent("starred_species.json") }

    /// Separate file for the eBird export ledger, decoupled from the life list
    /// for the same reason the stars are: it has to outlive a wipe-and-reimport.
    private var exportedKeysURL: URL? { directory?.appendingPathComponent("exported_observations.json") }

    /// Loads the export ledger. An absent file simply means nothing has been
    /// exported yet, so an empty set is the right answer.
    private func loadExportedKeys() -> Set<String> {
        do {
            guard let url = exportedKeysURL,
                  FileManager.default.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Set<String>.self, from: data)
        } catch {
            Log.error("LifeListStore: export ledger load failed — \(error)")
            return []
        }
    }

    /// Loads the persisted star set. Returns `nil` (not empty) when the file
    /// has never been written, so `init` can tell "no stars" apart from
    /// "pre-feature install, migrate from the entries."
    private func loadStars() -> Set<String>? {
        do {
            guard let url = starsURL,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Set<String>.self, from: data)
        } catch {
            Log.error("LifeListStore: stars load failed — \(error)")
            return nil
        }
    }

    /// Serial queue for persistence. Encoding the pretty-printed JSON and writing
    /// it to disk are both done here, off the main actor, so a star toggle or a
    /// life-list edit doesn't hitch the UI — the synchronous encode + atomic write
    /// of the whole list on the main thread was a visible lag (e.g. the full-screen
    /// viewer's star button stalling on tap). A serial queue keeps writes ordered
    /// so a later save can't land before an earlier one.
    private static let ioQueue = DispatchQueue(label: "com.kestrel.lifelist.io", qos: .utility)

    /// Blocks until every write queued so far has landed on disk.
    ///
    /// Persistence is deliberately asynchronous — that's the whole point of the
    /// IO queue — which leaves no moment at which a caller can say "the file now
    /// reflects this change." Tests need exactly that before they read a file
    /// back, and the queue being *serial* is what makes a barrier enough: a
    /// `sync` behind the queued writes can only run once they have.
    ///
    /// Not part of the app's own flow, and shouldn't be: blocking the main actor
    /// on disk IO is the hitch this queue exists to avoid.
    func flushPendingWrites() {
        Self.ioQueue.sync { }
    }

    /// Mirrors `saveStars`: snapshot on the main actor, encode + write on the
    /// serial IO queue so a large ledger never hitches the UI.
    private func saveExportedKeys() {
        let snapshot = exportedObservationKeys.sorted()
        guard let url = exportedKeysURL else { return }
        Self.ioQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.error("LifeListStore: export ledger save failed — \(error)")
            }
        }
    }

    private func saveStars() {
        // Snapshot on the main actor (cheap value copy), then encode + write off it.
        let snapshot = starredNames.sorted()
        guard let url = starsURL else { return }
        Self.ioQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.error("LifeListStore: stars save failed — \(error)")
            }
        }
    }

    /// Marks that this install's stored sightings have been rewritten onto the
    /// UTC-midnight invariant (see `ObservationDate`). The migration below is
    /// **not** idempotent — it reads a date's day in the device's time zone — so
    /// it has to run exactly once, and a flag is the only thing that can promise
    /// that.
    private static let dateMigrationKey = "lifeList.datesNormalizedToUTC"

    /// Rewrites every stored sighting to midnight UTC on the calendar day it
    /// currently reads as locally. Runs once per install, on the first launch
    /// after the invariant landed.
    ///
    /// Preserving the *local* day is what makes this a no-op from the user's
    /// side: a row that said "May 4, 2019" still says it, the export ledger's
    /// existing keys still match (they were the local day of the old date, which
    /// is the UTC day of the new one), and nothing already uploaded to eBird
    /// looks new again. Ordering survives too — the map is monotonic in day
    /// order, so an entry's earliest sighting stays its earliest and the
    /// displayed first-seen fields don't need re-promoting.
    ///
    /// The one imperfect case is a device whose time zone has changed since the
    /// records were written: those days shift by one. Unavoidable — the old
    /// format simply didn't record which zone it meant, which is the defect being
    /// fixed.
    private nonisolated static func normalizeDates(_ entries: [LifeListEntry]) -> [LifeListEntry] {
        entries.map { entry in
            var copy = entry
            copy.firstSeen = ObservationDate.canonical(entry.firstSeen)
            copy.otherObservations = entry.otherObservations.map { observation in
                var moved = observation
                moved.date = ObservationDate.canonical(observation.date)
                return moved
            }
            return copy
        }
    }

    private func load() {
        let needsDateMigration = !defaults.bool(forKey: Self.dateMigrationKey)
        do {
            guard let url = storeURL,
                  FileManager.default.fileExists(atPath: url.path) else {
                // Nothing stored yet, so there is nothing to migrate — a fresh
                // install writes canonical dates from its first sighting on.
                if needsDateMigration {
                    defaults.set(true, forKey: Self.dateMigrationKey)
                }
                return
            }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([LifeListEntry].self, from: data)
            let normalized = needsDateMigration ? Self.normalizeDates(decoded) : decoded
            let collapsed = Self.canonicalize(normalized)
            entries = collapsed.sorted(by: Self.ordersBefore)
            refreshSpeciesNames()
            // Persist if anything actually changed — dates were migrated, rows
            // merged, or a scientific name was rewritten to its catalog-canonical
            // form.
            let mutated = needsDateMigration
                || collapsed.count != decoded.count
                || zip(
                    decoded.sorted { $0.scientificName < $1.scientificName },
                    collapsed.sorted { $0.scientificName < $1.scientificName }
                ).contains { $0.scientificName != $1.scientificName }
            if mutated {
                save()
            }
            // Only once the migrated list is on its way to disk: a crash before
            // this leaves the flag clear and the migration runs again next launch,
            // which is the safe direction to fail in.
            if needsDateMigration {
                defaults.set(true, forKey: Self.dateMigrationKey)
            }
        } catch {
            Log.error("LifeListStore: load failed — \(error)")
        }
    }

    /// Full canonicalization pipeline shared by `load()` and the import
    /// `merge()`: rewrite stale eBird scientific names through the alias table,
    /// collapse trinomial subspecies into their binomial, then collapse
    /// same-common-name synonyms onto the BirdNET-canonical scientific name so
    /// image-slug and detection lookups resolve to the right photo.
    ///
    /// One rule governs `dedupe` throughout this file, and every `make` call
    /// below states which side of it it falls on: **collapse identical sightings
    /// only where two independent sets of records are being unioned** — the
    /// import folding a CSV into what is already stored, or two spellings of one
    /// species being merged into a single entry. A call that rebuilds one entry
    /// (relabeling it, or writing the user's own add / edit / delete into it)
    /// never dedupes, because there is no second set for its records to be
    /// duplicates *of*, and quietly dropping one would be losing data the user
    /// entered by hand. This pipeline runs on every launch, so getting that
    /// backwards would erode the list a little at a time.
    private nonisolated static func canonicalize(_ entries: [LifeListEntry]) -> [LifeListEntry] {
        collapseByCommonName(collapseToSpecies(applyAliases(entries)))
    }

    /// Merge entries whose scientific names differ only in a trinomial subspecies
    /// token (e.g. "Dryobates villosus villosus" + "Dryobates villosus harrisi" →
    /// "Dryobates villosus"). Keeps the earliest first-seen date, OR-merges the
    /// star flag, and prefers a parenthetical-free common name when picking which
    /// row's display fields to keep.
    private nonisolated static func collapseToSpecies(_ entries: [LifeListEntry]) -> [LifeListEntry] {
        var byBinomial: [String: LifeListEntry] = [:]
        // Insertion order, kept for the same reason `collapseByScientificName`
        // keeps one: `Dictionary.values` is unordered, and Swift seeds its
        // hashing per process, so returning it made the *input order* of the next
        // pass differ between launches. That pass resolves a collision by keeping
        // whichever entry it saw first, so which scientific name and which common
        // name survived a merge was a coin flip — and the survivor's name is the
        // entry's id, and its id is its photo slug.
        var order: [String] = []
        for entry in entries {
            let key = speciesBinomial(entry.scientificName)
            guard let existing = byBinomial[key] else {
                order.append(key)
                // Already a binomial: nothing to rewrite, so pass the entry
                // through untouched rather than round-tripping it through
                // `make`. That round-trip ran on every entry on every launch,
                // which is exactly where a rebuild could quietly disturb
                // observations the user recorded by hand.
                guard key != entry.scientificName else {
                    byBinomial[key] = entry
                    continue
                }
                // A trinomial being renamed to its binomial. Rebuild via `make`
                // so the rename carries the full observation set (and
                // earliest-sighting promotion) intact — but this is one entry
                // being relabeled, not two being merged, so nothing collapses.
                byBinomial[key] = LifeListEntry.make(
                    scientificName: key,
                    commonName: entry.commonName,
                    isStarred: entry.isStarred,
                    observations: entry.allObservations,
                    dedupe: false
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
                observations: existing.allObservations + entry.allObservations,
                // Two separately-stored spellings of one species being folded
                // together — a genuine union of record sets, so a sighting
                // filed under both spellings collapses to one.
                dedupe: true
            )
        }
        return order.compactMap { byBinomial[$0] }
    }

    /// Second-pass merge: collapse entries that share the same common name but
    /// have different scientific names — this catches taxonomic revisions where
    /// a species moved genera (e.g. "Leuconotopicus villosus" → "Dryobates villosus"
    /// for Hairy Woodpecker). Prefers the scientific name that matches BirdNET's
    /// catalog so detection-driven lookups resolve to the canonical entry.
    private nonisolated static func collapseByCommonName(_ entries: [LifeListEntry]) -> [LifeListEntry] {
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
        // Insertion order, for the reason spelled out in `collapseToSpecies`:
        // this pass keeps whichever of two colliding entries it met first, so its
        // output has to be ordered or the *next* pass inherits a different input
        // order on every launch.
        var order: [String] = []
        for entry in entries {
            let key = entry.commonName.lowercased()
            guard let existing = byCommon[key] else {
                byCommon[key] = entry
                order.append(key)
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
                observations: existing.allObservations + entry.allObservations,
                // A union of two entries' records, same as `collapseToSpecies`.
                dedupe: true
            )
        }
        // Final pass: rewrite singletons whose scientific name doesn't exist
        // in the catalog but whose common name does. This is the path that
        // fixes a lone Hairy Woodpecker entry stored under the old genus
        // (Leuconotopicus villosus) — the multi-entry merge above only fires
        // when there are two rows to collide.
        let relabeled = order.compactMap { byCommon[$0] }.map { entry in
            if catalogNames.contains(entry.scientificName) { return entry }
            guard let canonical = catalogByCommon[entry.commonName.lowercased()] else {
                return entry
            }
            return LifeListEntry.make(
                scientificName: canonical,
                commonName: entry.commonName,
                isStarred: entry.isStarred,
                observations: entry.allObservations,
                // One entry being relabeled, so its records pass through as-is.
                dedupe: false
            )
        }
        return collapseByScientificName(relabeled)
    }

    /// Folds together any entries left sharing a scientific name.
    ///
    /// The rewrite above can land one entry on a name another already holds,
    /// because it keys on the *common* name and only the scientific name has to
    /// come out unique. It takes two entries for the same bird whose common
    /// names differ — which an eBird export in a non-English display language
    /// produces readily: the localized name doesn't match the catalog, so that
    /// entry keeps its stale synonym, while a second entry under the English
    /// name gets rewritten onto the catalog's. `byCommon` never sees them as the
    /// same species, so neither earlier merge fires.
    ///
    /// Left alone, the two ride out of canonicalization sharing a
    /// `LifeListEntry.id`, and a `ForEach` over duplicate ids renders one row and
    /// misroutes the other's swipe actions — the bird becomes unreachable.
    ///
    /// A no-op in the overwhelmingly common case (one pass over the values, no
    /// collision found), so it costs nothing to run on every launch.
    private nonisolated static func collapseByScientificName(
        _ entries: [LifeListEntry]
    ) -> [LifeListEntry] {
        var bySci: [String: LifeListEntry] = [:]
        var order: [String] = []
        for entry in entries {
            guard let existing = bySci[entry.scientificName] else {
                bySci[entry.scientificName] = entry
                order.append(entry.scientificName)
                continue
            }
            // Prefer a common name without a parenthetical clarifier, matching
            // how `collapseToSpecies` picks between two spellings of one bird.
            let commonName = existing.commonName.contains("(") && !entry.commonName.contains("(")
                ? entry.commonName
                : existing.commonName
            bySci[entry.scientificName] = LifeListEntry.make(
                scientificName: entry.scientificName,
                commonName: commonName,
                isStarred: existing.isStarred || entry.isStarred,
                observations: existing.allObservations + entry.allObservations,
                // A union of two entries' record sets, same as the merges above.
                dedupe: true
            )
        }
        return order.compactMap { bySci[$0] }
    }

    /// First-pass migration: rewrite scientific names through the alias
    /// table so downstream collapses and image lookups see the BirdNET
    /// canonical form. Handles cases like "Setophaga aestiva" (eBird's
    /// post-split Northern Yellow Warbler) → "Setophaga petechia" (BirdNET's
    /// Yellow Warbler) where neither the sci nor common name matches the
    /// catalog directly.
    private nonisolated static func applyAliases(_ entries: [LifeListEntry]) -> [LifeListEntry] {
        entries.map { entry in
            let canonical = TaxonomyAliases.canonical(entry.scientificName)
            guard canonical != entry.scientificName else { return entry }
            return LifeListEntry.make(
                scientificName: canonical,
                commonName: entry.commonName,
                isStarred: entry.isStarred,
                observations: entry.allObservations,
                // One entry being relabeled, so its records pass through as-is.
                dedupe: false
            )
        }
    }

    private nonisolated static func speciesBinomial(_ s: String) -> String {
        let parts = s.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2 else { return s }
        return "\(parts[0]) \(parts[1])"
    }

    private func save() {
        // Snapshot the entries on the main actor (value-type copy), then encode +
        // write on the IO queue so the whole-list JSON encode and atomic disk write
        // never block the main thread (the source of the star-tap / edit hitch).
        let snapshot = entries
        guard let url = storeURL else { return }
        Self.ioQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.error("LifeListStore: save failed — \(error)")
            }
        }
    }
}
