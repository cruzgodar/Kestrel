import Foundation
import Testing
@testable import Kestrel

/// The eBird Record Format writer.
///
/// eBird's importer is unforgiving in ways that fail *silently*: it rejects files
/// containing quotation marks outright, it does no quoting or escaping so a comma
/// in a field shifts every later column, and it does no deduplication at all — so
/// a malformed or repeated upload becomes real, wrong data in the user's account
/// that they then have to unpick by hand.
@Suite("EBirdCSVExporter")
struct EBirdCSVExporterTests {

    private let may4 = utcDay(2026, 5, 4)

    private func row(
        _ sci: String = "Cardinalis cardinalis",
        _ common: String = "Northern Cardinal",
        observation: LifeListEntry.Observation
    ) -> EBirdCSVExporter.Row {
        .init(scientificName: sci, commonName: common, observation: observation)
    }

    // MARK: file shape

    /// Nineteen fields, in eBird's fixed order, with no header row — the importer
    /// treats the first line as data.
    @Test("every row is 19 comma-separated fields and there is no header")
    func rowShape() {
        let payload = EBirdCSVExporter.makeCSV(rows: [
            row(observation: .at(may4, "Ithaca NY", lat: 42.45342, lon: -76.47352)),
            row("Turdus migratorius", "American Robin", observation: .at(may4, "Ithaca NY")),
        ])
        let lines = parseExportedCSV(payload)
        #expect(lines.count == 2, "two rows, no header line")
        for line in lines {
            #expect(line.count == 19, "eBird's Record Format is exactly 19 columns")
        }
        let text = String(decoding: payload.csv, as: UTF8.self)
        #expect(!text.lowercased().hasPrefix("common name"), "a header would be imported as a record")
    }

    @Test("the file ends with a newline so the last record is a complete line")
    func trailingNewline() {
        let payload = EBirdCSVExporter.makeCSV(rows: [row(observation: .at(may4, "P"))])
        #expect(String(decoding: payload.csv, as: UTF8.self).hasSuffix("\n"))
    }

    @Test("an empty export is empty bytes, not a stray newline")
    func emptyExport() {
        let payload = EBirdCSVExporter.makeCSV(rows: [])
        #expect(payload.csv.isEmpty)
        #expect(payload.observationCount == 0)
        #expect(payload.speciesCount == 0)
        #expect(payload.exportedKeys.isEmpty)
    }

    /// The fixed columns carry meaning: `X` is "present, not counted", `N` says
    /// this is not a complete checklist, and `Historical` is eBird's protocol for
    /// records with no effort data — which is all Kestrel tracks. Marking these
    /// `Y` would misrepresent them as complete checklists.
    @Test("the fixed columns say what Kestrel actually knows")
    func fixedColumns() {
        let payload = EBirdCSVExporter.makeCSV(rows: [
            row(observation: .at(may4, "Ithaca NY", lat: 42.45342, lon: -76.47352)),
        ])
        let fields = parseExportedCSV(payload)[0]
        #expect(fields[0] == "Northern Cardinal")   // Common Name
        #expect(fields[1] == "Cardinalis")          // Genus
        #expect(fields[2] == "cardinalis")          // Species
        #expect(fields[3] == "X")                   // Number — present, not counted
        #expect(fields[4] == "")                    // Species Comments
        #expect(fields[5] == "Ithaca NY")           // Location Name
        #expect(fields[6] == "42.45342")            // Latitude
        #expect(fields[7] == "-76.47352")           // Longitude
        #expect(fields[8] == "05/04/2026")          // Date
        #expect(fields[9] == "")                    // Start Time
        #expect(fields[12] == "Historical")         // Protocol
        #expect(fields[13] == "1")                  // Number of Observers
        #expect(fields[15] == "N")                  // All observations reported?
    }

    /// Oldest first, so eBird's import review page walks forward through the
    /// user's birding history rather than backwards.
    @Test("rows are written oldest first, with a stable tie-break on common name")
    func sortOrder() {
        let payload = EBirdCSVExporter.makeCSV(rows: [
            row("C c", "Zebra Finch", observation: .at(utcDay(2026, 6, 1), "P")),
            row("A a", "Alder Flycatcher", observation: .at(utcDay(2026, 5, 1), "P")),
            row("B b", "Baltimore Oriole", observation: .at(utcDay(2026, 5, 1), "P")),
        ])
        let names = parseExportedCSV(payload).map { $0[0] }
        #expect(names == ["Alder Flycatcher", "Baltimore Oriole", "Zebra Finch"])
    }

    // MARK: sanitize — the silent-corruption guard

