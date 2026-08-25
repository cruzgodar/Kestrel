import Foundation
import Testing
@testable import Kestrel

/// Following a sighting through an edit.
///
/// Several screens hold a sighting *by value* rather than looking it up: the
/// full-screen viewer opened on a map pin, and the menus built from a
/// `MapPoint`. An edit rewrites the record's date or place — which is exactly
/// what `LifeListEntry.Observation.Identity` is made of — so the copy the screen
/// is still holding stops matching anything on record.
///
/// That cost two visible bugs. The held copy read as *deleted*, so
/// `SpeciesPhotoFullScreen` shut itself (and the map card under it) the moment a
/// user corrected a date; and a second edit or a delete aimed at the held copy
/// resolved to nothing in `LifeListStore.locate` and silently did nothing at
/// all. `ObservationActions` keeps the trail so every one of those screens can
/// ask what its sighting became.
@Suite("Observation edit tracking")
@MainActor
struct ObservationActionsTests {

    private let may4 = utcDay(2026, 5, 4)
    private let may5 = utcDay(2026, 5, 5)
    private let may6 = utcDay(2026, 5, 6)

    private func sighting(_ date: Date, _ place: String) -> LifeListEntry.Observation {
        LifeListEntry.Observation(date: date, location: place, latitude: 1, longitude: 1)
    }

    @Test("an untracked sighting is returned unchanged")
    func untrackedPassesThrough() {
        let actions = ObservationActions()
        let observation = sighting(may4, "Sapsucker Woods")
        #expect(actions.current(observation) == observation)
    }

    @Test("a tracked sighting resolves to its replacement")
    func followsOneEdit() {
        let actions = ObservationActions()
        let before = sighting(may4, "Sapsucker Woods")
        let after = sighting(may5, "Sapsucker Woods")
        actions.recordEdit(original: before, replacement: after)
        #expect(actions.current(before) == after)
    }

    /// The screens that need this keep holding the value they *opened* with, not
    /// the one the last edit produced — so a second edit has to resolve from the
    /// original all the way to the record that exists now.
    @Test("a chain of edits resolves to the record that exists now")
    func followsAChain() {
        let actions = ObservationActions()
        let first = sighting(may4, "Sapsucker Woods")
        let second = sighting(may5, "Sapsucker Woods")
        let third = sighting(may6, "Mundy Wildflower Garden")
        actions.recordEdit(original: first, replacement: second)
        actions.recordEdit(original: second, replacement: third)
        #expect(actions.current(first) == third)
        #expect(actions.current(second) == third)
    }

    /// Editing a sighting back to the values it started with closes a loop in
    /// the trail. Walking it has to terminate.
    @Test("an edit that restores the original values doesn't loop")
    func cycleTerminates() {
        let actions = ObservationActions()
        let first = sighting(may4, "Sapsucker Woods")
        let second = sighting(may5, "Sapsucker Woods")
        actions.recordEdit(original: first, replacement: second)
        actions.recordEdit(original: second, replacement: first)
        // Whichever end it settles on, it settles: the point is that it returns.
        let resolved = actions.current(first)
        #expect(resolved == first || resolved == second)
    }

    /// Only writes that changed something are worth tracking, and a self-edge
    /// would be a one-step cycle in the trail.
    @Test("re-confirming a sighting unchanged records nothing")
    func noSelfEdge() {
        let actions = ObservationActions()
        let observation = sighting(may4, "Sapsucker Woods")
        actions.recordEdit(original: observation, replacement: observation)
        #expect(actions.current(observation) == observation)
    }

    /// Provenance is part of the record, and the trail has to carry it: a
    /// resolved sighting that came back Kestrel-native would stop matching the
    /// imported row actually on file, which is the `locate` miss all over again.
    @Test("the trail carries provenance")
    func keepsProvenance() {
        let actions = ObservationActions()
        let before = LifeListEntry.Observation(
            date: may4, location: "P", latitude: 1, longitude: 1, isImported: true
        )
        let after = LifeListEntry.Observation(
            date: may5, location: "P", latitude: 1, longitude: 1, isImported: true
        )
        actions.recordEdit(original: before, replacement: after)
        #expect(actions.current(before).isImported)
    }

    /// The end-to-end shape of the viewer's bug: edit a pin-scoped sighting's
    /// date, then ask the store whether it still exists. Against the raw held
    /// copy the answer is "no" — which is what dismissed the viewer — and
    /// against the followed one it is "yes".
    @Test("a followed sighting is still found on the list after an edit")
    func followedSightingSurvivesAnEdit() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        store.recordObservation(scientificName: "X y", commonName: "X", date: may4,
                                location: "Sapsucker Woods", latitude: 1, longitude: 1)
        let held = store.entries[0].allObservations[0]

        let actions = ObservationActions()
        let written = try #require(store.replaceObservation(
            scientificName: "X y", original: held,
            date: may5, location: "Sapsucker Woods", latitude: 1, longitude: 1
        ))
        actions.recordEdit(original: held, replacement: written)

        let onRecord = store.observations(for: "X y")
        #expect(!onRecord.contains { $0.identity == held.identity },
                "the raw held copy is what made an edit look like a deletion")
        #expect(onRecord.contains { $0.identity == actions.current(held).identity })
    }
}
