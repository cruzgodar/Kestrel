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

    /// `sanitize` is lossy — it drops quotes outright and turns commas into
    /// spaces — so a name made only of those characters folds away to nothing.
    /// Testing the *stored* name for emptiness and folding afterwards let such a
    /// name through as a blank Location Name: a column eBird requires, with no
    /// coordinate fallback applied and nothing in `unplaceableCount` to warn
    /// about it.
    @Test("a name that folds away to nothing falls back to the coordinates")
    func foldedAwayNameFallsBackToCoordinates() {
        for hostile in [",", ",,,", "\"", "\u{201C}\u{201D}", "\" , \""] {
            let payload = EBirdCSVExporter.makeCSV(rows: [
                row(observation: .at(may4, hostile, lat: 1, lon: 2)),
            ])
            #expect(parseExportedCSV(payload)[0][5] == "1.00000 2.00000", "\(hostile)")
            #expect(payload.unplaceableCount == 0, "\(hostile)")
        }
    }

    @Test("a name that folds away with no coordinates is counted as unplaceable")
    func foldedAwayNameWithNoCoordinatesIsUnplaceable() {
        for hostile in [",", ",,,", "\"", "\" , \""] {
            let payload = EBirdCSVExporter.makeCSV(rows: [row(observation: .at(may4, hostile))])
            #expect(parseExportedCSV(payload)[0][5] == "Unspecified location", "\(hostile)")
            #expect(payload.unplaceableCount == 1, "\(hostile)")
        }
    }

    /// The column is required, so there is no input for which leaving it empty is
    /// the right answer.
    @Test("the Location Name column is never blank, whatever the stored name")
    func locationNameIsNeverBlank() {
        let names: [String?] = [
            nil, "", "   ", ",", "\"", ",,,", "\u{201C}\u{201D}", "\n\t", "Ithaca, NY", "Sapsucker Woods",
        ]
        for name in names {
            for coords in [(1.0, 2.0), (nil, nil)] as [(Double?, Double?)] {
                let payload = EBirdCSVExporter.makeCSV(rows: [
                    row(observation: .at(may4, name, lat: coords.0, lon: coords.1)),
                ])
                #expect(!parseExportedCSV(payload)[0][5].isEmpty, "\(name ?? "nil")")
            }
        }
    }

    /// `Observation.Identity` compares the *exported* place name, so a sighting
    /// whose stored name folds away has to recognize the coordinates it comes
    /// back from eBird carrying — otherwise the returning copy is filed as a
    /// second observation: a duplicate pin and a doubled "N Observations".
    @Test("a folded-away name and the coordinates it exports under are one identity")
    func foldedAwayNameRoundTripsAsOneSighting() {
        let stored = LifeListEntry.Observation.at(may4, ",", lat: 42.45342, lon: -76.47352)
        // What the next eBird download hands back: the name the file carried.
        let returned = LifeListEntry.Observation.at(
            may4, "42.45342 -76.47352", lat: 42.45342, lon: -76.47352, imported: true
        )
        #expect(stored.identity == returned.identity)
        #expect(
            EBirdCSVExporter.key(scientificName: "X y", observation: stored)
                == EBirdCSVExporter.key(scientificName: "X y", observation: returned),
            "the ledger and identity must not disagree about what one sighting is"
        )
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

    // MARK: re-keying a ledger entry onto a renamed species

    /// The ledger leads with the scientific name, and canonicalization *moves*
    /// scientific names. A key left under the old spelling matches nothing the
    /// exporter builds, so the sighting reads as never sent and the next "Export
    /// New Observations" hands eBird a second copy — which eBird keeps.
    @Test("re-keying rewrites the species and nothing else")
    func rekeyedRewritesTheSpecies() {
        let observation = LifeListEntry.Observation.at(may4, "Ithaca NY", lat: 42.45342, lon: -76.47352)
        let key = EBirdCSVExporter.key(scientificName: "Astur cooperii", observation: observation)

        let moved = EBirdCSVExporter.rekeyed(key, from: "Astur cooperii", to: "Accipiter cooperii")
        #expect(moved == EBirdCSVExporter.key(
            scientificName: "Accipiter cooperii", observation: observation
        ), "the migrated key is exactly the one the exporter would build now")
    }

    /// The legacy format differs only in its place component, which re-keying
    /// never looks at — so one function moves both formats and the ledger's
    /// compatibility read keeps working after a rename.
    @Test("re-keying moves a legacy key too, leaving its raw place intact")
    func rekeyedMovesLegacyKeys() {
        let observation = LifeListEntry.Observation.at(may4, "Ithaca, NY", lat: 1, lon: 2)
        let legacy = EBirdCSVExporter.legacyKey(scientificName: "Old name", observation: observation)

        let moved = EBirdCSVExporter.rekeyed(legacy, from: "Old name", to: "New name")
        #expect(moved == EBirdCSVExporter.legacyKey(
            scientificName: "New name", observation: observation
        ))
        #expect(moved?.contains("Ithaca, NY") == true, "the unfolded place survives")
    }

    /// A key for some other bird is not this rename's business. Returning nil
    /// rather than a rewritten string is what lets the caller walk the whole
    /// ledger against a whole rename map without filtering first.
    @Test("re-keying declines a key filed under a different species")
    func rekeyedDeclinesOtherSpecies() {
        let key = EBirdCSVExporter.key(
            scientificName: "Cardinalis cardinalis",
            observation: .at(may4, "P", lat: 1, lon: 2)
        )
        #expect(EBirdCSVExporter.rekeyed(key, from: "Astur cooperii", to: "Accipiter cooperii") == nil)
    }

    /// An identity rename has nothing to move, and saying so keeps a caller from
    /// re-inserting a key that is already there.
    @Test("re-keying declines a rename that goes nowhere")
    func rekeyedDeclinesIdentityRename() {
        let key = EBirdCSVExporter.key(scientificName: "X y", observation: .at(may4, "P"))
        #expect(EBirdCSVExporter.rekeyed(key, from: "X y", to: "X y") == nil)
    }

    /// **The species is the only field that can't contain the separator.** A
    /// place name can — `sanitize` strips quotes and commas, not pipes — so
    /// re-keying has to split once from the front rather than take the key apart
    /// into fields. A greedy split would reassemble this key wrong and silently
    /// retire a ledger entry.
    @Test("a place name containing the key separator survives re-keying")
    func rekeyedSurvivesAPipeInThePlaceName() {
        let observation = LifeListEntry.Observation.at(may4, "Ithaca | Sapsucker", lat: 1, lon: 2)
        let key = EBirdCSVExporter.key(scientificName: "Old name", observation: observation)
        #expect(key.contains("|Ithaca | Sapsucker|"), "the pipe really is in the place field")

        let moved = EBirdCSVExporter.rekeyed(key, from: "Old name", to: "New name")
        #expect(moved == EBirdCSVExporter.key(
            scientificName: "New name", observation: observation
        ))
    }

    /// A rename whose *target* is a name already in the ledger produces the key
    /// that species already has, which is what makes the migration idempotent:
    /// running it twice inserts nothing the second time.
    @Test("re-keying is idempotent under a repeated migration")
    func rekeyedIsIdempotent() {
        let observation = LifeListEntry.Observation.at(may4, "P", lat: 1, lon: 2)
        let key = EBirdCSVExporter.key(scientificName: "Old name", observation: observation)
        let once = EBirdCSVExporter.rekeyed(key, from: "Old name", to: "New name")
        #expect(once != nil)
        #expect(
            EBirdCSVExporter.rekeyed(once!, from: "Old name", to: "New name") == nil,
            "the moved key is no longer filed under the old name"
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

    // MARK: row order is a function of the data, not of the input

    /// The same life list must render the same bytes. Date + common name alone
    /// left two sightings of one species on one day comparing equal, and
    /// `Array.sorted` can return either arrangement of equal elements — so an
    /// export could differ from one run to the next with nothing having changed,
    /// which is a poor property for a file people diff and re-upload.
    @Test("the same rows in any order render byte-identical output")
    func exportIsInputOrderIndependent() {
        let observations: [LifeListEntry.Observation] = [
            .at(may4, "Sapsucker Woods", lat: 42.4791, lon: -76.4512),
            .at(may4, "Sapsucker Woods", lat: 42.4791, lon: -76.4512, imported: true),
            .at(may4, "Sapsucker Woods"),
            .at(may4, "Stewart Park", lat: 42.46, lon: -76.51),
        ]
        let rows = observations.map { row(observation: $0) }
        let expected = EBirdCSVExporter.makeCSV(rows: rows).csv
        for arrangement in [rows.reversed().map { $0 }, rows.shuffled(), rows.shuffled(), rows.shuffled()] {
            #expect(EBirdCSVExporter.makeCSV(rows: arrangement).csv == expected)
        }
    }

    /// Same day, two species: the common name decides, and nothing below it can
    /// reintroduce a wobble.
    @Test("same-day rows of different species order by name, stably")
    func sameDayDifferentSpecies() {
        let rows = [
            row("Zenaida macroura", "Mourning Dove", observation: .at(may4, "A")),
            row("Cardinalis cardinalis", "Northern Cardinal", observation: .at(may4, "A")),
        ]
        let forward = parseExportedCSV(EBirdCSVExporter.makeCSV(rows: rows)).map { $0[0] }
        let backward = parseExportedCSV(EBirdCSVExporter.makeCSV(rows: rows.reversed())).map { $0[0] }
        #expect(forward == ["Mourning Dove", "Northern Cardinal"])
        #expect(forward == backward)
    }

    // MARK: one rounding, shared with Identity

    /// The ledger key, the CSV columns, and `Observation.Identity` all describe
    /// the same coordinate. They used to round it two different ways — `%.5f`
    /// (half-to-even) in this file against `.rounded()` (half-away-from-zero) in
    /// `Identity` — so in principle they could disagree about a value landing on
    /// a half. One function now, and this is the assertion that keeps it one.
    @Test("Identity and the exporter round coordinates identically", arguments: [
        0.0, 1.0, -1.0, 42.4534198, -76.4735249, 0.000005, -0.000005,
        1.000005, 1.000015, 89.999995, -179.999995, 0.123455, 0.123465,
    ])
    func roundingAgrees(value: Double) {
        #expect(
            LifeListEntry.Observation.Identity.canonicalCoordinate(value)
                == EBirdCSVExporter.canonicalCoordinate(value)
        )
    }

    @Test("nil rounds to nil on both sides")
    func roundingAgreesOnNil() {
        #expect(EBirdCSVExporter.canonicalCoordinate(nil) == nil)
        #expect(LifeListEntry.Observation.Identity.canonicalCoordinate(nil) == nil)
    }

    /// The stronger property the shared rounding buys: what the file carries
    /// parses back to exactly the value identity will compare on, so a sighting
    /// still recognizes its own re-imported twin.
    @Test("the exported column parses back to the identity's own coordinate", arguments: [
        42.4534198, -76.4735249, 0.000005, 1.000005, 0.123455, -0.123455, 89.999995,
    ])
    func exportedColumnMatchesIdentity(value: Double) {
        let payload = EBirdCSVExporter.makeCSV(rows: [
            row(observation: .at(may4, "Somewhere", lat: value, lon: value)),
        ])
        let fields = parseExportedCSV(payload)[0]
        let parsed = Double(fields[6])
        #expect(parsed == LifeListEntry.Observation.Identity.canonicalCoordinate(value))
    }

    // MARK: unplaceable is a fact about the sighting, not a string match

    /// The tally used to be taken by comparing the exported name back against the
    /// placeholder, so a user who had genuinely named a spot "Unspecified
    /// location" was counted among the rows they would have to fix by hand on
    /// eBird's side. They have a place name like anyone else.
    @Test("a sighting the user named 'Unspecified location' is not counted as unplaceable")
    func userNamedPlaceholderIsNotUnplaceable() {
        for coordinates in [(1.0, 2.0), (nil, nil)] as [(Double?, Double?)] {
            let payload = EBirdCSVExporter.makeCSV(rows: [
                row(observation: .at(
                    may4, "Unspecified location", lat: coordinates.0, lon: coordinates.1
                )),
            ])
            #expect(parseExportedCSV(payload)[0][5] == "Unspecified location")
            #expect(payload.unplaceableCount == 0, "the user named this place")
        }
    }

    /// `isUnplaceable` has to agree exactly with the branch `exportedPlaceName`
    /// actually takes, or the alert reports a different number than the file.
    @Test("isUnplaceable agrees with the placeholder branch for every shape of input")
    func isUnplaceableMatchesTheFallback() {
        let names: [String?] = [nil, "", "   ", ",", "\"", "Named", "Unspecified location"]
        let coordinates: [(Double?, Double?)] = [(nil, nil), (1, nil), (nil, 2), (1, 2)]
        for name in names {
            for (lat, lon) in coordinates {
                let exported = EBirdCSVExporter.exportedPlaceName(
                    location: name, latitude: lat, longitude: lon
                )
                let flagged = EBirdCSVExporter.isUnplaceable(
                    location: name, latitude: lat, longitude: lon
                )
                // The one case where the two can legitimately differ is a user
                // who typed the placeholder themselves.
                let tookTheFallback = exported == "Unspecified location"
                    && EBirdCSVExporter.sanitize(name ?? "").isEmpty
                #expect(flagged == tookTheFallback, "\(name ?? "nil") \(String(describing: lat))")
            }
        }
    }

    /// Half a coordinate is no coordinate: `exportedPlaceName` needs both to
    /// build its fallback, so the tally has to require both too.
    @Test("one coordinate without the other is still unplaceable")
    func halfACoordinateIsUnplaceable() {
        for (lat, lon) in [(1.0, nil), (nil, 2.0)] as [(Double?, Double?)] {
            let payload = EBirdCSVExporter.makeCSV(rows: [
                row(observation: .at(may4, nil, lat: lat, lon: lon)),
            ])
            #expect(parseExportedCSV(payload)[0][5] == "Unspecified location")
            #expect(payload.unplaceableCount == 1)
        }
    }

    @Test("the suggested filename carries the save date")
    func defaultFilename() {
        let name = EBirdCSVExporter.defaultFilename(date: utcDay(2026, 5, 4))
        #expect(name.hasPrefix("Kestrel Life List "))
        #expect(!name.contains("/"), "a slash would break the save panel")
    }
}
