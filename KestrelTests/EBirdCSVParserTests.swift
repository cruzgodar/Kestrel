import Foundation
import Testing
@testable import Kestrel

/// The eBird "My eBird Data" CSV reader.
///
/// Dates are parsed **in UTC**, so a bare day in the file becomes midnight UTC on
/// that day — the form every stored sighting takes. Parsing in the device's zone
/// instead made an import's dates depend on where the phone was when the file was
/// opened, which is the same defect the whole `ObservationDate` invariant exists
/// to close.
@Suite("EBirdCSVParser")
struct EBirdCSVParserTests {

    private func parse(_ rows: [(sci: String, common: String, date: String, location: String?, lat: Double?, lon: Double?)]) throws -> [EBirdRawRow] {
        try EBirdCSVParser.parse(eBirdCSV(rows))
    }

    // MARK: dates

    @Test("an ISO date becomes midnight UTC on that day")
    func isoDateParsedAsUTC() throws {
        let rows = try parse([("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "P", 1.0, 1.0)])
        #expect(rows.count == 1)
        #expect(rows[0].date == utcDay(2019, 5, 4))
    }

    @Test("the US date format is accepted as a fallback")
    func usDateParsedAsUTC() throws {
        let rows = try parse([("Cardinalis cardinalis", "Northern Cardinal", "05/04/2019", "P", 1.0, 1.0)])
        #expect(rows.count == 1)
        #expect(rows[0].date == utcDay(2019, 5, 4))
    }

    /// Whatever the device's zone, the same file yields the same instants — this
    /// is the property that makes an import reproducible.
    @Test("every parsed date is already canonical")
    func parsedDatesAreCanonical() throws {
        let rows = try parse([
            ("A a", "A", "2019-01-01", "P", 1.0, 1.0),
            ("B b", "B", "2019-06-15", "P", 1.0, 1.0),
            ("C c", "C", "2019-12-31", "P", 1.0, 1.0),
            ("D d", "D", "2020-02-29", "P", 1.0, 1.0),
        ])
        #expect(rows.count == 4)
        for row in rows {
            #expect(row.date == ObservationDate.canonical(row.date, in: TestZones.utc))
            #expect(ObservationDate.isoDay(row.date) == ObservationDate.isoDay(row.date))
        }
        #expect(ObservationDate.isoDay(rows[0].date) == "2019-01-01")
        #expect(ObservationDate.isoDay(rows[3].date) == "2020-02-29")
    }

    @Test("a row with an unparseable date is skipped rather than guessed at")
    func unparseableDateSkipped() throws {
        let rows = try parse([
            ("A a", "A", "not a date", "P", 1.0, 1.0),
            ("B b", "B", "2019-05-04", "P", 1.0, 1.0),
        ])
        #expect(rows.map(\.scientificName) == ["B b"])
    }

    // MARK: fields

    @Test("coordinates and location come through")
    func fieldsParsed() throws {
        let rows = try parse([
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "Sapsucker Woods", 42.4791, -76.4512),
        ])
        #expect(rows[0].scientificName == "Cardinalis cardinalis")
        #expect(rows[0].commonName == "Northern Cardinal")
        #expect(rows[0].location == "Sapsucker Woods")
        #expect(rows[0].latitude == 42.4791)
        #expect(rows[0].longitude == -76.4512)
    }

    /// eBird rows without coordinates are common in older exports; they still
    /// carry a real sighting.
    @Test("a row with blank coordinates parses with none")
    func blankCoordinates() throws {
        let rows = try parse([("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "Somewhere", nil, nil)])
        #expect(rows.count == 1)
        #expect(rows[0].latitude == nil)
        #expect(rows[0].longitude == nil)
        #expect(rows[0].location == "Somewhere")
    }

    /// The test builder quotes any field containing a comma, exactly as eBird's
    /// export does — so the parser has to honor quoting even though the *writer*
    /// is forbidden from emitting it.
    @Test("a quoted field containing a comma is read as one field")
    func quotedFieldWithComma() throws {
        let rows = try parse([
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "Ithaca, NY", 42.4791, -76.4512),
        ])
        #expect(rows.count == 1)
        #expect(rows[0].location == "Ithaca, NY")
        #expect(rows[0].latitude == 42.4791, "the comma must not have shifted the columns")
    }

    @Test("an empty file parses to no rows")
    func emptyFile() throws {
        #expect(try EBirdCSVParser.parse(Data()).isEmpty)
    }

    @Test("a header-only file parses to no rows")
    func headerOnly() throws {
        #expect(try parse([]).isEmpty)
    }

    // MARK: filtering

    /// Spuhs, hybrids, and domestic forms aren't species and have no place on a
    /// life list — filtering here keeps the store from having to know about them.
    @Test(
        "non-species rows are filtered out",
        arguments: [
            (sci: "Buteo sp.", common: "Buteo sp."),
            (sci: "Anas platyrhynchos x rubripes", common: "Mallard x American Black Duck"),
            (sci: "Anser sp.", common: "Goose sp. (domestic type)"),
            (sci: "Aythya marila/affinis", common: "Greater/Lesser Scaup"),
            (sci: "", common: "Nameless"),
        ]
    )
    func nonSpeciesFiltered(name: (sci: String, common: String)) throws {
        let rows = try parse([
            (name.sci, name.common, "2019-05-04", "P", 1.0, 1.0),
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "P", 1.0, 1.0),
        ])
        #expect(rows.map(\.scientificName) == ["Cardinalis cardinalis"],
                "\(name.common.debugDescription) should not reach the life list")
    }

    /// Worth pinning explicitly, because it is not obvious from either function
    /// alone: the scientific name is collapsed to its binomial *before* the
    /// unidentified check runs, so `"Anas platyrhynchos x rubripes"` is already
    /// `"Anas platyrhynchos"` by the time the `" x "` test sees it. What actually
    /// catches hybrids is the **common name**, which is not collapsed — and which
    /// is how eBird writes them ("Mallard x American Black Duck").
    ///
    /// So the two checks are not redundant, and dropping the common-name half
    /// would silently start filing hybrids as their first parent species.
    @Test("the common-name column is what actually catches a hybrid")
    func hybridCaughtByCommonName() throws {
        // Marker only in the scientific name: collapsed away, so the row survives.
        let sciOnly = try parse([
            ("Anas platyrhynchos x rubripes", "Some Duck", "2019-05-04", "P", 1.0, 1.0),
        ])
        #expect(sciOnly.map(\.scientificName) == ["Anas platyrhynchos"])

        // Marker in the common name, as eBird writes it: filtered.
        let realistic = try parse([
            ("Anas platyrhynchos x rubripes", "Mallard x American Black Duck", "2019-05-04", "P", 1.0, 1.0),
        ])
        #expect(realistic.isEmpty)
    }

    /// The other half of the same rule, and the reason the filter can't simply
    /// reject anything parenthesized: eBird's subspecies groups and its
    /// disambiguated forms both arrive in parentheses, and both are real records
    /// of a real species. They are *stripped*, not filtered — and the trinomial is
    /// collapsed — so two subspecies groups of one bird land on one entry.
    @Test(
        "parenthesized clarifiers are stripped, not treated as unidentified",
        arguments: [
            (sci: "Dryobates villosus harrisi", common: "Hairy Woodpecker (Pacific)",
             expectSci: "Dryobates villosus", expectCommon: "Hairy Woodpecker"),
            (sci: "Columba livia", common: "Rock Pigeon (Feral Pigeon)",
             expectSci: "Columba livia", expectCommon: "Rock Pigeon"),
            (sci: "Junco hyemalis hyemalis", common: "Dark-eyed Junco (Slate-colored)",
             expectSci: "Junco hyemalis", expectCommon: "Dark-eyed Junco"),
        ]
    )
    func parentheticalsStripped(
        c: (sci: String, common: String, expectSci: String, expectCommon: String)
    ) throws {
        let rows = try parse([(c.sci, c.common, "2019-05-04", "P", 1.0, 1.0)])
        #expect(rows.count == 1, "\(c.common.debugDescription) is a real sighting")
        #expect(rows[0].scientificName == c.expectSci)
        #expect(rows[0].commonName == c.expectCommon)
    }

    /// Removing a parenthetical leaves a gap where it was, and a single
    /// `"  "` → `" "` pass only closes gaps of exactly two: `replacingOccurrences`
    /// doesn't rescan what it has written, so a run of three comes out as two.
    /// One clarifier between two words leaves two spaces and was handled; two
    /// space-separated clarifiers mid-name leave three, and that doubled space
    /// rode through into the stored — and displayed — common name.
    @Test(
        "the whitespace a stripped parenthetical leaves behind is fully collapsed",
        arguments: [
            // The shapes that leave a run of three, which is what actually broke.
            "Hairy Woodpecker (Eastern) (Pacific) Group",
            "Hairy   Woodpecker",
            // And the shapes that already worked, kept so closing the above can't
            // regress them.
            "Hairy (Eastern) Woodpecker",
            "Hairy Woodpecker (Eastern) (Pacific)",
            "Hairy Woodpecker (Eastern)  ",
            "  (Eastern) Hairy Woodpecker",
            "Hairy (a)(b)(c) Woodpecker",
        ]
    )
    func parentheticalWhitespaceCollapsed(raw: String) throws {
        let rows = try parse([("Dryobates villosus", raw, "2019-05-04", "P", 1.0, 1.0)])
        let name = rows[0].commonName
        #expect(!name.contains("  "), "\(raw.debugDescription) → \(name.debugDescription)")
        #expect(name == name.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(name.contains("Hairy"))
        #expect(name.contains("Woodpecker"))
    }

    /// Two subspecies groups of one bird arriving as separate rows must reduce to
    /// one species — that's what the stripping and the binomial collapse are for.
    @Test("two subspecies groups reduce to the same species")
    func subspeciesGroupsConverge() throws {
        let rows = try parse([
            ("Dryobates villosus harrisi", "Hairy Woodpecker (Pacific)", "2019-05-04", "P", 1.0, 1.0),
            ("Dryobates villosus villosus", "Hairy Woodpecker (Eastern)", "2020-05-04", "P", 1.0, 1.0),
        ])
        #expect(rows.count == 2, "both sightings are kept")
        #expect(Set(rows.map(\.scientificName)) == ["Dryobates villosus"], "under one species")
        #expect(Set(rows.map(\.commonName)) == ["Hairy Woodpecker"])
    }

    @Test("ordinary binomials and trinomials are kept")
    func realSpeciesKept() throws {
        let rows = try parse([
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "P", 1.0, 1.0),
            ("Dryobates villosus harrisi", "Hairy Woodpecker", "2019-05-04", "P", 1.0, 1.0),
        ])
        #expect(rows.count == 2)
    }

    // MARK: volume

    @Test("a large export parses in full")
    func largeExport() throws {
        let rows = (0..<2_000).map { i in
            (sci: "Genus sp\(i)", common: "Bird \(i)", date: "2019-05-04",
             location: "Place \(i)" as String?, lat: 42.0 as Double?, lon: -76.0 as Double?)
        }
        #expect(try parse(rows).count == 2_000)
    }
}