    /// A comma in a place name would shift every later column, so the row would
    /// import with the wrong date, the wrong protocol, everything. Quotes make
    /// eBird reject the file outright.
    @Test(
        "characters the format cannot carry never reach the file",
        arguments: [
            "Ithaca, NY",
            "\"Sapsucker Woods\"",
            "\u{201C}Curly\u{201D} Marsh",
            "Line\nBreak",
            "Carriage\rReturn",
            "Tab\tHere",
            "Everything, \"at\"\tonce\n",
        ]
    )
    func sanitizeStripsDangerousCharacters(place: String) {
        let payload = EBirdCSVExporter.makeCSV(rows: [row(observation: .at(may4, place))])
        let text = String(decoding: payload.csv, as: UTF8.self)
        #expect(!text.contains("\""), "eBird rejects any file containing a quotation mark")
        #expect(!text.contains("\u{201C}") && !text.contains("\u{201D}"))
        #expect(!text.contains("\t"))
        #expect(!text.contains("\r"))
        #expect(parseExportedCSV(payload)[0].count == 19, "column count must survive the name")
    }

    @Test("sanitize collapses the whitespace its own substitutions create")
    func sanitizeCollapsesWhitespace() {
        #expect(EBirdCSVExporter.sanitize("Ithaca, NY") == "Ithaca NY")
        #expect(EBirdCSVExporter.sanitize("A,,B") == "A B")
        #expect(EBirdCSVExporter.sanitize("  padded  ") == "padded")
        #expect(EBirdCSVExporter.sanitize("many     spaces") == "many spaces")
        #expect(EBirdCSVExporter.sanitize("") == "")
        #expect(EBirdCSVExporter.sanitize("   ") == "")
    }

    @Test("sanitize leaves ordinary names untouched")
    func sanitizeIsMinimal() {
        for name in ["Sapsucker Woods", "Mt. Auburn Cemetery", "Ash Rd. & 3rd", "Île d'Orléans"] {
            #expect(EBirdCSVExporter.sanitize(name) == name)
        }
    }

    // MARK: location fallbacks

    /// Location Name is required on every eBird row, but Kestrel's is optional.
    /// Coordinates still let eBird place the record on the map, so they are the
    /// first fallback; only a sighting with neither needs a human.
    @Test("a nameless sighting with coordinates exports under its own lat, lon")
    func namelessWithCoordinates() {
        let payload = EBirdCSVExporter.makeCSV(rows: [
            row(observation: .at(may4, nil, lat: 42.45342, lon: -76.47352)),
        ])
        let fields = parseExportedCSV(payload)[0]
        // The comma inside the fallback name is itself sanitized away.
        #expect(fields[5] == "42.45342 -76.47352")
        #expect(payload.unplaceableCount == 0, "eBird can place this one without help")
    }

    @Test("a sighting with neither a name nor coordinates is counted as unplaceable")
    func trulyUnplaceable() {
        let payload = EBirdCSVExporter.makeCSV(rows: [row(observation: .at(may4))])
        let fields = parseExportedCSV(payload)[0]
        #expect(fields[5] == "Unspecified location")
        #expect(fields[6] == "" && fields[7] == "")
        #expect(payload.unplaceableCount == 1)
    }

    @Test("a blank or whitespace-only name falls back like a missing one")
    func blankNameFallsBack() {
        for blank in ["", "   ", "\n"] {
            let payload = EBirdCSVExporter.makeCSV(rows: [
                row(observation: .at(may4, blank, lat: 1, lon: 2)),
            ])
            #expect(parseExportedCSV(payload)[0][5] == "1.00000 2.00000")
        }
    }

    /// The tally has to be counted the same way the file decides, or the alert
    /// tells the user a different number than eBird will ask them to fix.
    @Test("unplaceableCount matches the rows that actually got the placeholder")
    func unplaceableCountMatchesFile() {
        let payload = EBirdCSVExporter.makeCSV(rows: [
            row(observation: .at(may4)),
            row(observation: .at(may4, "Named")),
            row(observation: .at(may4, nil, lat: 1, lon: 2)),
            row(observation: .at(may4)),
        ])
        let placeholders = parseExportedCSV(payload).filter { $0[5] == "Unspecified location" }.count
        #expect(payload.unplaceableCount == placeholders)
        #expect(payload.unplaceableCount == 2)
    }

    // MARK: names and coordinates

    /// eBird files feral city pigeons under a disambiguated name; using it here
    /// saves a manual step during the import's "Fix Species" pass.
    @Test("Rock Pigeon is exported under eBird's disambiguated name")
    func rockPigeonRenamed() {
        let payload = EBirdCSVExporter.makeCSV(rows: [
            row("Columba livia", "Rock Pigeon", observation: .at(may4, "P")),
        ])
        #expect(parseExportedCSV(payload)[0][0] == "Rock Pigeon (Feral Pigeon)")
    }

