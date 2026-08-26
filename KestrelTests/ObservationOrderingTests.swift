import Foundation
import Testing
@testable import Kestrel

/// The order a species' sightings come back in.
///
/// The property under test throughout is **not** "they are sorted correctly" but
/// "the answer does not depend on the order they went in." `Array.sorted` makes
/// no promise about elements that compare equal, so a comparator that leaves two
/// records equal can hand back either arrangement of them — and which one you get
/// turns on the incidental order of the input, which shifts on every write (see
/// `LifeListEntry.make`, which re-sorts and re-partitions on each edit).
///
/// That matters because two sightings of one species are *allowed* to share a
/// date and a place. Every path where the user writes a record passes
/// `dedupe: false` precisely so an edit can't collapse one into a sibling, and
/// `LifeListStore.locate` exists because such a pair can differ in nothing but
/// `isImported`. `ObservationPickerSheet` keys its rows by position and re-reads
/// the store live, so an unstable order let the rows swap under the user's finger
/// in the one list whose whole job is telling those sightings apart.
@Suite("Observation ordering")
struct ObservationOrderingTests {

    private let may4 = utcDay(2026, 5, 4)
    private let may5 = utcDay(2026, 5, 5)

    /// Every arrangement of `items`, so a sort can be checked against all of
    /// them rather than against whichever one the test happened to write down.
    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        var out: [[T]] = []
        for (i, item) in items.enumerated() {
            var rest = items
            rest.remove(at: i)
            for tail in permutations(rest) { out.append([item] + tail) }
        }
        return out
    }

    @Test("the permutation helper is exhaustive")
    func permutationHelperIsSane() {
        #expect(permutations([1, 2, 3]).count == 6)
        #expect(Set(permutations([1, 2, 3]).map(\.description)).count == 6)
        #expect(permutations([1]).count == 1)
        #expect(permutations([Int]()).count == 1)
    }

    // MARK: the ordering itself

    /// The pair the old comparator could not separate: same day, same place,
    /// differing only in provenance — which `Identity` deliberately ignores, so
    /// they are not even distinguishable by identity.
    @Test("two sightings differing only in provenance have a defined order")
    func provenanceBreaksTheTie() {
        let native = LifeListEntry.Observation.at(may4, "Sapsucker Woods")
        let imported = LifeListEntry.Observation.at(may4, "Sapsucker Woods", imported: true)
        #expect(native != imported)
        #expect(native.identity == imported.identity, "identity is blind to provenance by design")
        // Exactly one direction holds — an order, not a coin flip.
        let forward = LifeListEntry.Observation.ordersBefore(native, imported)
        let backward = LifeListEntry.Observation.ordersBefore(imported, native)
        #expect(forward != backward)
    }

    @Test("two sightings differing only in coordinates have a defined order")
    func coordinatesBreakTheTie() {
        let a = LifeListEntry.Observation.at(may4, "Ithaca", lat: 42.1, lon: -76.1)
        let b = LifeListEntry.Observation.at(may4, "Ithaca", lat: 42.2, lon: -76.1)
        #expect(LifeListEntry.Observation.ordersBefore(a, b))
        #expect(!LifeListEntry.Observation.ordersBefore(b, a))
    }

    /// A sighting with no coordinate is not "equal to" one that has one, and the
    /// nil must land on a consistent side.
    @Test("a missing coordinate orders consistently against a present one")
    func missingCoordinateOrdersConsistently() {
        let none = LifeListEntry.Observation.at(may4, "Ithaca")
        let some = LifeListEntry.Observation.at(may4, "Ithaca", lat: 42.1, lon: -76.1)
        #expect(LifeListEntry.Observation.ordersBefore(none, some))
        #expect(!LifeListEntry.Observation.ordersBefore(some, none))
    }

    /// The comparator must be irreflexive, or `sorted` is entitled to do
    /// anything at all with it.
    @Test("a sighting does not order before itself")
    func irreflexive() {
        let all: [LifeListEntry.Observation] = [
            .at(may4),
            .at(may4, "Ithaca"),
            .at(may4, "Ithaca", lat: 1, lon: 2),
            .at(may4, "Ithaca", lat: 1, lon: 2, imported: true),
            .at(may5, "Ithaca"),
        ]
        for observation in all {
            #expect(!LifeListEntry.Observation.ordersBefore(observation, observation))
            #expect(!LifeListEntry.Observation.ordersBeforeAtSameDate(observation, observation))
        }
    }

    /// Asymmetry across every pair — the other half of "this is a strict order".
    @Test("exactly one direction holds for any two distinct sightings")
    func asymmetric() {
        let all: [LifeListEntry.Observation] = [
            .at(may5, "Zoo"),
            .at(may4),
            .at(may4, ""),
            .at(may4, "Ithaca"),
            .at(may4, "Ithaca", lat: 1, lon: 2),
            .at(may4, "Ithaca", lat: 1, lon: 3),
            .at(may4, "Ithaca", lat: 1, lon: 3, imported: true),
            .at(may4, "Jacksonville"),
        ]
        for a in all {
            for b in all where a != b {
                let forward = LifeListEntry.Observation.ordersBefore(a, b)
                let backward = LifeListEntry.Observation.ordersBefore(b, a)
                #expect(forward != backward, "\(a) vs \(b)")
            }
        }
    }

    @Test("newest first still holds, whatever the tiebreakers do")
    func newestFirst() {
        let older = LifeListEntry.Observation.at(may4, "Zzz", lat: 99, lon: 99, imported: true)
        let newer = LifeListEntry.Observation.at(may5, "Aaa")
        #expect(LifeListEntry.Observation.ordersBefore(newer, older))
        #expect(!LifeListEntry.Observation.ordersBefore(older, newer))
    }

    /// The whole point: the sorted result is a function of the *set*, not of the
    /// order it arrived in.
    @Test("sorting is independent of input order")
    func sortIsInputOrderIndependent() {
        let observations: [LifeListEntry.Observation] = [
            .at(may4, "Ithaca", lat: 1, lon: 2),
            .at(may4, "Ithaca", lat: 1, lon: 2, imported: true),
            .at(may4, "Ithaca"),
            .at(may5, "Ithaca"),
        ]
        let expected = observations.sorted(by: LifeListEntry.Observation.ordersBefore)
        for arrangement in permutations(observations) {
            #expect(arrangement.sorted(by: LifeListEntry.Observation.ordersBefore) == expected)
        }
    }

    // MARK: through the store

    /// `observations(for:)` is what every "which sighting did you mean?" list
    /// renders, so the guarantee has to survive the trip through the store.
    @Test("the store's observation list is independent of stored order")
    @MainActor
    func storeListIsStable() {
        let observations: [LifeListEntry.Observation] = [
            .at(may4, "Sapsucker Woods", lat: 42.4791, lon: -76.4512),
            .at(may4, "Sapsucker Woods", lat: 42.4791, lon: -76.4512, imported: true),
            .at(may4, "Sapsucker Woods"),
            .at(may5, "Stewart Park"),
        ]
        var results: [[LifeListEntry.Observation]] = []
        for arrangement in permutations(observations) {
            let scratch = ScratchDirectory(), defaults = ScratchDefaults()
            let store = makeStore(scratch, defaults)
            for observation in arrangement {
                store.recordObservation(
                    scientificName: "X y", commonName: "Ex Why",
                    date: observation.date, location: observation.location,
                    latitude: observation.latitude, longitude: observation.longitude
                )
            }
            results.append(store.observations(for: "X y"))
            store.flushPendingWrites()
        }
        // Every arrangement wrote the same four records (modulo the provenance
        // `recordObservation` always sets), so every list must match.
        for list in results {
            #expect(list.count == 4)
            #expect(list.map(\.location) == results[0].map(\.location))
            #expect(list.map(\.date) == results[0].map(\.date))
            #expect(list.map(\.latitude) == results[0].map(\.latitude))
        }
    }

    /// A same-day, same-place pair is the case that used to be able to swap, and
    /// the store must keep both of them *and* keep them in one order.
    @Test("a same-day same-place pair keeps a fixed order across re-reads")
    @MainActor
    func duplicatePairIsStableAcrossReads() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)
        for _ in 0..<2 {
            store.recordObservation(
                scientificName: "X y", commonName: "Ex Why",
                date: may4, location: "Ithaca", latitude: 42.44, longitude: -76.5
            )
        }
        #expect(store.observations(for: "X y").count == 2, "a deliberate repeat is two records")
        let first = store.observations(for: "X y")
        for _ in 0..<20 {
            #expect(store.observations(for: "X y") == first)
        }
    }

    /// Reloading from disk re-runs the whole canonicalization pipeline, which
    /// rebuilds every entry — a fresh chance for the order to come out different.
    @Test("the order survives a save and reload")
    @MainActor
    func orderSurvivesReload() {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let before: [LifeListEntry.Observation]
        do {
            let store = makeStore(scratch, defaults)
            for place in ["Ithaca", "Ithaca", "Dryden"] {
                store.recordObservation(
                    scientificName: "X y", commonName: "Ex Why",
                    date: may4, location: place, latitude: 42.44, longitude: -76.5
                )
            }
            before = store.observations(for: "X y")
            store.flushPendingWrites()
        }
        let reopened = makeStore(scratch, defaults)
        #expect(reopened.observations(for: "X y") == before)
    }
}
