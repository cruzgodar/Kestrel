import Foundation
import Testing
@testable import Kestrel

/// What happens to the two files that live *beside* the life list — the starred
/// set and the eBird export ledger — when a launch can't read one of them.
///
/// Both exist precisely so they can outlive `life_list.json`: stars survive a
/// wipe-and-reimport, and the ledger survives "Delete All Entries". Both are
/// therefore read on their own, at the top of `init`, before anything else
/// happens. And both readers used to collapse "there is no file" and "there is a
/// file I couldn't read" onto one answer — `nil` for the stars, the empty set for
/// the ledger — at which point the store went on to do what a *first run* does:
/// write the state it had just reconstructed from nothing straight over the file
/// it had failed to open.
///
/// The life list itself has never had that problem: `load()` sets `loadFailed`
/// and `save()` refuses while it holds (see
/// `LifeListStoreCanonicalizationTests`). These two files simply weren't given
/// the same treatment, and the asymmetry is what this suite pins.
///
/// The consequences aren't symmetric either:
///
///   • The stars are recoverable — the user re-taps them, and the entries' own
///     `isStarred` flags are a decent copy in the meantime.
///   • **The ledger is not.** It records which sightings eBird already holds, and
///     eBird does no deduplication whatsoever. A ledger replaced by an empty one
///     makes every sighting look new again, and the next "Export New
///     Observations" writes the user's whole Kestrel-native history into a file
///     they then upload as a second copy of records they already have — which
///     they unpick by hand, checklist by checklist, if they notice at all.
///
/// Two shapes of failure are exercised, because the store can't tell them apart
/// and mustn't need to: bytes that won't decode (`writeRaw`) and a path that
/// won't open (`obstruct` — the shape of a file-protection window before first
/// unlock, or a disk error). The second is the one that *heals*, which is why the
/// retry tests use it.
@Suite("LifeListStore sidecar load failures")
@MainActor
struct LifeListStoreSidecarLoadFailureTests {

    private let may4 = utcDay(2026, 5, 4)
    private let may5 = utcDay(2026, 5, 5)

    /// A sighting Kestrel recorded itself — the only kind the ledger is ever
    /// consulted about, since `isNewToEBird` refuses an imported one before the
    /// ledger is reached.
    private func native(_ date: Date) -> LifeListEntry.Observation {
        .at(date, "Sapsucker Woods", lat: 42.45342, lon: -76.47352, imported: false)
    }

    private func key(_ scientificName: String, _ observation: LifeListEntry.Observation) -> String {
        EBirdCSVExporter.key(scientificName: scientificName, observation: observation)
    }

    // MARK: - Stars

    /// The regression, in its simplest form. An unreadable stars file is not an
    /// absent one, and the store must not write the set it reconstructed from the
    /// entries over it.
    @Test("an undecodable stars file is never written over")
    func undecodableStarsAreNotOverwritten() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeRaw("starred_species.json", "{ this is not JSON")
        try scratch.writeLifeList([
            .make("A a", "Ay", [.at(may4, "P", lat: 1, lon: 1)]),
        ])

        let store = makeStore(scratch, defaults)
        // Both the seeding write in `init` and a deliberate toggle afterwards.
        store.setStarred(scientificName: "A a", isStarred: true)
        store.flushPendingWrites()

