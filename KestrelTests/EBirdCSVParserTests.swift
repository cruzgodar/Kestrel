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

    /// The check has to run on the columns as eBird wrote them, because both
    /// transforms that follow destroy the evidence: `speciesBinomial` collapses
    /// `"Anas platyrhynchos x rubripes"` to a clean-looking `"Anas
    /// platyrhynchos"`, and `stripParens` removes the parenthetical eBird puts
    /// the marker in for its *named* hybrids.
    ///
    /// Asked afterwards, both halves were blind and the row was filed as its
    /// first parent species — a Brewster's Warbler landing on the user's
    /// Golden-winged Warbler entry, and (see `LifeListStoreImportTests`)
    /// renaming it.
    @Test(
        "a hybrid is filtered however eBird marks it",
        arguments: [
            // Marker only in the scientific name: survived the binomial collapse.
            (sci: "Anas platyrhynchos x rubripes", common: "Some Duck"),
            // Marker in the common name too, as eBird usually writes it.
            (sci: "Anas platyrhynchos x rubripes", common: "Mallard x American Black Duck"),
            // eBird's *named* hybrids: the only marker is inside a parenthetical,
            // which `stripParens` removes, and the scientific name is the cross.
            (sci: "Vermivora chrysoptera x cyanoptera",
             common: "Brewster's Warbler (Golden-winged x Blue-winged)"),
            (sci: "Vermivora cyanoptera x chrysoptera", common: "Lawrence's Warbler (hybrid)"),
            // A hybrid eBird labelled but did not cross the scientific name of —
            // the second net in `isNonSpecies`.
            (sci: "Vermivora chrysoptera", common: "Some Warbler (hybrid)"),
        ]
    )
    func hybridsFiltered(name: (sci: String, common: String)) throws {
        let rows = try parse([
            (name.sci, name.common, "2019-05-04", "P", 1.0, 1.0),
            ("Cardinalis cardinalis", "Northern Cardinal", "2019-05-04", "P", 1.0, 1.0),
        ])
        #expect(rows.map(\.scientificName) == ["Cardinalis cardinalis"],
                "\(name.common.debugDescription) should not reach the life list")
    }

    /// The other side of the same rule, and why it can't be a plain substring
    /// test: at *subspecies* rank an `x` or a `/` doesn't make the species
    /// uncertain. An intergrade of two Yellow-rumped Warbler races is still a
    /// Yellow-rumped Warbler, and a record narrowed to "one of these two races"
    /// still names the bird — both belong on the life list, collapsed onto the
    /// binomial like any other subspecies row.
    @Test(
        "subspecies-level crosses and slashes are still real species",
        arguments: [
            (sci: "Setophaga coronata auduboni x coronata",
             common: "Yellow-rumped Warbler (Myrtle x Audubon's)"),
            (sci: "Setophaga coronata coronata/auduboni",
             common: "Yellow-rumped Warbler (Myrtle/Audubon's)"),
            (sci: "Junco hyemalis hyemalis x oreganus",
             common: "Dark-eyed Junco (Slate-colored x Oregon)"),
        ]
    )
    func subspeciesCrossesKept(name: (sci: String, common: String)) throws {
        let rows = try parse([(name.sci, name.common, "2019-05-04", "P", 1.0, 1.0)])
        #expect(rows.count == 1, "\(name.common.debugDescription) is a real sighting")
        #expect(rows.first?.scientificName == name.sci.split(separator: " ").prefix(2).joined(separator: " "))
    }

    /// `namesOneSpecies` decides by *position*, so the unit cases are worth
    /// pinning directly — the parser-level tests above can only reach it through
    /// a whole CSV.
    @Test(
        "namesOneSpecies reads the rank the marker sits at",
        arguments: [
            (name: "Cardinalis cardinalis", isSpecies: true),
            (name: "Larus", isSpecies: true),
            (name: "Dryobates villosus harrisi", isSpecies: true),
            (name: "Setophaga coronata auduboni x coronata", isSpecies: true),
            (name: "Setophaga coronata coronata/auduboni", isSpecies: true),
            (name: "Vermivora chrysoptera x cyanoptera", isSpecies: false),
            (name: "Anas platyrhynchos x rubripes", isSpecies: false),
            (name: "Aythya marila/affinis", isSpecies: false),
            (name: "Larus sp.", isSpecies: false),
            (name: "", isSpecies: false),
        ]
    )
    func namesOneSpeciesByRank(c: (name: String, isSpecies: Bool)) {
        #expect(EBirdCSVParser.namesOneSpecies(c.name) == c.isSpecies)
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

    /// Domestic and feral forms are *not* skipped the way spuhs and hybrids are —
    /// their parenthetical is stripped and the row is filed under the nominate
    /// species. eBird doesn't count them as separate species either, and anyone
    /// with a domestic Mallard on their list has a wild one too.
    ///
    /// The doc comment on `parse` used to claim they were filtered out, which
    /// described neither what the code did nor what it should do.
    @Test(
        "domestic and feral forms are filed under the nominate species, not dropped",
        arguments: [
            (sci: "Anas platyrhynchos", common: "Mallard (Domestic type)",
             expectCommon: "Mallard"),
            (sci: "Columba livia", common: "Rock Pigeon (Feral Pigeon)",
             expectCommon: "Rock Pigeon"),
            (sci: "Anser anser", common: "Graylag Goose (Domestic type)",
             expectCommon: "Graylag Goose"),
        ]
    )
    func domesticFormsAreKept(
        c: (sci: String, common: String, expectCommon: String)
    ) throws {
        let rows = try parse([(c.sci, c.common, "2019-05-04", "P", 1.0, 1.0)])
        #expect(rows.count == 1, "\(c.common.debugDescription) is still a real sighting")
        #expect(rows[0].scientificName == c.sci)
        #expect(rows[0].commonName == c.expectCommon)
    }

    /// The domestic form and the wild bird are one species, so an import carrying
    /// both must not produce two life-list entries.
    @Test("a domestic form and the wild bird converge on one species")
    func domesticFormConvergesWithWild() throws {
        let rows = try parse([
            ("Anas platyrhynchos", "Mallard (Domestic type)", "2019-05-04", "P", 1.0, 1.0),
            ("Anas platyrhynchos", "Mallard", "2020-05-04", "P", 1.0, 1.0),
        ])
        #expect(rows.count == 2, "both sightings are kept")
        #expect(Set(rows.map(\.scientificName)) == ["Anas platyrhynchos"])
        #expect(Set(rows.map(\.commonName)) == ["Mallard"])
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
