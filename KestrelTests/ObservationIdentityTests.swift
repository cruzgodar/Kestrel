import Foundation
import Testing
@testable import Kestrel

/// `LifeListEntry.Observation.Identity` — what makes two records the *same*
/// sighting.
///
/// The bug these guard: identity compared the raw stored coordinate and place
/// name, while the eBird export writes coordinates at five decimal places and
/// folds the place name (no quotes, no commas — the CSV can't escape them). The
/// app tells users to export to eBird and re-import periodically, so a sighting
/// recorded in Kestrel came back from that trip *not equal to itself*, was filed
/// as a second observation, and showed up as a duplicate pin on the map and a
/// doubled "N Observations".
@Suite("Observation.Identity")
struct ObservationIdentityTests {

    private let day = utcDay(2026, 5, 4)

    // MARK: the round trip

    /// The headline case, end to end through the two transforms the export
    /// actually applies.
    @Test("a sighting survives the export fold and matches itself on re-import")
    func survivesRoundTrip() {
        let original = LifeListEntry.Observation.at(
            day, "Ithaca, NY", lat: 42.4534198, lon: -76.4735178
        )

        // Exactly what the CSV carries, and therefore what eBird hands back.
        let exportedPlace = EBirdCSVExporter.sanitize("Ithaca, NY")
        let exportedLat = Double(String(format: "%.5f", 42.4534198))!
        let exportedLon = Double(String(format: "%.5f", -76.4735178))!
        let reimported = LifeListEntry.Observation.at(
            day, exportedPlace, lat: exportedLat, lon: exportedLon, imported: true
        )

        #expect(exportedPlace == "Ithaca NY", "the comma is what the CSV cannot carry")
        #expect(original.identity == reimported.identity)
        #expect(original.identity.hashValue == reimported.identity.hashValue)
    }

    /// Coordinates are the half that fails silently — the place name at least
    /// looks different when you read it.
    @Test("coordinates below the CSV's precision don't split a sighting in two")
    func coordinatePrecisionFolded() {
        let precise = LifeListEntry.Observation.at(day, "Sapsucker Woods", lat: 42.45341984, lon: -76.47351779)
        let rounded = LifeListEntry.Observation.at(day, "Sapsucker Woods", lat: 42.45342, lon: -76.47352)
        #expect(precise.identity == rounded.identity)
    }

    /// Rounding must not become *merging*. Five decimals is about a metre; two
    /// pins a stone's throw apart are still two places.
    @Test("distinct places stay distinct")
    func distinctPlacesStayDistinct() {
        let a = LifeListEntry.Observation.at(day, "Ithaca NY", lat: 42.45342, lon: -76.47352)
        // ~33 m north.
        let b = LifeListEntry.Observation.at(day, "Ithaca NY", lat: 42.45372, lon: -76.47352)
        // ~25 m east.
        let c = LifeListEntry.Observation.at(day, "Ithaca NY", lat: 42.45342, lon: -76.47322)
        #expect(a.identity != b.identity)
        #expect(a.identity != c.identity)
    }

    /// Two decimal places apart at the *sixth* place is below the fold; at the
    /// fifth it is not. This pins the boundary so a future change to the rounding
    /// can't quietly widen it.
    @Test("the fold is at five decimal places, not four or six")
    func foldBoundary() {
        let base = 42.400000
        let sixthPlace = LifeListEntry.Observation.at(day, nil, lat: base + 0.000001, lon: 0)
        let fifthPlace = LifeListEntry.Observation.at(day, nil, lat: base + 0.00001, lon: 0)
        let reference = LifeListEntry.Observation.at(day, nil, lat: base, lon: 0)
        #expect(reference.identity == sixthPlace.identity, "a millionth of a degree is below the CSV's precision")
        #expect(reference.identity != fifthPlace.identity, "a hundred-thousandth is what the CSV carries")
    }

    // MARK: place-name folding

    /// Everything `sanitize` removes, and therefore everything the round trip
    /// would otherwise change.
    @Test(
        "place names differing only by what the CSV strips are the same place",
        arguments: [
            ("Ithaca, NY", "Ithaca NY"),
            ("\"Quoted Marsh\"", "Quoted Marsh"),
            ("\u{201C}Curly Marsh\u{201D}", "Curly Marsh"),
            ("Line\nBreak", "Line Break"),
            ("Tab\tSeparated", "Tab Separated"),
            ("Double  Spaced", "Double Spaced"),
            ("  Leading and trailing  ", "Leading and trailing"),
            ("Comma,,Doubled", "Comma Doubled"),
        ]
    )
    func placeNameFolding(raw: String, folded: String) {
        let a = LifeListEntry.Observation.at(day, raw, lat: 1, lon: 2)
        let b = LifeListEntry.Observation.at(day, folded, lat: 1, lon: 2)
        #expect(a.identity == b.identity, "\(raw.debugDescription) should fold to \(folded.debugDescription)")
    }