        #expect(
            scratch.data("starred_species.json") == Data("{ this is not JSON".utf8),
            "the bytes are left for a later launch (or a person) to recover"
        )
    }

    /// The second, quieter half of the same failure — and the one that reached
    /// *past* the stars file into the life list.
    ///
    /// `init`'s first-run branch seeds `starredNames` from the entries and then
    /// calls `applyStarsToEntries`, which stamps every entry from that set and
    /// saves. Taken on a failed read with an empty seed, that stamp cleared the
    /// `isStarred` flags the entries were carrying and persisted them — so a
    /// stars file that merely failed to open took `life_list.json`'s copy of the
    /// same information with it, and there was then nothing left to recover from.
    @Test("a failed stars read doesn't clear the entries' own flags")
    func failedStarsReadKeepsEntryFlags() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeRaw("starred_species.json", "{ this is not JSON")
        try scratch.writeLifeList([
            .make("A a", "Ay", [.at(may4, "P", lat: 1, lon: 1)], starred: true),
        ])

        let store = makeStore(scratch, defaults)
        #expect(store.entries[0].isStarred, "the row still shows its star")
        #expect(
            store.starredNames == ["A a"],
            "and the classifier still alerts for it — the entries are the best copy this launch has"
        )

        // Force a life-list write, which is where the cleared flag used to land.
        store.recordObservation(
            scientificName: "B b", commonName: "Bee",
            date: may5, location: "Ithaca", latitude: 42.44, longitude: -76.5
        )
        store.flushPendingWrites()

        let onDisk = try scratch.readLifeList()
        #expect(
            onDisk.first(where: { $0.scientificName == "A a" })?.isStarred == true,
            "the stars file failing to load must not erase the flags stored beside the entries"
        )
    }

    /// The failure this is really about is transient — the file is unreadable for
    /// a moment (a protection window before first unlock) and fine afterwards.
    /// Refusing to write is what stops the loss; retrying at the next toggle is
    /// what makes the store work again inside the same launch rather than only
    /// after a relaunch.
    ///
    /// The user's tap is applied *on top of* what the retry read, so it wins.
    @Test("a transient stars failure heals at the next toggle")
    func transientStarsFailureHeals() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.obstruct("starred_species.json")
        let store = makeStore(scratch, defaults)
        #expect(store.starredNames.isEmpty, "nothing was readable at launch")

        // The window closes: the real file is there now.
        try scratch.clearObstruction("starred_species.json")
        try scratch.writeStars(["A a"])

        store.setStarred(scientificName: "B b", isStarred: true)
        store.flushPendingWrites()

        #expect(
            store.starredNames == ["A a", "B b"],
            "the retry recovered the user's stars, and the new toggle landed on top"
        )
        #expect(try scratch.readStars() == ["A a", "B b"])
    }

    /// The other half of that recovery: toggles made *during* the window, which
    /// `saveStars` refused and which the retry's wholesale replacement would
    /// otherwise revert — a star the user turned off coming back on its own.
    ///
    /// Replayed rather than unioned, which is why turning one *off* is the case
    /// worth testing: a union would restore exactly the star being removed.
    @Test("toggles made while the stars file was unreadable survive the recovery")
    func deferredStarTogglesAreReplayed() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.obstruct("starred_species.json")
        let store = makeStore(scratch, defaults)

        // Two answers given while nothing could be written.
        store.setStarred(scientificName: "B b", isStarred: true)
        store.setStarred(scientificName: "A a", isStarred: false)

        // The window closes, and the file still holds the star the user just
        // turned off.
        try scratch.clearObstruction("starred_species.json")
        try scratch.writeStars(["A a", "C c"])

        // Any toggle triggers the retry; make it one that changes nothing on its
        // own, so what lands on disk can only have come from the replay.
        store.setStarred(scientificName: "C c", isStarred: true)
        store.flushPendingWrites()

        #expect(
            store.starredNames == ["B b", "C c"],
            "the un-star was the user's answer, and it isn't undone by the file coming back"
        )
        #expect(try scratch.readStars() == ["B b", "C c"])
    }

    /// The guard is scoped to the file that failed. A store whose stars file is
    /// unreadable must still write the life list — the mirror of
    /// `unreadableFileStillLetsStarsSave`, which pins the same thing the other way
    /// round.
    @Test("an unreadable stars file doesn't block the life list")
    func unreadableStarsStillLetTheLifeListSave() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeRaw("starred_species.json", "{ this is not JSON")
        let store = makeStore(scratch, defaults)

        store.recordObservation(
            scientificName: "X y", commonName: "Ex Why",
            date: may4, location: "Ithaca", latitude: 42.44, longitude: -76.5
        )
        store.flushPendingWrites()
        #expect(try scratch.readLifeList().map(\.scientificName) == ["X y"])
    }

    /// The behavior the new third case must not have disturbed: with *no* stars
    /// file, this is still a first run, and the entries' flags are still migrated
    /// into one.
    @Test("an absent stars file is still the first-run migration")
    func absentStarsStillMigrate() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeLifeList([
            .make("A a", "Ay", [.at(may4, "P", lat: 1, lon: 1)], starred: true),
            .make("B b", "Bee", [.at(may5, "P", lat: 1, lon: 1)]),
        ])

        let store = makeStore(scratch, defaults)
        store.flushPendingWrites()

        #expect(store.starredNames == ["A a"])
        #expect(try scratch.readStars() == ["A a"])
    }

    // MARK: - Export ledger

    @Test("an undecodable export ledger is never written over")
    func undecodableLedgerIsNotOverwritten() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeRaw("exported_observations.json", "{ this is not JSON")

        let store = makeStore(scratch, defaults)
        store.markExported(["Some sci|2026-05-04|Somewhere|1.00000|2.00000"])
        store.flushPendingWrites()

        #expect(
            scratch.data("exported_observations.json") == Data("{ this is not JSON".utf8),
            "the record of what eBird already holds is the one thing with no way back"
        )
    }

    /// The consequence, stated in the terms the user would meet it in.
    ///
    /// A launch that couldn't read the ledger holds an empty one, and an empty
    /// ledger means "nothing has ever been exported" — so a `.newOnly` export
    /// offers up sightings eBird already has. The retry at the top of the export
    /// path is what closes that, and it runs before the snapshot the export is
    /// built from.
    @Test("a ledger that failed to load doesn't make exported sightings look new")
    func failedLedgerReadDoesNotResurrectExportedSightings() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let sighting = native(may4)
        try scratch.writeLifeList([.make("Cardinalis cardinalis", "Northern Cardinal", [sighting])])
        try scratch.obstruct("exported_observations.json")

        let store = makeStore(scratch, defaults)

        // The window closes before the user reaches the export sheet, which is
        // the ordinary case: the ledger is only ever consulted long after launch.
        try scratch.clearObstruction("exported_observations.json")
        try scratch.writeExportedKeys([key("Cardinalis cardinalis", sighting)])

        #expect(
            store.observationCount(for: .newOnly) == 0,
            "this sighting is already in eBird's hands, and the ledger says so"
        )
        #expect(store.observationCount(for: .everything) == 1, "Export All is unaffected either way")
    }

    /// Why the retry unions rather than replaces.
    ///
    /// A `markExported` that ran while the read was failing left keys in memory
    /// that never reached disk — and those describe records eBird now holds just
    /// as much as the ones on disk do. Replacing the in-memory set with the file
    /// would drop exactly those, which is the same unrecoverable loss by a
    /// narrower route.
    @Test("the ledger retry keeps keys marked while the file was unreadable")
    func ledgerRetryUnionsRatherThanReplaces() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let onDisk = native(may4)
        let markedMeanwhile = native(may5)
        try scratch.obstruct("exported_observations.json")

        let store = makeStore(scratch, defaults)
        store.markExported([key("Cardinalis cardinalis", markedMeanwhile)])

        try scratch.clearObstruction("exported_observations.json")
        try scratch.writeExportedKeys([key("Cardinalis cardinalis", onDisk)])

        // Any ledger read triggers the retry.
        _ = store.observationCount(for: .newOnly)
        store.flushPendingWrites()

        #expect(
            store.exportedObservationKeys == [
                key("Cardinalis cardinalis", onDisk),
                key("Cardinalis cardinalis", markedMeanwhile),
            ],
            "the ledger is append-only, so both halves survive"
        )
        #expect(try scratch.readExportedKeys().count == 2, "and both are now persisted")
    }

    /// The subtle one. Canonicalization can rename a species during `load()`, and
    /// `migrateRenamedState` moves that species' ledger keys onto the new name —
    /// but on a launch whose ledger failed to read there are no keys in memory to
    /// move, so the migration finds nothing and the rename is over.
    ///
    /// The keys the retry then reads off disk are filed under the name the bird
    /// *used* to have, which matches nothing the exporter builds. That is the
    /// orphaned-key duplicate `LifeListStoreExportLedgerMigrationTests` exists to
    /// prevent, reached one step later — so the rename is held (see
    /// `deferredKeyRenames`) and applied to whatever the retry finds.
    @Test("a rename made while the ledger was unreadable still moves its keys")
    func renameDuringFailedLedgerReadIsAppliedOnRetry() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        let sighting = native(may4)
        // Stored under eBird's spelling; the alias table rewrites it to BirdNET's
        // during `load()`.
        try scratch.writeLifeList([
            .make("Leuconotopicus villosus", "Hairy Woodpecker", [sighting]),
        ])
        try scratch.obstruct("exported_observations.json")

        let store = makeStore(scratch, defaults)
        #expect(store.entries[0].scientificName == "Dryobates villosus", "the name moved")

        // The ledger becomes readable, still keyed to the old name.
        try scratch.clearObstruction("exported_observations.json")
        try scratch.writeExportedKeys([key("Leuconotopicus villosus", sighting)])

        #expect(
            store.observationCount(for: .newOnly) == 0,
            "the key followed the rename, so eBird isn't handed a second copy"
        )
        store.flushPendingWrites()
        #expect(
            try scratch.readExportedKeys().contains(key("Dryobates villosus", sighting)),
            "and the move is persisted, so the next launch doesn't have to redo it"
        )
    }

    /// The regression guard for the third case, as with the stars: an absent
    /// ledger really does mean nothing has been exported.
    @Test("an absent export ledger is an empty one")
    func absentLedgerIsEmpty() throws {
        let scratch = ScratchDirectory(), defaults = ScratchDefaults()
        try scratch.writeLifeList([
            .make("Cardinalis cardinalis", "Northern Cardinal", [native(may4)]),
        ])

        let store = makeStore(scratch, defaults)
        #expect(store.exportedObservationKeys.isEmpty)
        #expect(
            store.observationCount(for: .newOnly) == 1,
            "nothing has been handed over, so the sighting is new"
        )

        // And writing works normally — the refusal is scoped to a failed read.
        store.markExported(["k"])
        store.flushPendingWrites()
        #expect(try scratch.readExportedKeys() == ["k"])
    }
}
