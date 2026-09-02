import Foundation
import Testing
@testable import Kestrel

/// What the export sheet is partway through, and what happens to it when the
/// sheet goes away underneath it.
///
/// The CSV render is an unstructured task started from a button in the sheet and
/// tied to nothing — the sheet stays swipe-dismissable for the whole of it, and
/// on the large life list the progress card exists for that is seconds of
/// opportunity. Every field here is written *after* the render finishes and read
/// only by the sheet, so a result landing after the sheet has gone leaves state
/// nothing on screen can show, clear, or answer for: an armed save panel with
/// nowhere to present (which the *next* visit to Export then honors, over the
/// previous run's file), or a "Nothing to Export" alert about an attempt the user
/// abandoned.
///
/// Clearing on `onDismiss` alone did not close that: dismissal completes in about
/// a third of a second and the render it is racing runs for seconds, so the clear
/// lands *first* and the stale write follows it. The run token is what actually
/// closes it, and it is what these tests are about.
@MainActor
@Suite("Export session")
struct ExportSessionTests {

    private func payload(rows: Int = 3) -> EBirdCSVExporter.Payload {
        EBirdCSVExporter.makeCSV(rows: (0..<rows).map { i in
            EBirdCSVExporter.Row(
                scientificName: "Cardinalis cardinalis",
                commonName: "Northern Cardinal",
                observation: LifeListEntry.Observation(
                    date: utcDay(2026, 5, 4 + i),
                    location: "Ithaca",
                    latitude: 42.45,
                    longitude: -76.5
                )
            )
        })
    }

    // MARK: the ordinary run

    @Test("a run that finishes while its sheet is up arms the save panel")
    func normalRunPresents() {
        let session = ExportSession()
        let run = session.begin()
        #expect(session.applies(run))

        session.present(payload: payload(), scope: .newOnly)
        #expect(session.isSaving)
        #expect(session.document != nil)
        #expect(session.payload != nil)
        #expect(session.scope == .newOnly)
    }

    @Test("an empty run reports itself instead of arming the save panel")
    func emptyRunReports() {
        let session = ExportSession()
        session.begin()
        session.reportEmpty(scope: .newOnly)
        #expect(session.emptyScope == .newOnly)
        #expect(!session.isSaving)
        #expect(session.document == nil)
    }

    /// The save panel closing drops the file but leaves the token where it is —
    /// nothing is outstanding at that point, and bumping it would be bumping it
    /// for no one.
    @Test("finishing the save drops the file and keeps the token")
    func finishClearsTheFile() {
        let session = ExportSession()
        let run = session.begin()
        session.present(payload: payload(), scope: .everything)
        session.finish()

        #expect(session.payload == nil)
        #expect(session.scope == nil)
        #expect(session.document == nil)
        #expect(session.applies(run), "nothing was outstanding, so nothing was retired")
    }

    // MARK: the sheet going away mid-render

    /// The bug, stated directly: a render that outlives its sheet must not be
    /// able to arm the save panel, because nothing is left to present it or to
    /// put it away again.
    @Test("a run whose sheet was dismissed no longer applies")
    func abandonRetiresTheRunInFlight() {
        let session = ExportSession()
        let run = session.begin()

        session.abandon()

        #expect(!session.applies(run))
    }

    /// The other half of the same bug: `emptyScope` set after the dismissal had
    /// already cleared it is what greeted the *next* visit to Export with
    /// "Nothing to Export" about an attempt that was already over.
    @Test("dismissal clears every field the sheet owns")
    func abandonClearsEverything() {
        let session = ExportSession()
        session.begin()
        session.present(payload: payload(), scope: .newOnly)
        session.reportEmpty(scope: .everything)

        session.abandon()

        #expect(!session.isSaving)
        #expect(session.document == nil)
        #expect(session.payload == nil)
        #expect(session.scope == nil)
        #expect(session.emptyScope == nil)
    }

    /// The whole point of retiring the token is that the caller checks it. This
    /// is the sequence `beginExport` actually walks: begin, sheet dismissed
    /// mid-render, render finishes and asks whether it still counts.
    @Test("a stale run's result is dropped rather than written")
    func staleRunWritesNothing() {
        let session = ExportSession()
        let run = session.begin()
        session.abandon()

        // What `beginExport` does with the answer.
        if session.applies(run) {
            session.present(payload: payload(), scope: .newOnly)
        }

        #expect(!session.isSaving, "the save panel must not be armed with no sheet to present it")
        #expect(session.document == nil)
        #expect(session.emptyScope == nil)
    }