    /// An empty place name and no place name are the same thing everywhere the
    /// app displays one, so they have to be the same thing to identity too —
    /// otherwise the two would be separate sightings that render identically.
    @Test("an empty or blank place name is the same as none", arguments: ["", " ", "   ", "\n", "\t "])
    func blankPlaceIsNoPlace(blank: String) {
        let blankNamed = LifeListEntry.Observation.at(day, blank, lat: 1, lon: 2)
        let unnamed = LifeListEntry.Observation.at(day, nil, lat: 1, lon: 2)
        #expect(blankNamed.identity == unnamed.identity)
    }

    /// Case and real wording are still meaningful — folding is about characters
    /// the format can't carry, not about being loose.
    @Test("folding doesn't erase genuine differences in wording")
    func foldingIsNarrow() {
        let a = LifeListEntry.Observation.at(day, "Sapsucker Woods", lat: 1, lon: 2)
        let b = LifeListEntry.Observation.at(day, "sapsucker woods", lat: 1, lon: 2)
        let c = LifeListEntry.Observation.at(day, "Sapsucker Woods Pond", lat: 1, lon: 2)
        #expect(a.identity != b.identity, "case is a real difference in a name the user typed")
        #expect(a.identity != c.identity)
    }

    // MARK: the rest of the identity

    /// Provenance is explicitly *not* part of identity: a bird added by hand and
    /// later restated by an import is one observation, not two.
    @Test("isImported is provenance, not identity")
    func provenanceExcluded() {
        let native = LifeListEntry.Observation.at(day, "Ithaca NY", lat: 1, lon: 2, imported: false)
        let imported = LifeListEntry.Observation.at(day, "Ithaca NY", lat: 1, lon: 2, imported: true)
        #expect(native.identity == imported.identity)
        #expect(native != imported, "the observations themselves still differ")
    }

    @Test("the date is part of identity")
    func dateMatters() {
        let a = LifeListEntry.Observation.at(utcDay(2026, 5, 4), "Ithaca NY", lat: 1, lon: 2)
        let b = LifeListEntry.Observation.at(utcDay(2026, 5, 5), "Ithaca NY", lat: 1, lon: 2)
        #expect(a.identity != b.identity)
    }

    /// A sighting with no coordinate is a real thing (an eBird row with blank
    /// lat/lon), and must not collide with one that has coordinates.
    @Test("a missing coordinate is distinct from a present one")
    func missingCoordinateDistinct() {
        let placed = LifeListEntry.Observation.at(day, "Ithaca NY", lat: 42.45342, lon: -76.47352)
        let unplaced = LifeListEntry.Observation.at(day, "Ithaca NY")
        let halfPlaced = LifeListEntry.Observation.at(day, "Ithaca NY", lat: 42.45342, lon: nil)
        #expect(placed.identity != unplaced.identity)
        #expect(placed.identity != halfPlaced.identity)
        #expect(unplaced.identity != halfPlaced.identity)
    }

    @Test("hasCoordinate requires both halves")
    func hasCoordinate() {
        #expect(LifeListEntry.Observation.at(day, nil, lat: 1, lon: 2).hasCoordinate)
        #expect(!LifeListEntry.Observation.at(day, nil, lat: 1, lon: nil).hasCoordinate)
        #expect(!LifeListEntry.Observation.at(day, nil, lat: nil, lon: 2).hasCoordinate)
        #expect(!LifeListEntry.Observation.at(day).hasCoordinate)
    }

    /// Negative coordinates round the same way positive ones do — the southern
    /// and western hemispheres are not a special case.
    @Test("rounding is symmetric about zero")
    func negativeRounding() {
        let west = LifeListEntry.Observation.at(day, nil, lat: -42.4534198, lon: -76.4735178)
        let westRounded = LifeListEntry.Observation.at(day, nil, lat: -42.45342, lon: -76.47352)
        #expect(west.identity == westRounded.identity)
    }

    /// Identity is used as a dictionary key throughout the merge paths, so equal
    /// identities must hash equally — an inconsistent `Hashable` would make
    /// dedupe silently miss.
    @Test("equal identities hash equally across the fold")
    func hashingConsistent() {
        let raw = LifeListEntry.Observation.at(day, "Ithaca, NY", lat: 42.4534198, lon: -76.4735178)
        let folded = LifeListEntry.Observation.at(day, "Ithaca NY", lat: 42.45342, lon: -76.47352)
        var set = Set<LifeListEntry.Observation.Identity>()
        set.insert(raw.identity)
        set.insert(folded.identity)
        #expect(set.count == 1)
    }
}