    @Test("other common names are passed through unchanged")
    func otherNamesUnchanged() {
        let payload = EBirdCSVExporter.makeCSV(rows: [
            row("Zenaida macroura", "Mourning Dove", observation: .at(may4, "P")),
        ])
        #expect(parseExportedCSV(payload)[0][0] == "Mourning Dove")
    }

    /// eBird wants genus and species as two columns. A name that isn't a clean
    /// binomial degrades to genus-only rather than guessing — the common-name
    /// column carries the identification either way.
    @Test(
        "scientific names split into genus and species",
        arguments: [
            ("Cardinalis cardinalis", "Cardinalis", "cardinalis"),
            ("Dryobates villosus harrisi", "Dryobates", "villosus"),
            ("Cardinalis", "Cardinalis", ""),
            ("", "", ""),
            ("  Spaced   Out  ", "Spaced", "Out"),
        ]
    )
    func binomialSplit(name: String, genus: String, species: String) {
        let payload = EBirdCSVExporter.makeCSV(rows: [row(name, "Bird", observation: .at(may4, "P"))])
        let fields = parseExportedCSV(payload)[0]
        #expect(fields[1] == genus)
        #expect(fields[2] == species)
    }

    @Test("coordinates are written at five decimal places")
    func coordinateFormat() {
        let payload = EBirdCSVExporter.makeCSV(rows: [
            row(observation: .at(may4, "P", lat: 42.4534198, lon: -76.4735178)),
        ])
        let fields = parseExportedCSV(payload)[0]
        #expect(fields[6] == "42.45342")
        #expect(fields[7] == "-76.47352")
    }

    /// `String(format:)` must not follow the device locale — a comma decimal
    /// separator would split the column in two and corrupt every later field.
    @Test("coordinates never use a comma as the decimal separator")
    func coordinateDecimalSeparator() {
        let payload = EBirdCSVExporter.makeCSV(rows: [
            row(observation: .at(may4, "P", lat: 42.5, lon: -76.5)),
        ])
        let fields = parseExportedCSV(payload)[0]
        #expect(fields[6] == "42.50000")
        #expect(fields.count == 19)
    }

    @Test("a half-present coordinate writes both columns blank-safe")
    func halfCoordinate() {
        let payload = EBirdCSVExporter.makeCSV(rows: [
            row(observation: .at(may4, "P", lat: 42.5, lon: nil)),
        ])
        let fields = parseExportedCSV(payload)[0]
        #expect(fields[6] == "42.50000")
        #expect(fields[7] == "")
        #expect(fields.count == 19)
    }

    // MARK: payload metadata

    @Test("speciesCount counts distinct species, not rows")
    func speciesCount() {
        let payload = EBirdCSVExporter.makeCSV(rows: [
            row("A a", "A", observation: .at(may4, "P")),
            row("A a", "A", observation: .at(utcDay(2026, 5, 5), "P")),
            row("B b", "B", observation: .at(may4, "P")),
        ])
        #expect(payload.observationCount == 3)
        #expect(payload.speciesCount == 2)
    }

    @Test("exportedKeys covers every row in the file")
    func exportedKeysCoverFile() {
        let observations: [LifeListEntry.Observation] = [
            .at(may4, "A", lat: 1, lon: 1),
            .at(utcDay(2026, 5, 5), "B", lat: 2, lon: 2),
            .at(utcDay(2026, 5, 6), nil),
        ]
        let payload = EBirdCSVExporter.makeCSV(rows: observations.map { row(observation: $0) })
        #expect(payload.exportedKeys.count == 3)
        for observation in observations {
            let key = EBirdCSVExporter.key(scientificName: "Cardinalis cardinalis", observation: observation)
            #expect(payload.exportedKeys.contains(key))
        }
    }

    /// eBird refuses any single import file over 1 MB, and says so only after the
    /// upload — so the app warns first.
    @Test("the size limit flag tracks eBird's 1 MB import ceiling")
    func sizeLimitFlag() {
        let small = EBirdCSVExporter.makeCSV(rows: [row(observation: .at(may4, "P"))])
        #expect(!small.exceedsEBirdSizeLimit)
        #expect(small.byteCount == small.csv.count)

        let many = (0..<12_000).map { i in
            row("Genus sp\(i)", "Bird \(i)", observation: .at(may4, "A reasonably long place name"))
        }
        let large = EBirdCSVExporter.makeCSV(rows: many)
        #expect(large.byteCount > 1_000_000)
        #expect(large.exceedsEBirdSizeLimit)
    }

