import Foundation

/// Builds an **eBird Record Format** CSV from the life list, ready to hand to
/// eBird's "Import Data" tool.
///
/// Record Format (rather than Checklist Format) because Checklist Format is
/// capped at 48 checklists per file — a life list spanning years of outings
/// blows past that immediately — while Record Format takes as many rows as fit
/// in 1 MB. Each row is one observation; eBird groups rows sharing a date,
/// location, time and protocol into a single checklist on its end, which is
/// exactly how Kestrel's per-species sightings should land.
///
/// Every column below is fixed by eBird: 19 fields in this exact order, **no
/// header row**, comma-delimited, and no quotation marks anywhere in the file
/// (see `sanitize`). See
/// https://support.ebird.org/en/support/solutions/articles/48000907878
nonisolated enum EBirdCSVExporter {
    /// The result of building an export: the bytes to save plus everything the
    /// UI needs to describe what just happened, and the observation keys to
    /// mark as exported once the file is actually written.
    nonisolated struct Payload {
        let csv: Data
        let speciesCount: Int
        let observationCount: Int
        /// Observations eBird cannot place at all: no place name *and* no
        /// coordinates, so they export under a placeholder name and need a
        /// location picked by hand during eBird's "Fix Locations" step. A
        /// sighting with coordinates but no name is not counted — it exports
        /// under its own "lat, lon" and eBird maps it without help.
        let unplaceableCount: Int
        /// Identity keys of every observation in this file. Handed back to
        /// `LifeListStore.markExported` only after a successful save.
        let exportedKeys: Set<String>

        var byteCount: Int { csv.count }
        /// eBird refuses any single import file over 1 MB.
        var exceedsEBirdSizeLimit: Bool { byteCount > 1_000_000 }
    }

    /// One observation paired with the species it belongs to. Flattened out of
    /// the life list by `LifeListStore` before it gets here.
    nonisolated struct Row {
        let scientificName: String
        let commonName: String
        let observation: LifeListEntry.Observation
    }

    /// eBird's recommended protocol for records that are just "this species, on
    /// this date, at this place" with no effort data — which is all Kestrel
    /// tracks. See "Enter your pre-eBird life list".
    private static let protocolName = "Historical"

    /// eBird accepts `X` in the count column for "present but not counted".
    /// Kestrel records that a bird was there, never how many.
    private static let presentNotCounted = "X"

    /// `N`: a Kestrel sighting is one bird logged, never a claim that every
    /// species present was reported. Marking these `Y` would misrepresent the
    /// records as complete checklists.
    private static let allObservationsReported = "N"

    /// Stable identity for a single sighting, used to remember which
    /// observations have already been sent to eBird. Coordinates are rounded to
    /// five decimals (~1 m) so a float round-trip through JSON can't make the
    /// same sighting look new on the next export.
    ///
    /// The day component is rendered in **UTC** (`ObservationDate.isoDay`), which
    /// is the whole point of storing sightings at midnight UTC: keyed on the
    /// device's local day instead, flying to a different UTC offset moved every
    /// evening sighting's key onto the next day, the ledger stopped recognizing
    /// it, and the next "Export New Observations" handed eBird a second copy.
    ///
    /// The place component is `exportedPlaceName` — the name this sighting is
    /// actually filed under on eBird's side, fallback resolved and folded —
    /// rather than the raw stored one, so this key and
    /// `LifeListEntry.Observation.Identity` describe a sighting the same way.
    /// They used to disagree, which meant an edit could carry a ledger entry
    /// forward under one notion of "the same sighting" while the merge folded
    /// records under another.
    static func key(scientificName: String, observation: LifeListEntry.Observation) -> String {
        key(
            scientificName: scientificName,
            observation: observation,
            place: exportedPlaceName(for: observation)
        )
    }

    /// The key format as it stood before the place component was folded: the raw
    /// stored location, empty string when there wasn't one.
    ///
    /// Read-side only, and never written. A ledger built by an earlier build is
    /// full of these, and the ledger is the one piece of state whose loss is
    /// *unrecoverable* — eBird does no deduplication, so a key that stops
    /// matching hands the user a second copy of a record they already uploaded.
    /// Recognizing both formats costs one extra set lookup and needs no
    /// migration, which is the only way to change the format without ever
    /// risking that.
    static func legacyKey(
        scientificName: String,
        observation: LifeListEntry.Observation
    ) -> String {
        key(
            scientificName: scientificName,
            observation: observation,
            place: observation.location ?? ""
        )
    }

    private static func key(
        scientificName: String,
        observation: LifeListEntry.Observation,
        place: String
    ) -> String {
        [
            scientificName,
            ObservationDate.isoDay(observation.date),
            place,
            coordinate(observation.latitude),
            coordinate(observation.longitude)
        ].joined(separator: "|")
    }

    /// How many rows are rendered between `onProgress` callbacks. Sized so a
    /// large life list reports roughly 40-ish times over the whole run — often
    /// enough that the bar moves smoothly, rarely enough that the reporting
    /// itself doesn't dominate the work.
    private static func progressStride(for count: Int) -> Int {
        max(1, count / 40)
    }

    /// Renders `rows` as a headerless eBird Record Format CSV. `onProgress` is
    /// called periodically with (rows rendered, total rows) — see
    /// `progressStride`.
    static func makeCSV(
        rows: [Row],
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) -> Payload {
        // Oldest first, so the file reads chronologically and eBird's import
        // review page walks forward through the user's birding history.
        //
        // Tiebroken past the name and down through the sighting itself
        // (`ordersBeforeAtSameDate`, the same fall-through
        // `LifeListStore.observations(for:)` uses), so the same life list always
        // renders byte-identical bytes. Date + common name alone left two
        // sightings of one species on one day comparing equal, and
        // `Array.sorted` can hand back either arrangement of equal elements — so
        // exporting twice could produce two different files from unchanged data,
        // which is a poor property for something a user diffs or re-uploads.
        let sorted = rows.sorted { a, b in
            if a.observation.date != b.observation.date {
                return a.observation.date < b.observation.date
            }
            if a.commonName != b.commonName { return a.commonName < b.commonName }
            if a.scientificName != b.scientificName { return a.scientificName < b.scientificName }
            return LifeListEntry.Observation.ordersBeforeAtSameDate(a.observation, b.observation)
        }

        var lines: [String] = []
        lines.reserveCapacity(sorted.count)
        var keys = Set<String>()
        var unplaceable = 0
        let total = sorted.count
        let stride = progressStride(for: total)

        for (index, row) in sorted.enumerated() {
            let observation = row.observation
            let (genus, species) = splitBinomial(row.scientificName)
            // The exact string the Location Name column gets, so the tally and
            // the file can't drift from each other.
            let place = exportedPlaceName(for: observation)
            if isUnplaceable(
                location: observation.location,
                latitude: observation.latitude,
                longitude: observation.longitude
            ) {
                unplaceable += 1
            }

            let fields: [String] = [
                sanitize(eBirdCommonName(row.commonName)),      // Common Name
                sanitize(genus),                                // Genus
                sanitize(species),                              // Species
                presentNotCounted,                              // Number
                "",                                             // Species Comments
                place,                                          // Location Name
                coordinate(observation.latitude),               // Latitude
                coordinate(observation.longitude),              // Longitude
                ObservationDate.eBirdDay(observation.date),     // Date
                "",                                             // Start Time
                "",                                             // State/Province
                "",                                             // Country Code
                protocolName,                                   // Protocol
                "1",                                            // Number of Observers
                "",                                             // Duration
                allObservationsReported,                        // All observations reported?
                "",                                             // Effort Distance Miles
                "",                                             // Effort area acres
                ""                                              // Submission Comments
            ]
            lines.append(fields.joined(separator: ","))
            keys.insert(key(scientificName: row.scientificName, observation: observation))
            if (index + 1) % stride == 0 { onProgress(index + 1, total) }
        }
        // Always land on 100%, whatever the stride left over.
        onProgress(total, total)

        // Trailing newline so the last record is a complete line. eBird's parser
        // treats the first row as data — there is deliberately no header here.
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        return Payload(
            csv: Data(text.utf8),
            speciesCount: Set(sorted.map(\.scientificName)).count,
            observationCount: sorted.count,
            unplaceableCount: unplaceable,
            exportedKeys: keys
        )
    }

    /// Suggested filename (without extension) for the save panel.
    static func defaultFilename(date: Date = Date()) -> String {
        "Kestrel Life List \(filenameDateFormatter.string(from: date))"
    }

    // MARK: Field formatting

    /// eBird wants feral city pigeons filed as "Rock Pigeon (Feral Pigeon)" —
    /// naming them that way here saves a manual disambiguation during the
    /// import's "Fix Species" step. Kestrel strips parentheticals on import, so
    /// the stored name is always the bare "Rock Pigeon".
    private static func eBirdCommonName(_ name: String) -> String {
        name == "Rock Pigeon" ? "Rock Pigeon (Feral Pigeon)" : name
    }

    /// `exportedPlaceName` for a whole observation.
    static func exportedPlaceName(for observation: LifeListEntry.Observation) -> String {
        exportedPlaceName(
            location: observation.location,
            latitude: observation.latitude,
            longitude: observation.longitude
        )
    }

    /// **The** name a sighting is filed under once it has been through the
    /// export: the Location Name column's fallback resolved, then folded by
    /// `sanitize`. Byte-for-byte what lands in the CSV, and therefore what eBird
    /// hands back on the next data download.
    ///
    /// Not private, and not merely a rendering detail, because a sighting has to
    /// be able to recognize its own re-imported twin.
    /// `LifeListEntry.Observation.Identity` compares *this*, not the raw stored
    /// location: a sighting with coordinates but no place name went out under
    /// `42.45342 -76.47352` and came back carrying that as its Location, so
    /// comparing the raw values made it unequal to itself and filed the returning
    /// copy as a second observation — a duplicate pin on the map and a doubled
    /// "N Observations" for a record the user already had. The same is true of a
    /// sighting with neither, which goes out as `unplaceableLocation`.
    ///
    /// Note the *space* in that fallback, not a comma. The file forbids commas
    /// outright (they are the delimiter, with no quoting), so the two numbers are
    /// joined by a space and nothing downstream ever sees the comma form.
    ///
    /// The comma case (`Ithaca, NY` → `Ithaca NY`) was already handled by folding
    /// through `sanitize`; these are the two the fallback introduces, which no
    /// amount of folding the *stored* name could have caught.
    ///
    /// **Fold first, then decide whether anything survived.** `sanitize` is lossy
    /// — it drops quotes outright and turns commas into spaces — so a name made
    /// only of those characters folds away to nothing. Testing the *stored* name
    /// for emptiness and folding afterwards let such a name through as a blank
    /// Location Name: a column eBird requires, with no coordinate fallback
    /// applied and nothing in `Payload.unplaceableCount` to warn about it. The
    /// order here is the fix, and it is why the fallback lives in this function
    /// rather than in a separate one feeding it.
    static func exportedPlaceName(
        location: String?,
        latitude: Double?,
        longitude: Double?
    ) -> String {
        // `sanitize` collapses whitespace, so this subsumes trimming: a name of
        // nothing but spaces folds to "" here just as an empty one does.
        let folded = sanitize(location ?? "")
        if !folded.isEmpty { return folded }
        // Coordinates still let eBird place the record on the map without help.
        // Joined by a space, and built by `coordinate` — the same function the
        // Latitude and Longitude columns go through — so the name a row is filed
        // under can't round differently from the columns beside it.
        if let latitude, let longitude {
            return "\(coordinate(latitude)) \(coordinate(longitude))"
        }
        // Nothing to place it by at all — the user resolves these by hand during
        // eBird's "Fix Locations" step.
        return unplaceableLocation
    }

    /// Whether eBird will have nothing at all to place this sighting by, and so
    /// whether it exports under `unplaceableLocation` — exactly the condition
    /// under which `exportedPlaceName` reaches its last line.
    ///
    /// Stated structurally rather than by comparing the exported name back
    /// against the placeholder string, which counted a user who had genuinely
    /// named a spot "Unspecified location" among the rows they would have to fix
    /// by hand on eBird's side.
    static func isUnplaceable(location: String?, latitude: Double?, longitude: Double?) -> Bool {
        guard sanitize(location ?? "").isEmpty else { return false }
        return latitude == nil || longitude == nil
    }

    /// Stand-in name for a sighting with neither a place name nor coordinates —
    /// the only rows the user has to resolve by hand on eBird's side, and what
    /// `Payload.unplaceableCount` counts.
    private static let unplaceableLocation = "Unspecified location"

    /// A coordinate rounded to the five decimal places (~1 m) the CSV carries —
    /// the most precision that can survive a trip through eBird.
    ///
    /// **The single rounding decision**, shared with
    /// `LifeListEntry.Observation.Identity.canonicalCoordinate`, which delegates
    /// here the same way `canonicalPlace` delegates to `exportedPlaceName`. The
    /// two used to round independently — `%.5f` here (half-to-even) against
    /// `(v * 100_000).rounded() / 100_000` there (half-away-from-zero) — so the
    /// ledger's idea of a coordinate and identity's could in principle disagree
    /// about a value landing exactly on a half. One function, one answer.
    static func canonicalCoordinate(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return (value * 100_000).rounded() / 100_000
    }

    /// `canonicalCoordinate` rendered for the file. Formatting the already-
    /// rounded value means `%.5f` has nothing left to decide.
    private static func coordinate(_ value: Double?) -> String {
        guard let value = canonicalCoordinate(value) else { return "" }
        return String(format: "%.5f", value)
    }

    /// eBird's scientific name arrives as two columns, not one. A name that
    /// isn't a clean two-token binomial degrades to genus-only rather than
    /// guessing — the common name column carries the identification either way.
    private static func splitBinomial(_ scientificName: String) -> (genus: String, species: String) {
        let parts = scientificName.split(whereSeparator: { $0.isWhitespace })
        guard let genus = parts.first else { return ("", "") }
        guard parts.count >= 2 else { return (String(genus), "") }
        return (String(genus), String(parts[1]))
    }

    /// eBird's importer rejects files containing quotation marks outright, and
    /// commas are the delimiter with no quoting permitted — so a place name like
    /// `Ithaca, NY` would silently shift every later column out of place. Strip
    /// quotes, turn commas and line breaks into spaces, and collapse the
    /// resulting runs of whitespace.
    ///
    /// Not private, because this transform is *lossy* and the loss outlives the
    /// file: a place name that goes to eBird folded comes back folded on the
    /// next import. `LifeListEntry.Observation.Identity` folds the stored name
    /// the same way before comparing, so a re-imported sighting still matches
    /// the one it came from instead of being filed as a duplicate. The two must
    /// stay the same function — hence one definition, here, where the CSV
    /// constraint that forces it lives.
    static func sanitize(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "\"", "\u{201C}", "\u{201D}":
                continue
            case ",", "\n", "\r", "\t":
                out.append(" ")
            default:
                out.append(ch)
            }
        }
        return out
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // MARK: Formatters

    /// Both of this file's sighting-date renderings — the CSV's `MM/dd/yyyy`
    /// Date column and the ledger key's `yyyy-MM-dd` day — live on
    /// `ObservationDate`, in UTC, alongside the invariant that puts every stored
    /// sighting at midnight UTC. There is deliberately no local-time formatter
    /// here for either.
    ///
    /// The filename stamp below is the exception, and stays local: it names the
    /// day the user is saving the file on, not the day a bird was seen.
    private static let filenameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
