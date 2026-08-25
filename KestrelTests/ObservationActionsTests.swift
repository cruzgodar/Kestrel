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

    // MARK: which sighting did you mean?

    /// Whether an Edit or a Delete acts outright or raises the chooser.
    ///
    /// This is the branch that decides whether the trail above is even reachable.
    /// An action resolved to a single sighting runs the flow from `draft`, which
    /// the host's own `observationFlow` reports back through `onEdited`; one that
    /// raises a `choice` runs it from the chooser's own draft instead — and the
    /// chooser has to forward those edits on, or a host holding a sighting by
    /// value never hears about them. The chooser's wiring is a SwiftUI
    /// presentation and can't be driven from here; these pin the precondition for
    /// it mattering.

    /// Files `count` sightings of one species, newest last.
    private func seed(_ store: LifeListStore, _ count: Int) {
        for i in 0..<count {
            store.recordObservation(
                scientificName: "X y", commonName: "X",
                date: utcDay(2026, 5, 4 + i), location: "Place \(i)",
                latitude: Double(i), longitude: Double(i)
            )
        }
    }

    @Test("a bird seen once is edited outright, with nothing to ask")
    func singleSightingEditsDirectly() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        seed(store, 1)

        let actions = ObservationActions()
        actions.edit(scientificName: "X y", commonName: "X", in: store)
        #expect(actions.choice == nil, "there is only one sighting this could mean")
        #expect(actions.draft?.editing == store.observations(for: "X y").first)
    }

    @Test("a bird seen several times raises the chooser instead")
    func severalSightingsRaiseTheChooser() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        seed(store, 3)

        let actions = ObservationActions()
        actions.edit(scientificName: "X y", commonName: "X", in: store)
        #expect(actions.draft == nil)

        let choice = try #require(actions.choice)
        #expect(choice.isDeleting == false)
        #expect(choice.limitedTo == nil, "a life-list row stands for the whole species")
        #expect(choice.observations(in: store).count == 3)
    }

    @Test("delete mirrors edit: one goes straight to the confirmation, several ask")
    func deleteResolvesTheSameWay() {
        let scratchA = ScratchDirectory(), defaultsA = ScratchDefaults()
        let single = makeStore(scratchA, defaultsA)
        seed(single, 1)
        let a = ObservationActions()
        a.delete(scientificName: "X y", commonName: "X", in: single)
        #expect(a.choice == nil)
        #expect(a.pendingDelete?.observation == single.observations(for: "X y").first)

        let scratchB = ScratchDirectory(), defaultsB = ScratchDefaults()
        let many = makeStore(scratchB, defaultsB)
        seed(many, 3)
        let b = ObservationActions()
        b.delete(scientificName: "X y", commonName: "X", in: many)
        #expect(b.pendingDelete == nil)
        #expect(b.choice?.isDeleting == true)
    }

    /// A map thumbnail stands for only the sightings pinned under it, so the
    /// question it raises is narrowed to those — offering one from the other side
    /// of the country under a pin the user long-pressed here would be a non
    /// sequitur.
    @Test("a pin-scoped action asks only about the sightings it stands for")
    func limitedChoiceNarrowsTheQuestion() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        seed(store, 3)
        let subset = Array(store.observations(for: "X y").prefix(2))

        let actions = ObservationActions()
        actions.edit(scientificName: "X y", commonName: "X", among: subset)

        let choice = try #require(actions.choice)
        #expect(choice.limitedTo == Set(subset.map(\.identity)))
        #expect(choice.observations(in: store).count == 2)
    }

    @Test("an action with nothing to act on is a no-op, not an empty chooser")
    func noSightingsIsANoOp() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)

        let actions = ObservationActions()
        actions.edit(scientificName: "X y", commonName: "X", in: store)
        actions.delete(scientificName: "X y", commonName: "X", in: store)
        #expect(actions.choice == nil)
        #expect(actions.draft == nil)
        #expect(actions.pendingDelete == nil)
    }
}