    // MARK: progress

    @Test("progress is monotonic and always lands on 100%")
    func progressReporting() {
        var reports: [(Int, Int)] = []
        let rows = (0..<250).map { i in
            row("Genus sp\(i)", "Bird \(i)", observation: .at(may4, "P"))
        }
        _ = EBirdCSVExporter.makeCSV(rows: rows) { done, total in reports.append((done, total)) }

        #expect(!reports.isEmpty)
        #expect(reports.last! == (250, 250), "the bar must reach the end")
        #expect(reports.map(\.0) == reports.map(\.0).sorted(), "progress must never go backwards")
        #expect(reports.allSatisfy { $0.1 == 250 })
        #expect(reports.allSatisfy { $0.0 <= $0.1 })
    }

    @Test("an empty render still reports completion")
    func progressOnEmpty() {
        var reports: [(Int, Int)] = []
        _ = EBirdCSVExporter.makeCSV(rows: []) { done, total in reports.append((done, total)) }
        #expect(reports.last! == (0, 0))
    }

    // MARK: the export ledger key

    /// The key exists so a repeat export can skip what eBird already holds. It
    /// rounds coordinates so a float round-trip through JSON can't make the same
    /// sighting look new, and renders the day in UTC so travel can't either.
    @Test("the ledger key is stable across a JSON round trip")
    func keyStableAcrossJSON() throws {
        let observation = LifeListEntry.Observation.at(may4, "Ithaca NY", lat: 42.4534198, lon: -76.4735178)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(
            LifeListEntry.Observation.self, from: encoder.encode(observation)
        )
        #expect(
            EBirdCSVExporter.key(scientificName: "X y", observation: observation)
            == EBirdCSVExporter.key(scientificName: "X y", observation: restored)
        )
    }

    @Test("the ledger key's day component is UTC")
    func keyUsesUTCDay() {
        let key = EBirdCSVExporter.key(
            scientificName: "X y",
            observation: .at(utcDay(2026, 5, 4), "P", lat: 1, lon: 2)
        )
        #expect(key.contains("2026-05-04"))
    }

    @Test("the ledger key separates every component so they can't run together")
    func keyComponentsSeparated() {
        let key = EBirdCSVExporter.key(
            scientificName: "Cardinalis cardinalis",
            observation: .at(may4, "Ithaca NY", lat: 42.45342, lon: -76.47352)
        )
        let parts = key.components(separatedBy: "|")
        #expect(parts.count == 5)
        #expect(parts[0] == "Cardinalis cardinalis")
        #expect(parts[1] == "2026-05-04")
        #expect(parts[2] == "Ithaca NY")
        #expect(parts[3] == "42.45342")
        #expect(parts[4] == "-76.47352")
    }

    @Test("distinct sightings get distinct keys")
    func keysAreDistinct() {
        let base = LifeListEntry.Observation.at(may4, "P", lat: 1, lon: 2)
        let keys = Set([
            EBirdCSVExporter.key(scientificName: "A a", observation: base),
            EBirdCSVExporter.key(scientificName: "B b", observation: base),
            EBirdCSVExporter.key(scientificName: "A a", observation: .at(utcDay(2026, 5, 5), "P", lat: 1, lon: 2)),
            EBirdCSVExporter.key(scientificName: "A a", observation: .at(may4, "Q", lat: 1, lon: 2)),
            EBirdCSVExporter.key(scientificName: "A a", observation: .at(may4, "P", lat: 9, lon: 2)),
            EBirdCSVExporter.key(scientificName: "A a", observation: .at(may4, "P")),
        ])
        #expect(keys.count == 6)
    }

    /// Provenance is not part of the key: the key describes a *record*, and the
    /// same record edited from imported to native is still the same record.
    @Test("the ledger key ignores provenance")
    func keyIgnoresProvenance() {
        let native = LifeListEntry.Observation.at(may4, "P", lat: 1, lon: 2, imported: false)
        let imported = LifeListEntry.Observation.at(may4, "P", lat: 1, lon: 2, imported: true)
        #expect(
            EBirdCSVExporter.key(scientificName: "X y", observation: native)
            == EBirdCSVExporter.key(scientificName: "X y", observation: imported)
        )
    }

    /// The key and `Observation.Identity` have to describe a sighting the same
    /// way, or an edit can carry a ledger entry forward under one notion of "the
    /// same sighting" while the merge folds records under another.
    @Test("the ledger key's place component is the one identity compares")
    func keyPlaceMatchesIdentity() {
        let cases: [LifeListEntry.Observation] = [
            .at(may4, "Ithaca, NY", lat: 42.4534198, lon: -76.4735178),
            .at(may4, nil, lat: 42.4534198, lon: -76.4735178),
            .at(may4, "   ", lat: 1, lon: 2),
            .at(may4),
        ]
        for observation in cases {
            let place = EBirdCSVExporter.key(scientificName: "X y", observation: observation)
                .components(separatedBy: "|")[2]
            #expect(
                place == observation.identity.location,
                "key and identity must fold \(String(describing: observation.location)) the same way"
            )
        }
    }

    // MARK: the legacy ledger key

    /// The place component of the key changed. A ledger written by an earlier
    /// build is full of the old form, and nothing migrates it — the store reads
    /// both instead (see `LifeListStore.hasBeenExported`), because a key that
    /// stops matching means the user's next export hands eBird a second copy of
    /// records it already holds, which cannot be undone.
    @Test("the legacy key is the old raw-location format")
    func legacyKeyShape() {
        let observation = LifeListEntry.Observation.at(
            may4, "Ithaca, NY", lat: 42.45342, lon: -76.47352
        )
        let legacy = EBirdCSVExporter.legacyKey(scientificName: "X y", observation: observation)
        #expect(legacy == "X y|2026-05-04|Ithaca, NY|42.45342|-76.47352")

        let current = EBirdCSVExporter.key(scientificName: "X y", observation: observation)
        #expect(current == "X y|2026-05-04|Ithaca NY|42.45342|-76.47352")
        #expect(current != legacy, "this pair is the whole reason both are read")
    }

    /// A sighting whose stored name needs no folding produces the same string
    /// either way, which is why the vast majority of an existing ledger keeps
    /// matching without any compatibility read at all.
    @Test("the two key formats agree when the place name needs no folding")
    func legacyKeyAgreesOnPlainNames() {
        let observation = LifeListEntry.Observation.at(may4, "Sapsucker Woods", lat: 1, lon: 2)
        #expect(
            EBirdCSVExporter.key(scientificName: "X y", observation: observation)
            == EBirdCSVExporter.legacyKey(scientificName: "X y", observation: observation)
        )
    }

    // MARK: exportedPlaceName

    /// The single definition of "what place is this sighting filed under", shared
    /// by the CSV's Location Name column, the ledger key, and identity.
    @Test("exportedPlaceName resolves the fallback and folds the result")
    func exportedPlaceNameResolvesFallback() {
        #expect(
            EBirdCSVExporter.exportedPlaceName(location: "Ithaca, NY", latitude: 1, longitude: 2)
            == "Ithaca NY"
        )
        #expect(
            EBirdCSVExporter.exportedPlaceName(location: nil, latitude: 42.4534198, longitude: -76.4735178)
            == "42.45342 -76.47352"
        )
        #expect(
            EBirdCSVExporter.exportedPlaceName(location: "  ", latitude: 42.45342, longitude: -76.47352)
            == "42.45342 -76.47352",
            "a blank name is no name"
        )
        #expect(
            EBirdCSVExporter.exportedPlaceName(location: nil, latitude: 42.45342, longitude: nil)
            == "Unspecified location",
            "half a coordinate can't place anything"
        )
        #expect(
            EBirdCSVExporter.exportedPlaceName(location: nil, latitude: nil, longitude: nil)
            == "Unspecified location"
        )
    }

    /// It has to be exactly what the file carries, or the sighting still won't
    /// recognize the copy that comes back.
    @Test("exportedPlaceName is byte-for-byte the CSV's Location Name column")
    func exportedPlaceNameMatchesTheFile() {
        let observations: [LifeListEntry.Observation] = [
            .at(may4, "Ithaca, NY", lat: 42.4534198, lon: -76.4735178),
            .at(may4, nil, lat: 42.4534198, lon: -76.4735178),
            .at(may4, "\"Quoted Marsh\"", lat: 1, lon: 2),
            .at(may4),
        ]
        let payload = EBirdCSVExporter.makeCSV(rows: observations.map { row(observation: $0) })
        let written = parseExportedCSV(payload).map { $0[5] }
        let expected = observations.map {
            EBirdCSVExporter.exportedPlaceName(
                location: $0.location, latitude: $0.latitude, longitude: $0.longitude
            )
        }
        #expect(Set(written) == Set(expected))
    }

    @Test("the suggested filename carries the save date")
    func defaultFilename() {
        let name = EBirdCSVExporter.defaultFilename(date: utcDay(2026, 5, 4))
        #expect(name.hasPrefix("Kestrel Life List "))
        #expect(!name.contains("/"), "a slash would break the save panel")
    }
}
