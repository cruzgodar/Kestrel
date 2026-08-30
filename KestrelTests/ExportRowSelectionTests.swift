import Foundation
import Testing
@testable import Kestrel

/// Which sightings an export writes, and where that decision runs.
///
/// `LifeListStore.exportRows` is the whole selection: it flattens the life list
/// to one row per observation and, for `.newOnly`, asks the export ledger about
/// every one of them. That question is not cheap — each row builds two ledger
/// keys, and each key renders a date, folds a place name character by character
/// and formats two coordinates — which is why it is a `nonisolated static` taking
/// its inputs by value: so `makeEBirdExport` can run the whole thing off the main
/// actor instead of detaching only the CSV rendering and leaving the equally
/// expensive half on the tap's frame.
///
/// What it decides matters more than where it runs. eBird's importer does no
/// deduplication whatsoever, so a row that shouldn't have been in a `.newOnly`
/// file becomes a second copy of a record the user already has, in their real
/// account, which they then unpick by hand.
@Suite("Export row selection")
struct ExportRowSelectionTests {

    private let may4 = utcDay(2026, 5, 4)
    private let may5 = utcDay(2026, 5, 5)

    private func cardinal(_ observations: [LifeListEntry.Observation]) -> LifeListEntry {
        .make("Cardinalis cardinalis", "Northern Cardinal", observations)
    }

    private func rows(
        _ entries: [LifeListEntry],
        _ scope: LifeListStore.ExportScope,
        exported: Set<String> = []
    ) -> [EBirdCSVExporter.Row] {
        LifeListStore.exportRows(from: entries, scope: scope, exportedKeys: exported)
    }

    // MARK: everything

    @Test("Export All writes one row per observation, whatever its provenance")
    func everythingTakesEveryObservation() {
        let entries = [
            cardinal([
                .at(may4, "Ithaca NY", lat: 42.45342, lon: -76.47352),
                .at(may5, "Ithaca NY", lat: 42.45342, lon: -76.47352, imported: true),
            ]),
            .make("Turdus migratorius", "American Robin", [.at(may4, "Ithaca NY")]),
        ]
        let selected = rows(entries, .everything)
        #expect(selected.count == 3, "a species contributes a row per sighting, not one flat")
    }

    /// Export All is documented as ignoring the ledger entirely — it's the "give
    /// me the whole list" operation (a backup, a re-upload, a file for something
    /// other than eBird), not a handover.
    @Test("Export All ignores the ledger and the imported flag")
    func everythingIgnoresTheLedger() {
        let observation = LifeListEntry.Observation.at(may4, "Ithaca NY", imported: true)
        let entry = cardinal([observation])
        let key = EBirdCSVExporter.key(
            scientificName: "Cardinalis cardinalis", observation: observation
        )
        #expect(rows([entry], .everything, exported: [key]).count == 1)
    }

    // MARK: newOnly

    @Test("Export New keeps a sighting recorded in Kestrel and never sent")
    func newOnlyKeepsFreshSightings() {
        let entry = cardinal([.at(may4, "Ithaca NY", lat: 42.45342, lon: -76.47352)])
        #expect(rows([entry], .newOnly).count == 1)
    }

    /// It came *from* eBird, so handing it back would duplicate a record that
    /// account already holds.
    @Test("Export New drops an imported sighting")
    func newOnlyDropsImported() {
        let entry = cardinal([.at(may4, "Ithaca NY", imported: true)])
        #expect(rows([entry], .newOnly).isEmpty)
    }

    @Test("Export New drops a sighting a previous export already handed over")
    func newOnlyDropsExported() {
        let observation = LifeListEntry.Observation.at(
            may4, "Ithaca NY", lat: 42.45342, lon: -76.47352
        )
        let key = EBirdCSVExporter.key(
            scientificName: "Cardinalis cardinalis", observation: observation
        )
        #expect(rows([cardinal([observation])], .newOnly, exported: [key]).isEmpty)
    }

    /// The ledger is the one piece of state whose loss can't be undone, and its
    /// place component changed format once. A ledger written by an earlier build
    /// is full of the old form, and nothing migrates it — so the selection has to
    /// recognize both, or the next Export New hands the user a second copy of
    /// everything they already uploaded.
    @Test("Export New recognizes a ledger key in the pre-fold format")
    func newOnlyDropsLegacyExported() {
        // A place name the fold changes, so the two key formats genuinely differ.
        let observation = LifeListEntry.Observation.at(
            may4, "Ithaca, NY", lat: 42.45342, lon: -76.47352
        )
        let legacy = EBirdCSVExporter.legacyKey(
            scientificName: "Cardinalis cardinalis", observation: observation
        )
        let current = EBirdCSVExporter.key(
            scientificName: "Cardinalis cardinalis", observation: observation
        )
        #expect(legacy != current, "otherwise this test proves nothing")
        #expect(rows([cardinal([observation])], .newOnly, exported: [legacy]).isEmpty)
    }

    @Test("Export New splits a species' own sightings, keeping only the new ones")
    func newOnlyIsPerObservation() {
        let sent = LifeListEntry.Observation.at(may4, "Ithaca NY")
        let key = EBirdCSVExporter.key(scientificName: "Cardinalis cardinalis", observation: sent)
        let entry = cardinal([
            sent,
            .at(may5, "Ithaca NY"),                    // fresh
            .at(may5, "Sapsucker Woods", imported: true),  // came from eBird
        ])
        let selected = rows([entry], .newOnly, exported: [key])
        #expect(selected.count == 1, "one of the three is new to eBird")
        #expect(selected.first?.observation.date == may5)
        #expect(selected.first?.observation.location == "Ithaca NY")
    }

    // MARK: the two callers agree

    /// `observationCount(for:)` and the export itself must never disagree about
    /// what a scope covers — the count is what a caller reasons about before the
    /// file exists. They're one function now precisely so they can't drift.
    @Test("the count and the rows are the same answer")
    @MainActor
    func countMatchesRows() async {
        let scratch = ScratchDirectory()
        let defaults = ScratchDefaults()
        let store = makeStore(scratch, defaults)

        store.recordObservation(
            scientificName: "Cardinalis cardinalis",
            commonName: "Northern Cardinal",
            date: may4,
            location: "Ithaca NY",
            latitude: 42.45342,
            longitude: -76.47352
        )
        store.addObservation(
            scientificName: "Cardinalis cardinalis", date: may5, location: "Sapsucker Woods"
        )

        #expect(store.observationCount(for: .everything) == 2)
        #expect(store.observationCount(for: .newOnly) == 2)

        let payload = await store.makeEBirdExport(scope: .newOnly)
        #expect(payload.observationCount == store.observationCount(for: .newOnly))

        // And once one of them is handed over, both move together.
        store.markExported(payload.exportedKeys)
        #expect(store.observationCount(for: .newOnly) == 0)
        let after = await store.makeEBirdExport(scope: .newOnly)
        #expect(after.observationCount == 0, "an emptied scope is what the sheet reports on")
        #expect(store.observationCount(for: .everything) == 2, "Export All still writes them")
    }

    /// The point of the signature: the selection has to be runnable off the main
    /// actor, because that is where `makeEBirdExport` now does it. A version that
    /// touched store state would not compile here.
    @Test("the selection runs off the main actor")
    func runsOffTheMainActor() async {
        let entries = [cardinal([.at(may4, "Ithaca NY"), .at(may5, "Ithaca NY", imported: true)])]
        let count = await Task.detached {
            LifeListStore.exportRows(from: entries, scope: .newOnly, exportedKeys: []).count
        }.value
        #expect(count == 1)
    }
}
