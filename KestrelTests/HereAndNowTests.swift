import CoreLocation
import Foundation
import Testing
@testable import Kestrel

/// The "did you see this bird here and now?" add: when the question is asked
/// at all, and what a "yes" files.
///
/// Two things went wrong with it. A "yes" could wait seconds on a location fix
/// — or find none — before falling back to the very flow a "no" opens, so the
/// question was asked where it couldn't be acted on; it is now asked only
/// where the location is already established. And past ten miles the naming
/// step was pre-filled with the nearest name on the list however far away it
/// was, so on a trip one tap filed the sighting under the home patch.
@Suite("Here and now")
@MainActor
struct HereAndNowTests {

    private let cardinal = (scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal")
    /// A place already on the list, with a name.
    private let sapsucker = CLLocationCoordinate2D(latitude: 42.48, longitude: -76.45)
    /// About five miles north of `sapsucker` — inside the reuse radius.
    private let fiveMilesNorth = (latitude: 42.5524, longitude: -76.45)
    /// About twenty miles north — outside it.
    private let twentyMilesNorth = (latitude: 42.77, longitude: -76.45)

    // MARK: whether the question is asked

    @Test("asked with a fresh fix from anywhere, or a phone that can refresh one")
    func availabilityRule() {
        // A fix inside the freshness window counts wherever it came from.
        #expect(ObservationDraft.hereAndNowIsAvailable(phoneAuthorized: false, hasFix: true, fixIsFresh: true))
        #expect(ObservationDraft.hereAndNowIsAvailable(phoneAuthorized: true, hasFix: true, fixIsFresh: true))
        // A stale fix on a phone that may look for a newer one.
        #expect(ObservationDraft.hereAndNowIsAvailable(phoneAuthorized: true, hasFix: true, fixIsFresh: false))
        // Still loading: may look, nothing landed yet.
        #expect(!ObservationDraft.hereAndNowIsAvailable(phoneAuthorized: true, hasFix: false, fixIsFresh: false))
        // A stale watch fix on a phone that may not look.
        #expect(!ObservationDraft.hereAndNowIsAvailable(phoneAuthorized: false, hasFix: true, fixIsFresh: false))
        // Not granted, nothing from anywhere.
        #expect(!ObservationDraft.hereAndNowIsAvailable(phoneAuthorized: false, hasFix: false, fixIsFresh: false))
    }

    @Test("read off the location cache as it stands")
    func availabilityFromTheCache() {
        let now = Date()
        let empty = Self.cache()
        #expect(!ObservationDraft.canAskHereAndNow(cache: empty, authorized: true, now: now),
                "still loading")

        let staleWatch = Self.cache()
        staleWatch.update(latitude: 42.5, longitude: -76.5, at: now.addingTimeInterval(-600))
        #expect(!ObservationDraft.canAskHereAndNow(cache: staleWatch, authorized: false, now: now),
                "a watch fix from ten minutes ago, and no permission to look again")
        #expect(ObservationDraft.canAskHereAndNow(cache: staleWatch, authorized: true, now: now),
                "the same fix on a phone that can refresh it")

        let freshWatch = Self.cache()
        freshWatch.update(latitude: 42.5, longitude: -76.5, at: now.addingTimeInterval(-10))
        #expect(ObservationDraft.canAskHereAndNow(cache: freshWatch, authorized: false, now: now),
                "a watch fix from moments ago, permission or not")
    }

    // MARK: which name a sighting is filed under

    @Test("a named place within ten miles is filed under; one further is not offered")
    func placeWithinRadius() {
        let radius = ObservationDraft.hereAndNowReuseRadius
        #expect(ObservationDraft.hereAndNowPlace(nearest: ("Sapsucker Woods", 8_000)) == "Sapsucker Woods")
        #expect(ObservationDraft.hereAndNowPlace(nearest: ("Sapsucker Woods", radius)) == "Sapsucker Woods")
        #expect(ObservationDraft.hereAndNowPlace(nearest: ("Sapsucker Woods", radius + 1)) == nil)
        #expect(ObservationDraft.hereAndNowPlace(nearest: ("Home", 1_600_000)) == nil,
                "a thousand miles away is no suggestion")
        #expect(ObservationDraft.hereAndNowPlace(nearest: nil) == nil)
    }

    // MARK: what a "yes" files

    @Test("near a named place, the sighting is filed outright under its name")
    func filesOutrightNearby() async {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = seededStore(scratch, defaults)
        let askedAt = Date()
        let cache = Self.cache()
        cache.update(latitude: fiveMilesNorth.latitude, longitude: fiveMilesNorth.longitude, at: askedAt)

        let draft = await file(askedAt: askedAt, store: store, cache: cache, authorized: true)

        #expect(draft == nil, "nothing left to ask")
        let filed = store.observations(for: cardinal.scientificName).first { $0.date == ObservationDate.today }
        #expect(filed?.location == "Sapsucker Woods")
        #expect(filed?.latitude == fiveMilesNorth.latitude)
        #expect(filed?.longitude == fiveMilesNorth.longitude)
    }

    @Test("far from every named place, the naming step opens with nothing pre-filled")
    func asksForANameFarAway() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = seededStore(scratch, defaults)
        let askedAt = Date()
        let cache = Self.cache()
        cache.update(latitude: twentyMilesNorth.latitude, longitude: twentyMilesNorth.longitude, at: askedAt)
        let before = store.observations(for: cardinal.scientificName).count

        let draft = try #require(await file(askedAt: askedAt, store: store, cache: cache, authorized: true))

        #expect(draft.isHereAndNow)
        #expect(draft.placeName == nil, "the step suggests its own — the town, not Sapsucker Woods")
        #expect(draft.coordinate?.latitude == twentyMilesNorth.latitude)
        #expect(store.observations(for: cardinal.scientificName).count == before, "nothing written yet")
    }

    /// The watch sends its coordinate once, and a phone without permission
    /// can't refresh it. A fix that was current when the question went up
    /// still vouches for "here", however long the answer took.
    @Test("a fix current when asked still counts when the answer comes late")
    func freshnessIsMeasuredFromTheQuestion() async {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = seededStore(scratch, defaults)
        // Asked 50s ago, about a fix 30s older than that: 80s old by the answer.
        let askedAt = Date().addingTimeInterval(-50)
        let cache = Self.cache()
        cache.update(latitude: fiveMilesNorth.latitude, longitude: fiveMilesNorth.longitude,
                     at: askedAt.addingTimeInterval(-30))
        #expect(!cache.isFresh())

        let draft = await file(askedAt: askedAt, store: store, cache: cache, authorized: false)

        #expect(draft == nil)
        #expect(store.observations(for: cardinal.scientificName).contains { $0.date == ObservationDate.today })
    }

    @Test("with no fix current as of the question and no way to refresh it, the ordinary flow")
    func fallsBackWithoutAFix() async throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = seededStore(scratch, defaults)
        let askedAt = Date()
        let cache = Self.cache()
        cache.update(latitude: fiveMilesNorth.latitude, longitude: fiveMilesNorth.longitude,
                     at: askedAt.addingTimeInterval(-600))
        let before = store.observations(for: cardinal.scientificName).count

        let draft = try #require(await file(askedAt: askedAt, store: store, cache: cache, authorized: false))

        #expect(!draft.isHereAndNow)
        #expect(draft.coordinate == nil, "the map opens on the user, as for any add")
        #expect(store.observations(for: cardinal.scientificName).count == before)
    }

    @Test("a phone with a stale fix refreshes it and files at the new one")
    func refreshesAStaleFix() async {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let store = seededStore(scratch, defaults)
        let askedAt = Date()
        let cache = LocationCache(
            fetch: { [fiveMilesNorth] in fiveMilesNorth },
            clock: { Date() }
        )
        cache.update(latitude: 40, longitude: -100, at: askedAt.addingTimeInterval(-600))

        let draft = await file(askedAt: askedAt, store: store, cache: cache, authorized: true)

        #expect(draft == nil)
        let filed = store.observations(for: cardinal.scientificName).first { $0.date == ObservationDate.today }
        #expect(filed?.latitude == fiveMilesNorth.latitude, "the refreshed fix, not the stale one")
    }

    // MARK: helpers

    /// A cache that never resolves a fix of its own.
    private static func cache() -> LocationCache {
        LocationCache(fetch: { nil }, clock: { Date() })
    }

    /// A store holding one named, located sighting at `sapsucker`.
    private func seededStore(_ scratch: ScratchDirectory, _ defaults: ScratchDefaults) -> LifeListStore {
        let store = makeStore(scratch, defaults)
        store.recordObservation(
            scientificName: cardinal.scientificName,
            commonName: cardinal.commonName,
            date: utcDay(2026, 5, 4),
            location: "Sapsucker Woods",
            latitude: sapsucker.latitude,
            longitude: sapsucker.longitude
        )
        return store
    }

    private func file(
        askedAt: Date,
        store: LifeListStore,
        cache: LocationCache,
        authorized: Bool
    ) async -> ObservationDraft? {
        await ObservationDraft.fileHereAndNow(
            scientificName: cardinal.scientificName,
            commonName: cardinal.commonName,
            askedAt: askedAt,
            store: store,
            cache: cache,
            authorized: authorized
        )
    }
}

/// Whether an add / edit / delete is underway — what a here-and-now naming
/// step checks before it opens, so it never lands on a flow the user started
/// while the sighting was finding its place.
@Suite("Observation actions busy state")
@MainActor
struct ObservationActionsBusyTests {

    @Test("busy while any of the three is underway")
    func busy() {
        let actions = ObservationActions()
        #expect(!actions.isBusy)

        actions.add(scientificName: "Cardinalis cardinalis", commonName: "Northern Cardinal")
        #expect(actions.isBusy)
        actions.draft = nil
        #expect(!actions.isBusy)

        actions.pendingDelete = PendingObservationDelete(
            scientificName: "Cardinalis cardinalis",
            commonName: "Northern Cardinal",
            observation: LifeListEntry.Observation(
                date: utcDay(2026, 5, 4), location: "Sapsucker Woods", latitude: 1, longitude: 1
            )
        )
        #expect(actions.isBusy)
        actions.pendingDelete = nil

        actions.choice = ObservationChoice(
            scientificName: "Cardinalis cardinalis",
            commonName: "Northern Cardinal",
            isDeleting: false,
            limitedTo: nil
        )
        #expect(actions.isBusy)
    }
}
