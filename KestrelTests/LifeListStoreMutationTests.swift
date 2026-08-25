import CoreLocation
import Foundation
import Testing
@testable import Kestrel

/// Add, edit, delete, star, and the export ledger — the paths where the *user*
/// writes to their own list. The governing rule everywhere here is that a user's
/// record must never disappear without them asking.
@Suite("LifeListStore mutations")
@MainActor
struct LifeListStoreMutationTests {

    private let may4 = utcDay(2026, 5, 4)
    private let may5 = utcDay(2026, 5, 5)
    private let may6 = utcDay(2026, 5, 6)

    // MARK: adding

    @Test("recordObservation creates the entry the first time a species is seen")
    func recordCreatesEntry() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(
            scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal",
            date: may4, location: "Sapsucker Woods", latitude: 42.4791, longitude: -76.4512
        )
        #expect(store.entries.count == 1)
        #expect(store.entries[0].firstSeen == may4)
        #expect(store.entries[0].firstLocation == "Sapsucker Woods")
        #expect(store.speciesNames.contains("Cardinalis cardinalis"))
    }

    /// A sighting the user recorded in Kestrel has never been to eBird, so it
    /// must not be marked as imported — that flag is what keeps the export from
    /// sending it.
    @Test("a recorded sighting is not marked imported")
    func recordedSightingIsNative() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(
            scientificName: "X y", commonName: "X", date: may4,
            location: "P", latitude: 1, longitude: 2
        )
        #expect(!store.entries[0].firstIsImported)
        #expect(store.observationCount(for: .newOnly) == 1, "it should be offered to eBird")
    }

    @Test("recordObservation files a second sighting under an existing species")
    func recordAddsToExisting() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "A", latitude: 1, longitude: 1)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may5,
                                location: "B", latitude: 2, longitude: 2)
        #expect(store.entries.count == 1, "one species, two sightings")
        #expect(store.entries[0].allObservations.count == 2)
    }

    @Test("a sighting earlier than the current first-seen is promoted")
    func earlierSightingPromoted() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may5,
                                location: "Later", latitude: 2, longitude: 2)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "Earlier", latitude: 1, longitude: 1)
        #expect(store.entries[0].firstSeen == may4)
        #expect(store.entries[0].firstLocation == "Earlier")
        #expect(store.entries[0].otherObservations.map(\.location) == ["Later"])
    }

    /// Two identical sightings the user recorded on purpose both stand. This is
    /// the `dedupe: false` rule at the store level.
    @Test("recording the same sighting twice keeps both")
    func duplicateRecordsKept() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        for _ in 0..<2 {
            store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                    location: "Same", latitude: 1, longitude: 1)
        }
        #expect(store.entries[0].allObservations.count == 2)
        #expect(store.totalObservationCount == 2)
    }

    @Test("add is a no-op for a species already on the list")
    func addIsIdempotent() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        #expect(store.add(scientificName: "X y", commonName: "X", firstSeen: may4))
        #expect(!store.add(scientificName: "X y", commonName: "Different", firstSeen: may5))
        #expect(store.entries.count == 1)
        #expect(store.entries[0].commonName == "X")
    }

    @Test("addObservation is a no-op for a species not on the list")
    func addObservationRequiresEntry() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.addObservation(scientificName: "Nope nope", date: may4, location: "P")
        #expect(store.entries.isEmpty)
    }

    // MARK: editing

    @Test("replaceObservation rewrites a sighting in place")
    func replaceRewrites() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "Wrong", latitude: 1, longitude: 1)
        let original = store.entries[0].allObservations[0].identity

        store.replaceObservation(
            scientificName: "X y", original: original,
            date: may5, location: "Right", latitude: 3, longitude: 3
        )
        #expect(store.entries[0].allObservations.count == 1, "an edit is not an add")
        #expect(store.entries[0].firstSeen == may5)
        #expect(store.entries[0].firstLocation == "Right")
    }

    /// Editing the earliest sighting to a later date has to re-promote whichever
    /// sighting is now earliest into the displayed fields.
    @Test("editing the earliest sighting later re-promotes the new earliest")
    func editRepromotes() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "First", latitude: 1, longitude: 1)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may5,
                                location: "Second", latitude: 2, longitude: 2)
        let earliest = store.entries[0].allObservations.first { $0.location == "First" }!

        store.replaceObservation(
            scientificName: "X y", original: earliest.identity,
            date: may6, location: "Moved to last", latitude: 1, longitude: 1
        )
        #expect(store.entries[0].firstSeen == may5)
        #expect(store.entries[0].firstLocation == "Second")
        #expect(store.entries[0].allObservations.count == 2)
    }

    /// The failure this guards: correcting one imported sighting's date onto a
    /// same-place sibling's date produces an identical identity. With dedupe on,
    /// the two silently collapsed into one — no warning, no undo.
    @Test("editing a sighting onto a sibling's identity keeps both records")
    func editOntoSiblingKeepsBoth() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "Same Place", latitude: 1, longitude: 1)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may5,
                                location: "Same Place", latitude: 1, longitude: 1)
        let toEdit = store.entries[0].allObservations.first { $0.date == may5 }!

        // Correct its date onto the sibling's — now identical in every field.
        store.replaceObservation(
            scientificName: "X y", original: toEdit.identity,
            date: may4, location: "Same Place", latitude: 1, longitude: 1
        )
        #expect(store.entries[0].allObservations.count == 2, "an edit must never delete a record")
    }

    /// An edited eBird row still corresponds to a record that account holds, so
    /// it must not start looking new to "Export New Observations."
    @Test("provenance rides along through an edit")
    func editKeepsProvenance() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeLifeList([
            .make(scientificName: "X y", commonName: "X", isStarred: false,
                  observations: [.at(may4, "P", lat: 1, lon: 1, imported: true)], dedupe: false),
        ])
        let store = makeStore(scratch, defaults)
        let original = store.entries[0].allObservations[0].identity

        store.replaceObservation(scientificName: "X y", original: original,
                                 date: may5, location: "Corrected", latitude: 1, longitude: 1)
        #expect(store.entries[0].firstIsImported, "it still came from eBird")
        #expect(store.observationCount(for: .newOnly) == 0, "and must not be sent back")
    }

    /// The ledger is keyed on date, place and coordinates, so correcting any of
    /// them would orphan the old key and make an already-uploaded sighting look
    /// new — and eBird, which does no deduplication, would take the next export's
    /// copy as a second record rather than a correction.
    @Test("an edited sighting stays out of the next Export New")
    func editCarriesLedgerEntry() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "Original", latitude: 1, longitude: 1)
        let observation = store.entries[0].allObservations[0]
        store.markExported([EBirdCSVExporter.key(scientificName: "X y", observation: observation)])
        #expect(store.observationCount(for: .newOnly) == 0)

        store.replaceObservation(scientificName: "X y", original: observation.identity,
                                 date: may5, location: "Corrected", latitude: 9, longitude: 9)
        #expect(store.observationCount(for: .newOnly) == 0,
                "a correction is not a new record for eBird to file twice")
    }

    @Test("replaceObservation is a no-op when the sighting isn't there")
    func replaceUnknownIsNoOp() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        let before = store.entries
        store.replaceObservation(
            scientificName: "X y",
            original: LifeListEntry.Observation.at(may6, "Nowhere").identity,
            date: may5, location: "Q", latitude: 2, longitude: 2
        )
        #expect(store.entries == before)
    }

    // MARK: deleting

    @Test("removeObservation removes exactly one sighting")
    func removeOne() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        for (date, place) in [(may4, "A"), (may5, "B"), (may6, "C")] {
            store.recordObservation(scientificName: "X y", commonName: "X", date: date,
                                    location: place, latitude: 1, longitude: 1)
        }
        let target = store.entries[0].allObservations.first { $0.location == "B" }!
        store.removeObservation(scientificName: "X y", identity: target.identity)
        #expect(store.entries[0].allObservations.map(\.location) == ["A", "C"])
    }

    @Test("removing one of two identical sightings leaves the other")
    func removeOneOfIdenticalPair() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        for _ in 0..<2 {
            store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                    location: "Same", latitude: 1, longitude: 1)
        }
        let identity = store.entries[0].allObservations[0].identity
        store.removeObservation(scientificName: "X y", identity: identity)
        #expect(store.entries[0].allObservations.count == 1, "one delete removes one record")
    }

    /// A bird with no observations left is a bird that was never seen.
    @Test("deleting the last sighting drops the species from the list")
    func deletingLastDropsSpecies() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        store.removeObservation(
            scientificName: "X y",
            identity: store.entries[0].allObservations[0].identity
        )
        #expect(store.entries.isEmpty)
        #expect(store.speciesNames.isEmpty, "membership has to keep up with the delete")
    }

    /// Deliberate: a star is a standing instruction about a species, not a
    /// property of one sighting. Losing it because the last record was deleted
    /// would be the more surprising outcome.
    @Test("a star outlives the species leaving the list, and comes back with it")
    func starOutlivesDeletion() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        store.setStarred(scientificName: "X y", isStarred: true)
        store.removeObservation(
            scientificName: "X y",
            identity: store.entries[0].allObservations[0].identity
        )
        #expect(store.entries.isEmpty)
        #expect(store.starredNames.contains("X y"), "it still fires alerts")

        store.recordObservation(scientificName: "X y", commonName: "X", date: may5,
                                location: "Q", latitude: 1, longitude: 1)
        #expect(store.entries[0].isStarred, "re-adding must not show an empty star")
    }

    @Test("removeAll clears every entry but keeps the stars")
    func removeAllKeepsStars() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "A a", commonName: "A", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        store.recordObservation(scientificName: "B b", commonName: "B", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        store.setStarred(scientificName: "A a", isStarred: true)

        store.removeAll()
        #expect(store.entries.isEmpty)
        #expect(store.speciesNames.isEmpty)
        #expect(store.starredNames == ["A a"])
    }

    @Test("removeObservation is a no-op for an unknown species or identity")
    func removeUnknownIsNoOp() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        let before = store.entries
        store.removeObservation(scientificName: "Not here", identity: before[0].allObservations[0].identity)
        store.removeObservation(scientificName: "X y",
                                identity: LifeListEntry.Observation.at(may6, "Nowhere").identity)
        #expect(store.entries == before)
    }

    // MARK: stars

    @Test("stars persist separately and survive a wipe-and-reimport")
    func starsPersistSeparately() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        do {
            let store = makeStore(scratch, defaults)
            store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                    location: "P", latitude: 1, longitude: 1)
            store.setStarred(scientificName: "X y", isStarred: true)
            store.removeAll()
            store.flushPendingWrites()
        }
        #expect(try scratch.readStars() == ["X y"])

        // A fresh launch re-stamps the star onto a re-added entry.
        let reopened = makeStore(scratch, defaults)
        #expect(reopened.starredNames == ["X y"])
        reopened.recordObservation(scientificName: "X y", commonName: "X", date: may5,
                                   location: "P", latitude: 1, longitude: 1)
        #expect(reopened.entries[0].isStarred)
    }

    @Test("the persisted star set is the source of truth over a stale entry flag")
    func starSetOverridesEntryFlag() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        // Entry says starred; the authoritative file says otherwise.
        try scratch.writeLifeList([
            .make("X y", "X", [.at(may4, "P", lat: 1, lon: 1)], starred: true),
        ])
        try scratch.writeStars([])
        let store = makeStore(scratch, defaults)
        #expect(!store.entries[0].isStarred)
        #expect(store.starredNames.isEmpty)
    }

    /// First run after the separate star file shipped: seed it from whatever
    /// stars the entries already carry, then it becomes the source of truth.
    @Test("a pre-feature install seeds the star file from its entries")
    func starsMigratedFromEntries() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeLifeList([
            .make("A a", "A", [.at(may4, "P", lat: 1, lon: 1)], starred: true),
            .make("B b", "B", [.at(may4, "P", lat: 1, lon: 1)], starred: false),
        ])
        let store = makeStore(scratch, defaults)  // no stars file written
        #expect(store.starredNames == ["A a"])
        store.flushPendingWrites()
        #expect(try scratch.readStars() == ["A a"])
    }

    @Test("toggling a star writes through to both the set and the entry")
    func starToggle() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        store.setStarred(scientificName: "X y", isStarred: true)
        #expect(store.starredNames.contains("X y"))
        #expect(store.entries[0].isStarred)

        store.setStarred(scientificName: "X y", isStarred: false)
        #expect(!store.starredNames.contains("X y"))
        #expect(!store.entries[0].isStarred)
    }

    @Test("a species can be starred before it is ever recorded")
    func starWithoutEntry() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.setStarred(scientificName: "Never seen", isStarred: true)
        #expect(store.starredNames == ["Never seen"])
        #expect(store.entries.isEmpty)
    }

    // MARK: the export ledger

    @Test("Export New skips imported sightings")
    func newOnlySkipsImported() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeLifeList([
            .make(scientificName: "A a", commonName: "A", isStarred: false,
                  observations: [.at(may4, "P", lat: 1, lon: 1, imported: true)], dedupe: false),
            .make(scientificName: "B b", commonName: "B", isStarred: false,
                  observations: [.at(may4, "P", lat: 1, lon: 1, imported: false)], dedupe: false),
        ])
        let store = makeStore(scratch, defaults)
        #expect(store.observationCount(for: .everything) == 2)
        #expect(store.observationCount(for: .newOnly) == 1)
    }

    @Test("Export New skips what a previous export already handed over")
    func newOnlySkipsExported() async {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "A a", commonName: "A", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        store.recordObservation(scientificName: "B b", commonName: "B", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        #expect(store.observationCount(for: .newOnly) == 2)

        let payload = await store.makeEBirdExport(scope: .newOnly)
        store.markExported(payload.exportedKeys)
        #expect(store.observationCount(for: .newOnly) == 0)
        #expect(store.observationCount(for: .everything) == 2, "Export All ignores the ledger entirely")
    }

    @Test("the ledger survives a wipe-and-reimport")
    func ledgerSurvivesWipe() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        do {
            let store = makeStore(scratch, defaults)
            store.recordObservation(scientificName: "A a", commonName: "A", date: may4,
                                    location: "P", latitude: 1, longitude: 1)
            let observation = store.entries[0].allObservations[0]
            store.markExported([EBirdCSVExporter.key(scientificName: "A a", observation: observation)])
            store.removeAll()
            store.flushPendingWrites()
        }
        let reopened = makeStore(scratch, defaults)
        #expect(reopened.exportedObservationKeys.count == 1,
                "re-importing a CSV you already sent must not make it look new")
    }

    @Test("markExported is idempotent and only writes when the set actually grows")
    func markExportedIdempotent() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.markExported(["a", "b"])
        store.markExported(["a", "b"])
        store.markExported(["b", "c"])
        #expect(store.exportedObservationKeys == ["a", "b", "c"])
    }

    @Test("an export renders one row per observation, not per species")
    func exportRowsPerObservation() async {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        for date in [may4, may5, may6] {
            store.recordObservation(scientificName: "X y", commonName: "X", date: date,
                                    location: "P", latitude: 1, longitude: 1)
        }
        let payload = await store.makeEBirdExport(scope: .everything)
        #expect(payload.observationCount == 3)
        #expect(payload.speciesCount == 1)
    }

    /// Building the file must not mark anything — the caller does that only after
    /// a successful save, so a cancelled save panel doesn't quietly hide those
    /// sightings from the next export.
    @Test("rendering an export marks nothing as exported")
    func renderingDoesNotMark() async {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        _ = await store.makeEBirdExport(scope: .newOnly)
        #expect(store.exportedObservationKeys.isEmpty)
        #expect(store.observationCount(for: .newOnly) == 1)
    }

    // MARK: counts and lookups

    @Test("totalObservationCount counts sightings, not species")
    func totalObservationCount() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "A a", commonName: "A", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        store.recordObservation(scientificName: "A a", commonName: "A", date: may5,
                                location: "P", latitude: 1, longitude: 1)
        store.recordObservation(scientificName: "B b", commonName: "B", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        #expect(store.entries.count == 2)
        #expect(store.totalObservationCount == 3)
    }

    @Test("observations are listed newest first")
    func observationsNewestFirst() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        for (date, place) in [(may5, "B"), (may4, "A"), (may6, "C")] {
            store.recordObservation(scientificName: "X y", commonName: "X", date: date,
                                    location: place, latitude: 1, longitude: 1)
        }
        #expect(store.observations(for: "X y").map(\.location) == ["C", "B", "A"])
        #expect(store.observations(for: "Nope").isEmpty)
    }

    @Test("the store's own common name wins over the catalog's")
    func commonNameLookup() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "Cardinalis cardinalis", commonName: "eBird's Wording",
                                date: may4, location: "P", latitude: 1, longitude: 1)
        #expect(store.commonName(for: "Cardinalis cardinalis") == "eBird's Wording")
        #expect(store.commonName(for: "Not on the list") == nil)
    }

    @Test("firstObservation and firstObservationCoordinate report the earliest sighting")
    func firstObservationLookups() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may5,
                                location: "Later", latitude: 2, longitude: 2)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "Earliest", latitude: 1, longitude: 1)
        let first = store.firstObservation(for: "X y")
        #expect(first?.location == "Earliest")
        #expect(first?.date == may4)
        let coord = store.firstObservationCoordinate(for: "X y")
        #expect(coord?.latitude == 1)
        #expect(store.firstObservationCoordinate(for: "Not here") == nil)
    }

    @Test("a species logged without coordinates has none to show on the map")
    func noCoordinateForUnplacedSighting() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "Named but unplaced", latitude: nil, longitude: nil)
        #expect(store.firstObservationCoordinate(for: "X y") == nil)
        #expect(store.firstObservation(for: "X y")?.location == "Named but unplaced")
    }

    /// The naming step's default: a spot you've already named is almost certainly
    /// the same spot you're pinning again, and your own wording beats a geocoder's.
    @Test("nearestObservationName reuses a nearby name and ignores a distant one")
    func nearestObservationName() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "Sapsucker Woods", latitude: 42.4791, longitude: -76.4512)

        // ~100 m away.
        let close = CLLocationCoordinate2D(latitude: 42.4800, longitude: -76.4512)
        #expect(store.nearestObservationName(to: close, within: 1609.344) == "Sapsucker Woods")
        // Another continent.
        let far = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)
        #expect(store.nearestObservationName(to: far, within: 1609.344) == nil)
    }

    @Test("nearestObservationName picks the closest of several named spots")
    func nearestPicksClosest() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "A a", commonName: "A", date: may4,
                                location: "Far End", latitude: 42.4900, longitude: -76.4512)
        store.recordObservation(scientificName: "B b", commonName: "B", date: may4,
                                location: "Near End", latitude: 42.4792, longitude: -76.4512)
        let target = CLLocationCoordinate2D(latitude: 42.4791, longitude: -76.4512)
        #expect(store.nearestObservationName(to: target, within: 5000) == "Near End")
    }

    @Test("a sighting with no place name is not offered as a nearby name")
    func nearestIgnoresUnnamed() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: nil, latitude: 42.4791, longitude: -76.4512)
        let target = CLLocationCoordinate2D(latitude: 42.4791, longitude: -76.4512)
        #expect(store.nearestObservationName(to: target, within: 5000) == nil)
    }

    // MARK: persistence

    @Test("mutations reach disk and survive a relaunch")
    func mutationsPersist() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        do {
            let store = makeStore(scratch, defaults)
            store.recordObservation(scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal",
                                    date: may4, location: "Sapsucker Woods", latitude: 42.4791, longitude: -76.4512)
            store.recordObservation(scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal",
                                    date: may5, location: "Elsewhere", latitude: 1, longitude: 1)
            store.flushPendingWrites()
        }
        let reopened = makeStore(scratch, defaults)
        #expect(reopened.entries.count == 1)
        #expect(reopened.entries[0].allObservations.count == 2)
        #expect(reopened.entries[0].firstLocation == "Sapsucker Woods")
        #expect(!reopened.entries[0].firstIsImported, "provenance has to survive the round trip")
    }

    @Test("speciesNames tracks every membership change")
    func speciesNamesTracksMembership() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        #expect(store.speciesNames.isEmpty)

        store.recordObservation(scientificName: "A a", commonName: "A", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        #expect(store.speciesNames == ["A a"])

        // A second sighting of the same species doesn't change membership.
        store.recordObservation(scientificName: "A a", commonName: "A", date: may5,
                                location: "P", latitude: 1, longitude: 1)
        #expect(store.speciesNames == ["A a"])

        store.recordObservation(scientificName: "B b", commonName: "B", date: may4,
                                location: "P", latitude: 1, longitude: 1)
        #expect(store.speciesNames == ["A a", "B b"])

        // Deleting one of two sightings leaves the species on the list.
        let target = store.entries.first { $0.scientificName == "A a" }!.allObservations[0]
        store.removeObservation(scientificName: "A a", identity: target.identity)
        #expect(store.speciesNames == ["A a", "B b"])

        store.removeAll()
        #expect(store.speciesNames.isEmpty)
    }
}