    /// Reopening Export after abandoning one render must behave like a first
    /// visit — not like the previous one is still going.
    @Test("a fresh run after a dismissal starts clean and applies")
    func freshRunAfterAbandonApplies() {
        let session = ExportSession()
        let stale = session.begin()
        session.abandon()

        let current = session.begin()
        #expect(!session.applies(stale))
        #expect(session.applies(current))

        session.present(payload: payload(), scope: .newOnly)
        #expect(session.isSaving)
    }

    // MARK: two taps in one visit

    /// Tapping Export All and then Export New without waiting starts two renders
    /// against one sheet. Only the second one's answer is the one the user asked
    /// for last, and the first must not land on top of it.
    @Test("a second tap retires the first tap's run")
    func secondTapSupersedesTheFirst() {
        let session = ExportSession()
        let first = session.begin()
        let second = session.begin()

        #expect(!session.applies(first))
        #expect(session.applies(second))
    }

    // MARK: the progress card

    /// The card is the one piece of a run's state that is *shared* between runs,
    /// so it is the one a superseded run can damage rather than merely waste.
    /// Both taps land inside the 180 ms before the card appears — after which it
    /// dims the sheet and swallows the second tap — so this is the window.

    @Test("the run the sheet is waiting on can raise and lower the card")
    func liveRunDrivesTheCard() {
        let session = ExportSession()
        let progress = ExportProgress()
        let run = session.begin()

        #expect(session.setProgressVisible(true, run: run, on: progress))
        #expect(progress.isVisible)
        #expect(session.setProgressVisible(false, run: run, on: progress))
        #expect(!progress.isVisible)
    }

    /// The regression: run one finishes while run two is still rendering. Run
    /// two's reveal has already fired and will not fire again, so hiding the card
    /// here left it rendering behind a blank sheet until it finished.
    @Test("a superseded run cannot hide the card its successor raised")
    func supersededRunLeavesTheCardAlone() {
        let session = ExportSession()
        let progress = ExportProgress()
        let first = session.begin()
        let second = session.begin()
        session.setProgressVisible(true, run: second, on: progress)

        #expect(!session.setProgressVisible(false, run: first, on: progress),
                "the write is refused")
        #expect(progress.isVisible, "so the live run's card stays up")
    }

    /// The other half: the sheet is swiped away 100 ms in, and the reveal fires at
    /// 180 ms. A card raised then has nothing drawing it, and nothing left to
    /// clear it — the *next* visit to Export opened onto it.
    @Test("an abandoned run cannot raise the card after its sheet has gone")
    func abandonedRunCannotRaiseTheCard() {
        let session = ExportSession()
        let progress = ExportProgress()
        let run = session.begin()
        session.abandon()

        #expect(!session.setProgressVisible(true, run: run, on: progress))
        #expect(!progress.isVisible)
    }

    /// A run can lose the sheet *between* the guard and the write — the hide waits
    /// out a 320 ms beat so the finished bar is readable, and the sheet is
    /// dismissable across it. The gate lives on the write for that reason.
    @Test("a run that loses its sheet mid-beat stops writing")
    func runLosingItsSheetMidBeatStopsWriting() {
        let session = ExportSession()
        let progress = ExportProgress()
        let run = session.begin()
        session.setProgressVisible(true, run: run, on: progress)
        #expect(session.applies(run), "still the sheet's run when the beat starts")

        // The sheet goes away while the beat is running; `onDismiss` puts the
        // card away with everything else it owned.
        session.abandon()
        progress.isVisible = false

        #expect(!session.setProgressVisible(false, run: run, on: progress))
    }

    @Test("the run token keeps rising, so a retired token is never reissued")
    func tokensAreMonotonic() {
        let session = ExportSession()
        var seen: Set<Int> = [session.run]
        for _ in 0..<50 {
            seen.insert(session.begin())
            session.abandon()
            seen.insert(session.run)
        }
        #expect(seen.count == 101, "every begin and every abandon names a distinct run")
    }
}
