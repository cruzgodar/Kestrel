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
        // The default path resolves Application Support with `create: true`; an
        // injected one had nothing doing the same, so a store pointed at a
        // directory that didn't exist yet could read and write nothing — every
        // `save()` failing with "the folder doesn't exist", silently, since the
        // write is on the IO queue and its error only reaches the log. Make the
        // two paths behave alike.
        if let directory = self.directory {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
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
        let result: (entries: [LifeListEntry], renames: [String: String], summary: ImportSummary)
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
        // An import can fold an eBird spelling onto a name already on the list —
        // that is what the canonicalization above is for — so follow the user's
        // stars onto whatever it moved, *before* the re-stamp below overwrites
        // them from a set still keyed to the old name. See `migrateStars`.
        migrateStars(renames: result.renames)
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

    /// The sightings `scope` covers, flattened into one row per observation and
    /// paired with its species. The unit of an eBird record is a single
    /// observation, not a species, so repeat sightings each get their own row.
    ///
    /// **`nonisolated static`, taking its inputs by value, so the whole walk can
    /// run off the main actor** — which `makeEBirdExport` does. This is not a
    /// cheap flatten: `.newOnly` asks the ledger about every row, and each of
    /// those questions builds two keys, each of which renders a date, folds a
    /// place name character by character (`EBirdCSVExporter.sanitize`) and
    /// formats two coordinates. An eBird export is one row per *observation*, so
    /// for an active birder's imported history that is tens of thousands of rows
    /// and a hundred thousand-odd string allocations. Building the rows on the
    /// main actor and detaching only the CSV rendering left the expensive half
    /// exactly where the detaching was meant to keep it from being.
    nonisolated static func exportRows(
        from entries: [LifeListEntry],
        scope: ExportScope,
        exportedKeys: Set<String>
    ) -> [EBirdCSVExporter.Row] {
        var rows: [EBirdCSVExporter.Row] = []
        for entry in entries {
            for observation in entry.allObservations {
                let row = EBirdCSVExporter.Row(
                    scientificName: entry.scientificName,
                    commonName: entry.commonName,
                    observation: observation
                )
                switch scope {
                case .everything:
                    rows.append(row)
                case .newOnly:
                    if isNewToEBird(row, exportedKeys: exportedKeys) { rows.append(row) }
                }
            }
        }
        return rows
    }

    /// The export ledger's key for one sighting. Wrapped so the export check and
    /// the edit path (which has to carry a key forward, see `replaceObservation`)
    /// can't drift apart on how a sighting is identified.
    private nonisolated static func exportKey(
        scientificName: String,
        observation: LifeListEntry.Observation
    ) -> String {
        EBirdCSVExporter.key(scientificName: scientificName, observation: observation)
    }

    /// Whether a sighting belongs in a `.newOnly` export. Two ways eBird can
    /// already have it: it came *from* eBird on an import, or a previous export
    /// handed it over.
    nonisolated static func isNewToEBird(
        _ row: EBirdCSVExporter.Row,
        exportedKeys: Set<String>
    ) -> Bool {
        guard !row.observation.isImported else { return false }
        return !hasBeenExported(
            scientificName: row.scientificName,
            observation: row.observation,
            in: exportedKeys
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
    private nonisolated static func hasBeenExported(
        scientificName: String,
        observation: LifeListEntry.Observation,
        in exportedKeys: Set<String>
    ) -> Bool {
        let key = exportKey(scientificName: scientificName, observation: observation)
        if exportedKeys.contains(key) { return true }
        let legacy = EBirdCSVExporter.legacyKey(
            scientificName: scientificName,
            observation: observation
        )
        return exportedKeys.contains(legacy)
    }

    /// `hasBeenExported` against this store's own ledger, for the main-actor
    /// callers that have one to hand.
    private func hasBeenExported(
        scientificName: String,
        observation: LifeListEntry.Observation
    ) -> Bool {
        Self.hasBeenExported(
            scientificName: scientificName,
            observation: observation,
            in: exportedObservationKeys
        )
    }

    /// Every recorded sighting on the life list, counted. A species contributes
    /// one per observation, not one flat — which is what "N observations" has to
    /// mean anywhere the user is told how much they are about to lose.
    var totalObservationCount: Int {
        entries.reduce(0) { $0 + 1 + $1.otherObservations.count }
    }

    /// How many rows an export of `scope` would produce.
    ///
    /// Synchronous, and therefore on the main actor for the whole walk — see
    /// `exportRows` for what that costs on a large list. Deliberately **not** on
    /// the export button's path any more: the sheet used to call this to vet a
    /// scope before starting, which meant every tap paid for the walk twice, once
    /// here and once inside `makeEBirdExport`. The emptiness of an export is now
    /// read off the payload it produced (see `LifeListView.beginExport`), so this
    /// is left as the plain question it reads as, for tests and diagnostics.
    func observationCount(for scope: ExportScope) -> Int {
        Self.exportRows(
            from: entries, scope: scope, exportedKeys: exportedObservationKeys
        ).count
    }

    /// Builds the eBird Record Format CSV for `scope`, reporting completion
    /// through `progress` as it goes.
    ///
    /// Everything runs on a detached task: selecting the rows is as expensive as
    /// rendering them (see `exportRows`), and both would otherwise freeze the
    /// sheet mid-tap. Only the two snapshots below happen on the main actor, and
    /// both are `Array`/`Set` retains rather than walks.
    ///
    /// Nothing is marked as exported here — the caller does that via
    /// `markExported` only after the file is actually saved, so a cancelled
    /// save panel doesn't quietly hide those sightings from the next export.
    func makeEBirdExport(
        scope: ExportScope,
        progress: ExportProgress? = nil
    ) async -> EBirdCSVExporter.Payload {
        let entries = self.entries
        let exportedKeys = exportedObservationKeys
        return await Task.detached(priority: .userInitiated) {
            let rows = Self.exportRows(
                from: entries, scope: scope, exportedKeys: exportedKeys
            )
            return EBirdCSVExporter.makeCSV(rows: rows) { done, total in
                guard let progress else { return }
                let fraction = total > 0 ? Double(done) / Double(total) : 1
                Task { @MainActor in progress.fraction = fraction }
            }
        }.value
    }

    /// Whether saving this export counts as handing its observations to eBird.
    ///
    /// Two conditions, and the second is the subtle one.
    ///
    /// **The scope must be `.newOnly`.** Exporting everything is a "give me the
    /// whole list" operation — a backup, a re-upload, a file for something other
    /// than eBird — and treating it as a handover would silently empty out Export
    /// New, which is the one thing the user relies on to not duplicate their
    /// history.
    ///
    /// **The file must be one eBird will actually accept.** Saving is not
    /// uploading, and the ledger deliberately takes a save as good enough — but
    /// past eBird's 1 MB import limit the app *knows* the file can't be uploaded
    /// as it stands (it says so, in the same alert). Marking those rows handed
    /// over anyway left the user with a file eBird refuses, an Export New that now
    /// writes nothing, and no way to get the missing records out except Export All
    /// — which is the whole imported history, and the duplicate risk the ledger
    /// exists to prevent.
    nonisolated static func recordsHandover(
        scope: ExportScope,
        exceedsSizeLimit: Bool
    ) -> Bool {
        scope == .newOnly && !exceedsSizeLimit
    }

    /// Records that these observations are now in eBird's hands, so the next
    /// `.newOnly` export skips them. Call only on a successful save, and only
    /// when `recordsHandover` says so.
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
    /// one drops into `otherObservations`. No-op if the species isn't on the
    /// list — the Life List tab's add flow routes those through `add` instead.
    ///
    /// **Nothing collapses here**, even an exact repeat of a sighting already on
    /// file. This is the user writing a record by hand, not two sets of records
    /// being unioned, so it falls on the `dedupe: false` side of this file's one
    /// rule — see `canonicalize` and the note at the call below. (This comment
    /// used to claim the opposite, "exact duplicates collapse, matching
    /// re-import behavior", which was left over from before that rule existed
    /// and describes a behavior that would silently eat a second sighting of one
    /// bird at one spot on one day.)
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

    /// Carries the user's stars across the scientific names canonicalization
    /// moved, so a star survives its species being re-filed.
    ///
    /// **Runs before `applyStarsToEntries`, always.** Canonicalization OR-merges
    /// `isStarred` onto the surviving entry, and that re-stamp then overwrites
    /// every flag from `starredNames` — which is keyed to the name the bird had
    /// *before* the move. So without this the re-stamp didn't just fail to notice
    /// the star, it cleared the one the merge had carried over: a bird the user
    /// had asked to be alerted about went quiet on the launch its name changed,
    /// and the row showed an empty star with nothing to explain it.
    ///
    /// **Additive: the old name is kept.** Removing it could only lose
    /// information, and leaving it costs nothing — a superseded name matches no
    /// BirdNET detection (that is exactly why it was rewritten) and no entry, so
    /// it sits inert, the same way a retired key sits in
    /// `exportedObservationKeys`. It also can't resurrect anything: unstarring
    /// removes the *current* name, and the next launch finds nothing left to
    /// rename — the entry is already stored under it — so this never runs over
    /// that pair again.
    ///
    /// Returns whether anything was added, so a caller can tell a launch that
    /// migrated a star from one that had nothing to do.
    @discardableResult
    private func migrateStars(renames: [String: String]) -> Bool {
        guard !renames.isEmpty else { return false }
        var changed = false
        for (old, new) in renames where starredNames.contains(old) {
            if starredNames.insert(new).inserted { changed = true }
        }
        if changed { saveStars() }
        return changed
    }

    /// Re-stamps every entry's `isStarred` flag from the authoritative
    /// `starredNames` set, persisting the life list only if anything changed.
    ///
    /// Every caller runs `migrateStars` first — see that method for what happens
    /// when they don't.
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
    ///
    /// Ordered by `LifeListEntry.Observation.ordersBefore`, which tiebreaks past
    /// the date all the way down to provenance. Sorting on date and place alone
    /// left two sightings sharing both — a pair this app deliberately allows —
    /// comparing equal, and `Array.sorted` can return either arrangement of equal
    /// elements. See that function.
    func observations(for scientificName: String) -> [LifeListEntry.Observation] {
        guard let entry = entries.first(where: { $0.scientificName == scientificName }) else {
            return []
        }
        return entry.allObservations.sorted(by: LifeListEntry.Observation.ordersBefore)
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
    ///
    /// Returns the sighting it actually wrote, or `nil` when `original` wasn't on
    /// record and nothing was written. Both halves matter to a caller holding a
    /// sighting *by value*: an edit gives that value a new date or place, so the
    /// copy the caller is still holding no longer describes anything, and a
    /// second edit or a delete aimed at it would silently do nothing. Handing
    /// back the replacement is what lets a caller follow its own edit — see
    /// `ObservationActions.recordEdit`. The `nil` says the write didn't happen,
    /// which used to be indistinguishable from one that did.
    @discardableResult
    func replaceObservation(
        scientificName: String,
        original: LifeListEntry.Observation,
        date: Date,
        location: String?,
        latitude: Double?,
        longitude: Double?
    ) -> LifeListEntry.Observation? {
        guard let idx = entries.firstIndex(where: { $0.scientificName == scientificName }) else {
            return nil
        }
        let existing = entries[idx]
        var remaining = existing.allObservations
        guard let hit = Self.locate(original, in: remaining) else { return nil }
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
        return replacement
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

    /// What the life list held for one species before an import, reduced to the
    /// two things the tally compares against.
    nonisolated struct PriorEntry {
        /// Every sighting the species had on record, earliest included.
        var observationCount: Int
        /// The sighting that was showing as its first — i.e. the entry's
        /// `first*` fields, reconstituted.
        var first: LifeListEntry.Observation
    }

    /// The pre-import life list keyed by the name each species will come out
    /// under, following `renames` so a species canonicalization re-files is
    /// compared against itself rather than looking brand new.
    ///
    /// Two entries can land on one name — that is exactly what a rename-and-merge
    /// is — so a collision sums the sightings and keeps whichever first sighting
    /// `LifeListEntry.make` would have promoted. Using `promotionOrder` rather
    /// than a date comparison of its own is what stops this from disagreeing with
    /// the entry it is describing when two same-day sightings differ only in how
    /// complete they are.
    nonisolated static func priorEntries(
        _ existing: [LifeListEntry],
        renames: [String: String]
    ) -> [String: PriorEntry] {
        var priors: [String: PriorEntry] = [:]
        priors.reserveCapacity(existing.count)
        for entry in existing {
            let name = renames[entry.scientificName] ?? entry.scientificName
            let observations = entry.allObservations
            // `allObservations` always leads with the displayed first sighting,
            // and is never empty — an entry with no observations can't exist.
            guard let first = observations.first else { continue }
            guard let prior = priors[name] else {
                priors[name] = PriorEntry(observationCount: observations.count, first: first)
                continue
            }
            priors[name] = PriorEntry(
                observationCount: prior.observationCount + observations.count,
                first: LifeListEntry.promotionOrder(first, prior.first) ? first : prior.first
            )
        }
        return priors
    }

    /// Pure merge: folds `rows` into `existing` and returns the canonicalized,
    /// sorted entry set plus the import tally. `nonisolated static` so the heavy
    /// work (full canonicalization against the ~6.5k-species catalog) can run off
    /// the main actor from `importEBird`. It does not touch instance state — the
    /// caller assigns the result, re-stamps stars, and saves on the main actor.
    private nonisolated static func computeMergedEntries(
        rows: [EBirdRawRow],
        existing: [LifeListEntry]
    ) -> (entries: [LifeListEntry], renames: [String: String], summary: ImportSummary) {
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
        // **Sorted before canonicalizing, and that is load-bearing.** `prelim`
        // comes off a `Dictionary`, whose iteration order Swift randomizes per
        // process — and `canonicalize` resolves a collision by keeping whichever
        // of two entries it met *first*: `collapseByCommonName` picks
        // `existing.scientificName` when the catalog can't break the tie, and
        // `collapseToSpecies` / `collapseByScientificName` pick a common name the
        // same way. Handed an unordered array, which spelling of a bird survived
        // an import was a coin flip between launches — and the survivor's name is
        // the entry's id, its photo slug, and what a BirdNET detection matches
        // against.
        //
        // Those three passes each keep an explicit `order` array so they don't
        // *introduce* any order dependence of their own (see the note in
        // `collapseToSpecies`); this is the input they were relying on someone
        // else to make deterministic. `load()` always did, by handing over a
        // decoded file in stored order. The import path is the one that didn't.
        //
        // `ordersBefore` rather than, say, plain name order, because it is the
        // order the finished set comes out in anyway (below) and the order a
        // `load()` of this same data would present it in — so an import resolves a
        // collision exactly the way the next launch would have.
        let ordered = prelim.sorted(by: Self.ordersBefore)
        // Canonicalize the same way `load()` does so freshly imported entries
        // pick up BirdNET-canonical scientific names immediately — otherwise an
        // eBird name like "Astur cooperii" (Cooper's Hawk) or "Spilopelia
        // chinensis" (Spotted Dove) would slug to a missing image and show the
        // placeholder until the next launch.
        let canonical = Self.canonicalize(ordered)
        let merged = canonical.entries.sorted(by: Self.ordersBefore)

        // The tally is measured against the *finished* set rather than against
        // the row names, because canonicalization can fold an eBird spelling onto
        // a species already on the list ("Astur cooperii" onto "Accipiter
        // cooperii"). Counting rows would report that as a species added when the
        // list didn't grow at all; comparing final entries to the ones we started
        // with gets it right without needing to know which names were rewritten.
        //
        // `touchedKeys` is the one part that *does* need to know: it is keyed on
        // the names the CSV used, and the loop below asks it about names as they
        // came out the far end. A row canonicalization rewrote answered "the CSV
        // never mentioned this species" about a species the CSV was entirely
        // about, so a re-import of an eBird export under eBird's own spelling
        // reported fewer species "already known" than it had read — and with one
        // species in the file, reported nothing at all. Follow the same renames
        // the stars follow.
        let touched = Set(touchedKeys.map { canonical.renames[$0] ?? $0 })
        // The life list as it stood before this import began, keyed by the name
        // each species came out under — so the comparison below is against the
        // *same* species, not against whatever happened to be filed under that
        // name before.
        //
        // `touchedKeys` above follows the renames; this used to not, and the
        // asymmetry showed. Canonicalization can fold an entry already on the list
        // onto an imported spelling and keep the *imported* name (that is what
        // `collapseByCommonName` does when only the incoming name is in the
        // catalog), and a lookup keyed by the pre-import name then found nothing —
        // so a species the user already had was reported as new to their life
        // list, with every sighting it had ever held counted as freshly added.
        let priorBySci = Self.priorEntries(existing, renames: canonical.renames)
        var added = 0
        var gained = 0
        var revised = 0
        var skipped = 0
        var newObservations = 0
        for entry in merged {
            guard let before = priorBySci[entry.scientificName] else {
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
            let grew = entry.allObservations.count - before.observationCount
            let earliestChanged = before.first.date != entry.firstSeen
                || before.first.location != entry.firstLocation
                || before.first.latitude != entry.firstLatitude
                || before.first.longitude != entry.firstLongitude
            // Growing wins over a revised earliest when both happened: the
            // species is already accounted for by the "added N observations"
            // clause, and naming it twice would double-count it.
            if grew > 0 {
                gained += 1
                newObservations += grew
            } else if earliestChanged {
                revised += 1
            } else if touched.contains(entry.scientificName) {
                // The CSV named it and had nothing new to say. Species the import
                // never mentioned are simply not part of this tally.
                skipped += 1
            }
        }

        return (
            merged,
            canonical.renames,
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

    /// Records that this install's stored sightings have been rewritten onto the
    /// UTC-midnight invariant (see `ObservationDate`), so later launches can skip
    /// a pass that has nothing left to do.
    ///
    /// **An optimization, not a correctness guarantee.** It used to be the latter,
    /// and couldn't be: the flag lands in `UserDefaults` while the migrated list
    /// lands on the IO queue, and nothing orders the two, so a kill between them
    /// can leave *either* one written without the other. The direction that
    /// mattered — data migrated, flag lost — re-ran a conversion that was not
    /// idempotent and slid every sighting west of UTC back a day. `normalizeDates`
    /// is now safe to repeat, which is what actually closes that; this only keeps
    /// the ordinary launch from walking the list for nothing.
    private static let dateMigrationKey = "lifeList.datesNormalizedToUTC"

    /// Rewrites every stored sighting that isn't already midnight UTC to midnight
    /// UTC on the calendar day it currently reads as locally.
    ///
    /// Preserving the *local* day is what makes this a no-op from the user's
    /// side: a row that said "May 4, 2019" still says it, the export ledger's
    /// existing keys still match (they were the local day of the old date, which
    /// is the UTC day of the new one), and nothing already uploaded to eBird
    /// looks new again. Ordering survives too — the map is monotonic in day
    /// order, so an entry's earliest sighting stays its earliest and the
    /// displayed first-seen fields don't need re-promoting.
    ///
    /// **Safe to run any number of times.** `ObservationDate.canonical` on its own
    /// is not — it re-reads an already-canonical instant's day in the device's
    /// zone, which west of UTC is the day before — so every date is gated on
    /// `ObservationDate.isCanonical` first. Skipping those is exactly right, not
    /// merely safe: see that function. This is what makes the migration flag an
    /// optimization rather than the only thing standing between a lost `UserDefaults`
    /// write and a life list shifted back a day.
    ///
    /// The one imperfect case is a device whose time zone has changed since the
    /// records were written: those days shift by one. Unavoidable — the old
    /// format simply didn't record which zone it meant, which is the defect being
    /// fixed.
    private nonisolated static func normalizeDates(_ entries: [LifeListEntry]) -> [LifeListEntry] {
        func normalized(_ date: Date) -> Date {
            ObservationDate.isCanonical(date) ? date : ObservationDate.canonical(date)
        }
        return entries.map { entry in
            var copy = entry
            copy.firstSeen = normalized(entry.firstSeen)
            copy.otherObservations = entry.otherObservations.map { observation in
                var moved = observation
                moved.date = normalized(observation.date)
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
            entries = collapsed.entries.sorted(by: Self.ordersBefore)
            refreshSpeciesNames()
            // Follow the user's stars onto whatever names this pass moved, before
            // `init`'s `applyStarsToEntries` re-stamps from the set — see
            // `migrateStars`.
            migrateStars(renames: collapsed.renames)
            // Persist if anything actually changed — dates were migrated, rows
            // merged, a scientific name was rewritten to its catalog-canonical
            // form, or a merge picked a different common name.
            //
            // Straight value equality against what was decoded, because every
            // stage above preserves input order when it changes nothing:
            // `normalizeDates` and `applyAliases` map, and each collapse pass
            // rebuilds from a first-seen `order` array. So `collapsed == decoded`
            // is exactly "this launch found nothing to fix". The old test
            // compared only entry *counts* and scientific names, which missed a
            // changed common name or a re-sorted observation set and redid that
            // work, unpersisted, on every launch.
            if collapsed.entries != decoded {
                save()
            }
            // Purely so the next launch can skip the pass; `normalizeDates` is
            // idempotent, so losing this write costs a walk over the list rather
            // than the user's dates. See `dateMigrationKey`.
            if needsDateMigration {
                defaults.set(true, forKey: Self.dateMigrationKey)
            }
        } catch let error as DecodingError {
            // The file is there and readable but isn't a life list any more.
            // Nothing is going to make those bytes decode, so the store starts
            // empty — but they are not thrown away: `quarantineStore` moves them
            // aside under a dated name, which is what makes it safe to go on
            // saving over the (now absent) real file. Without that move, the
            // user's first add or import would encode this empty list straight
            // over their history.
            Log.error("LifeListStore: life list is corrupt — \(error)")
            if quarantineStore() {
                if needsDateMigration {
                    defaults.set(true, forKey: Self.dateMigrationKey)
                }
            } else {
                loadFailed = true
            }
        } catch {
            // Couldn't *read* the file — a file-protection window before first
            // unlock, a disk error, a file yanked mid-launch. Possibly transient,
            // so nothing is moved and nothing is assumed about the contents; the
            // store simply refuses to write until a launch manages to load it.
            Log.error("LifeListStore: load failed — \(error)")
            loadFailed = true
        }
    }

    /// Whether the last `load()` came back without the life list it was supposed
    /// to read, in a way that leaves the on-disk copy still worth protecting.
    ///
    /// `entries` is empty in that state and does **not** describe the user's
    /// history, so writing it out would destroy the thing that failed to load.
    /// Every write path funnels through `save()`, which refuses while this is set;
    /// the next launch retries the load. Deliberately *not* set for a corrupt file
    /// that `quarantineStore()` managed to move aside — once the bad bytes are
    /// safely parked under their own name, an empty store is the honest state and
    /// saving over nothing is correct.
    @ObservationIgnored private var loadFailed = false

    /// Moves an undecodable life list aside as `life_list.corrupt-<stamp>.json`,
    /// so the bytes survive for recovery while the app gets a clean slate to write
    /// to. Returns whether the move succeeded — a failure leaves the original
    /// exactly where it is and the store read-only for this launch.
    private func quarantineStore() -> Bool {
        guard let url = storeURL else { return false }
        let stamp = Self.quarantineStampFormatter.string(from: Date())
        let destination = url
            .deletingLastPathComponent()
            .appendingPathComponent("life_list.corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            Log.error(
                "LifeListStore: moved the unreadable life list to \(destination.lastPathComponent)"
            )
            return true
        } catch {
            Log.error("LifeListStore: couldn't quarantine the corrupt life list — \(error)")
            return false
        }
    }

    /// `yyyy-MM-dd-HHmmss` in UTC, POSIX — a filename stamp, so it has to sort and
    /// parse the same whatever the device's locale and calendar are set to.
    private static let quarantineStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = ObservationDate.utc
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

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
    private nonisolated static func canonicalize(_ entries: [LifeListEntry]) -> Canonicalization {
        let aliased = applyAliases(entries)
        let species = collapseToSpecies(aliased.entries)
        let common = collapseByCommonName(species.entries)
        return Canonicalization(
            entries: common.entries,
            renames: composeRenames(
                composeRenames(aliased.renames, species.renames),
                common.renames
            )
        )
    }

    /// What a canonicalization produced: the finished entries, plus every
    /// scientific name it *moved*.
    nonisolated struct Canonicalization {
        var entries: [LifeListEntry]
        /// `old → new` for every name that went in and came out filed under a
        /// different one — an alias rewrote it, a trinomial collapsed to its
        /// binomial, or two spellings of one bird merged. Keys are names as they
        /// stood on the way in; values are names present in `entries`. Empty on
        /// the overwhelmingly common launch, where nothing moved.
        ///
        /// **This exists for `starredNames`**, which is keyed by scientific name
        /// and persisted separately from the life list so a star can outlive the
        /// entry (see that property). Every merge below OR-merges `isStarred`
        /// onto the surviving entry — and then `applyStarsToEntries` re-stamps
        /// every entry from `starredNames`, which is still keyed to the name the
        /// bird *used* to have. Without carrying the rename across, that re-stamp
        /// didn't merely fail to add the star, it actively cleared the one the
        /// merge had just carried over: the user's "alert me" for that bird
        /// vanished on the launch its name moved, with nothing to say why. See
        /// `migrateStars`.
        var renames: [String: String] = [:]
    }

    /// Chains two rename maps, so a name the first pass moved and the second
    /// moved again ends up pointing at where it actually landed.
    ///
    /// A name that comes back to itself is dropped rather than recorded as an
    /// identity rename — `migrateStars` would otherwise re-insert a star that is
    /// already there, and, more to the point, a rename map is supposed to list
    /// what changed.
    nonisolated static func composeRenames(
        _ first: [String: String],
        _ second: [String: String]
    ) -> [String: String] {
        guard !first.isEmpty else { return second }
        var out = second
        for (old, middle) in first {
            let final = second[middle] ?? middle
            if final == old {
                out.removeValue(forKey: old)
            } else {
                out[old] = final
            }
        }
        return out
    }

    /// Records `old → new` in a rename map a pass is building for itself,
    /// **re-pointing anything that had already landed on `old`** so the map can
    /// never contain a chain.
    ///
    /// `composeRenames` chains one pass's map onto the next one's. Nothing
    /// chained a pass's map onto *itself*, and `collapseByCommonName` is a pass
    /// that can move the same name twice: three entries sharing a common name
    /// merge pairwise, and if the survivor's scientific name changes on the
    /// second collision, the first collision's target is now a name no entry
    /// holds. Written straight into the dictionary, that left `Z → X` beside
    /// `X → Y` with nothing pointing `Z` at `Y`.
    ///
    /// The consequence was a star that vanished, and vanished *unpredictably*.
    /// `migrateStars` walks the map with `for (old, new) in renames`, and
    /// `Dictionary` iteration order is seeded per process — so `Z → X` before
    /// `X → Y` carried the star the whole way, while the other order left the
    /// surviving entry's name unstarred and `applyStarsToEntries` then cleared
    /// the flag the merge had OR'd onto it. Same data, same code, different
    /// answer on the next launch.
    ///
    /// Keeping the map flat at the point of insertion fixes it for every reader
    /// at once, rather than teaching each one to chase chains.
    nonisolated static func recordRename(
        _ old: String,
        to new: String,
        in map: inout [String: String]
    ) {
        guard old != new else { return }
        for (key, value) in map where value == old {
            // A name that would now point at itself is dropped rather than
            // recorded as an identity rename, matching `composeRenames`.
            if key == new {
                map.removeValue(forKey: key)
            } else {
                map[key] = new
            }
        }
        map[old] = new
    }

    /// Merge entries whose scientific names differ only in a trinomial subspecies
    /// token (e.g. "Dryobates villosus villosus" + "Dryobates villosus harrisi" →
    /// "Dryobates villosus"). Keeps the earliest first-seen date, OR-merges the
    /// star flag, and prefers a parenthetical-free common name when picking which
    /// row's display fields to keep.
    private nonisolated static func collapseToSpecies(_ entries: [LifeListEntry]) -> Canonicalization {
        var renames: [String: String] = [:]
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
            // Recorded once here rather than in each branch below: a trinomial
            // lands under its binomial whether it is the first entry to claim
            // that key or is merging into one that already has, and the star
            // that rode in on it has to follow either way.
            Self.recordRename(entry.scientificName, to: key, in: &renames)
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
        return Canonicalization(
            entries: order.compactMap { byBinomial[$0] },
            renames: renames
        )
    }

    /// Second-pass merge: collapse entries that share the same common name but
    /// have different scientific names — this catches taxonomic revisions where
    /// a species moved genera (e.g. "Leuconotopicus villosus" → "Dryobates villosus"
    /// for Hairy Woodpecker). Prefers the scientific name that matches BirdNET's
    /// catalog so detection-driven lookups resolve to the canonical entry.
    private nonisolated static func collapseByCommonName(_ entries: [LifeListEntry]) -> Canonicalization {
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
        // The two rewrites below run in sequence — a name the merge moves can be
        // moved again by the catalog relabel — so they are chained rather than
        // unioned. See `composeRenames`.
        var mergeRenames: [String: String] = [:]
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
            // Whichever of the pair didn't supply the surviving name has been
            // moved onto the other's, and its star has to come with it. Through
            // `recordRename` — which no-ops when a name didn't actually move,
            // and, crucially here, re-points anything an *earlier* collision had
            // already sent to `existing.scientificName`. Three entries under one
            // common name merge pairwise, so a name this pass moved once can be
            // moved again; see `recordRename`.
            Self.recordRename(existing.scientificName, to: scientificName, in: &mergeRenames)
            Self.recordRename(entry.scientificName, to: scientificName, in: &mergeRenames)
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
        var relabelRenames: [String: String] = [:]
        let relabeled = order.compactMap { byCommon[$0] }.map { entry -> LifeListEntry in
            if catalogNames.contains(entry.scientificName) { return entry }
            guard let canonical = catalogByCommon[entry.commonName.lowercased()] else {
                return entry
            }
            Self.recordRename(entry.scientificName, to: canonical, in: &relabelRenames)
            return LifeListEntry.make(
                scientificName: canonical,
                commonName: entry.commonName,
                isStarred: entry.isStarred,
                observations: entry.allObservations,
                // One entry being relabeled, so its records pass through as-is.
                dedupe: false
            )
        }
        return Canonicalization(
            entries: collapseByScientificName(relabeled),
            // `collapseByScientificName` folds entries that already *share* a
            // scientific name, so it can't move one and contributes nothing here.
            renames: composeRenames(mergeRenames, relabelRenames)
        )
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
    private nonisolated static func applyAliases(_ entries: [LifeListEntry]) -> Canonicalization {
        var renames: [String: String] = [:]
        let mapped = entries.map { entry -> LifeListEntry in
            let canonical = TaxonomyAliases.canonical(entry.scientificName)
            guard canonical != entry.scientificName else { return entry }
            Self.recordRename(entry.scientificName, to: canonical, in: &renames)
            return LifeListEntry.make(
                scientificName: canonical,
                commonName: entry.commonName,
                isStarred: entry.isStarred,
                observations: entry.allObservations,
                // One entry being relabeled, so its records pass through as-is.
                dedupe: false
            )
        }
        return Canonicalization(entries: mapped, renames: renames)
    }

    private nonisolated static func speciesBinomial(_ s: String) -> String {
        let parts = s.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2 else { return s }
        return "\(parts[0]) \(parts[1])"
    }

    private func save() {
        // A load that failed leaves `entries` empty and *wrong* — it describes
        // nothing, least of all the file it couldn't read. Writing it out would
        // replace the user's whole life list with an empty one, and an import
        // landing in that state would replace it with the CSV alone. See
        // `loadFailed`, which the next launch clears by loading successfully.
        guard !loadFailed else {
            Log.error("LifeListStore: refusing to save over a life list that failed to load")
            return
        }
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
