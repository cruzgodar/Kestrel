import Foundation

/// An async job that runs one at a time, with concurrent requests folded onto
/// the run already in flight.
///
/// The shape a shared recomputation wants when several unrelated events ask for
/// it at once, the work resolves some device resource, and the result is a
/// single value everybody then reads. Run in parallel, those requests each
/// resolve the resource and each assign the result — so what the app keeps is
/// whichever finished last rather than whichever knew the most, and the runs
/// that lose the resource (a second concurrent asker being told "no fix
/// available") are exactly the ones that compute the emptiest answer.
///
/// `request(force:)` waits for the work either way, so a caller that needs the
/// value can await it.
@MainActor
final class CoalescedJob {
    private let work: () async -> Void
    private var running: Task<Void, Never>?

    /// How many times the work has actually run.
    private(set) var runCount = 0
    /// How many callers are waiting on the run in flight.
    private(set) var joinerCount = 0
    /// Whether a further run is already scheduled — see `request(force:)`.
    private(set) var isRerunScheduled = false

    // The three counters above are diagnostics, and they are what a test waits
    // on: the behavior being pinned here is *when* requests overlap, and without
    // something to observe, a test can only guess at an interleaving with a
    // fixed number of `Task.yield()`s and pass whether or not it produced one.

    init(_ work: @escaping () async -> Void) {
        self.work = work
    }

    /// Whether a run is in flight.
    var isRunning: Bool { running != nil }

    /// Runs the job, or joins the run already in flight.
    ///
    /// `force` is for a caller whose *inputs* differ from the run in flight — it
    /// holds something that run was started without, so joining would settle on
    /// an answer computed in ignorance of it. Exactly one further run is
    /// scheduled however many forced requests arrive during the current one:
    /// they all want the same next answer, and running once per request would
    /// just rebuild it that many times.
    ///
    /// A forced caller still returns as soon as the run it joined finishes,
    /// rather than waiting out the rerun it asked for. Every caller today is
    /// fire-and-forget, and the alternative — holding each one until the last
    /// scheduled rerun completes — makes a burst of requests take as long as all
    /// of them put together for no reader's benefit.
    func request(force: Bool = false) async {
        if let running {
            if force { isRerunScheduled = true }
            joinerCount += 1
            await running.value
            joinerCount -= 1
            return
        }
        repeat {
            // Cleared once per run, and — the part that matters — with no
            // suspension between the loop condition's read of it below and this
            // write. A request can therefore only ever set it from inside a
            // run's own window, so it is always attributed to the run it
            // overlapped and always earns a further one.
            isRerunScheduled = false
            runCount += 1
            let task = Task { await self.work() }
            running = task
            await task.value
            running = nil
        } while isRerunScheduled
    }
}
