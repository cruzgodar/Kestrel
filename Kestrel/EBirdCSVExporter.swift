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
    static func key(scientificName: String, observation: LifeListEntry.Observation) -> String {
        let date = ObservationDate.isoDay(observation.date)
        let location = observation.location ?? ""
        func coord(_ value: Double?) -> String {
            guard let value else { return "" }
            return String(format: "%.5f", value)
        }
        return [
            scientificName,
            date,
            location,
            coord(observation.latitude),
            coord(observation.longitude)
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
        let sorted = rows.sorted { a, b in
            if a.observation.date != b.observation.date {
                return a.observation.date < b.observation.date
            }
            return a.commonName < b.commonName
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
            // Counted the same way `locationName(for:)` decides to fall back to
            // the placeholder, so the tally can't drift from the file.
            if locationName(for: observation) == unplaceableLocation { unplaceable += 1 }

            let fields: [String] = [
                sanitize(eBirdCommonName(row.commonName)),      // Common Name
                sanitize(genus),                                // Genus
                sanitize(species),                              // Species
                presentNotCounted,                              // Number
                "",                                             // Species Comments
                sanitize(locationName(for: observation)),       // Location Name
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

    /// Location Name is required by eBird on every row, but Kestrel's place name
    /// is optional (sound-ID adds made before the naming step existed, imports
    /// from CSVs without a Location column). Fall back to the coordinates, which
    /// still let eBird place the record on the map, and only then to a
    /// placeholder the user will have to resolve by hand.
    private static func locationName(for observation: LifeListEntry.Observation) -> String {
        if let name = observation.location?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        if let lat = observation.latitude, let lon = observation.longitude {
            return String(format: "%.5f, %.5f", lat, lon)
        }
        return unplaceableLocation
    }

    /// Stand-in name for a sighting with neither a place name nor coordinates —
    /// the only rows the user has to resolve by hand on eBird's side, and what
    /// `Payload.unplaceableCount` counts.
    private static let unplaceableLocation = "Unspecified location"

    private static func coordinate(_ value: Double?) -> String {
        guard let value else { return "" }
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
