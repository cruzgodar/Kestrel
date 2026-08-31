import Foundation
import Testing
@testable import Kestrel

/// `CoalescedJob` — the one-at-a-time wrapper the nearby-species filter runs
/// behind.
///
/// The behavior under test isn't "don't do redundant work". It's that a shared
/// recomputation which several events request at once must not end up with the
/// answer from whichever *run* finished last, because the runs that lose the
/// race for the device resource they need are the ones that produce the emptiest
/// answer — a second concurrent asker for a location fix used to be told there
/// wasn't one, and a species filter built on no location is no filter at all.
@Suite("CoalescedJob")
@MainActor
struct CoalescedJobTests {

    /// Lets a test hold the job open at a known point, so requests can be made
    /// while a run is provably in flight rather than hoping for an interleaving.
    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func openGate() {
            open = true
            let pending = waiters
            waiters.removeAll()
            for c in pending { c.resume() }
        }
    }

    /// Yields until `condition` holds. Everything here is main-actor and
    /// cooperative, so this settles in a turn or two; the bound is only so a
    /// genuine failure reports as a failed expectation instead of hanging the
    /// suite. Counting fixed `Task.yield()`s instead would pin the tests to how
    /// many hops the implementation happens to take today.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test("a request with nothing in flight runs the work once")
    func runsOnce() async {
        var runs = 0
        let job = CoalescedJob { runs += 1 }
        await job.request()
        #expect(runs == 1)
        #expect(job.runCount == 1)
        #expect(!job.isRunning)
    }

    /// The case the species filter was losing: several unrelated events ask at
    /// once, and every one of them must end up on a single computed answer.
    @Test("requests arriving during a run join it instead of racing it")
    func concurrentRequestsCoalesce() async {
        let gate = Gate()
        var runs = 0
        let job = CoalescedJob {
            runs += 1
            await gate.wait()
        }

        async let first: Void = job.request()
        // Let the first request get as far as the gate before the others arrive.
        await settle(until: { job.isRunning })
        async let second: Void = job.request()
        async let third: Void = job.request()
        await settle(until: { job.joinerCount == 2 })

        gate.openGate()
        _ = await (first, second, third)

        #expect(runs == 1, "three requests, one computed answer")
        #expect(job.runCount == 1)
        #expect(!job.isRunning)
    }

    /// A caller holding an input the run in flight was started without can't
    /// simply take that run's answer — for the species filter this is the watch
    /// arriving with its own coordinate while a refresh built on the phone's
    /// (possibly absent) location is already under way.
    @Test("a forced request during a run schedules exactly one more run")
    func forcedRequestReruns() async {
        let gate = Gate()
        var runs = 0
        let job = CoalescedJob {
            runs += 1
            await gate.wait()
        }

        async let first: Void = job.request()
        await settle(until: { job.isRunning })
        async let forced: Void = job.request(force: true)
        await settle(until: { job.isRerunScheduled })

        gate.openGate()
        _ = await (first, forced)
        // The rerun is scheduled by the owning request, which returns only once
        // the whole chain has drained.
        #expect(runs == 2, "the forced caller's inputs get their own run")
        #expect(job.runCount == 2)
        #expect(!job.isRunning)
    }

    /// However many forced callers pile up, they all want the same *next*
    /// answer — one that accounts for everything known by the time it starts.
    /// Running once per caller would rebuild the identical list N times.
    @Test("several forced requests during one run still schedule only one more")
    func forcedRequestsCollapseToOneRerun() async {
        let gate = Gate()
        var runs = 0
        let job = CoalescedJob {
            runs += 1
            await gate.wait()
        }

        async let first: Void = job.request()
        await settle(until: { job.isRunning })
        async let a: Void = job.request(force: true)
        async let b: Void = job.request(force: true)
        async let c: Void = job.request(force: true)
        await settle(until: { job.joinerCount == 3 })

        gate.openGate()
        _ = await (first, a, b, c)

        #expect(runs == 2)
        #expect(job.runCount == 2)
    }

    /// A rerun is not a "final" run that absorbs everything arriving after it:
    /// a forced request landing *during* one has inputs that run was started
    /// without, exactly as the first forced request did, and earns a further run
    /// of its own. Chaining is what makes the coalescing safe to hold a caller's
    /// input in — otherwise a late-arriving watch coordinate would be swallowed
    /// by a refresh that had already started without it.
    @Test("a forced request during the rerun schedules another one")
    func forcedRequestDuringRerunReruns() async {
        let gates = [Gate(), Gate(), Gate()]
        var runs = 0
        let job = CoalescedJob {
            let gate = gates[min(runs, gates.count - 1)]
            runs += 1
            await gate.wait()
        }

        async let first: Void = job.request()
        await settle(until: { job.isRunning })
        async let forced: Void = job.request(force: true)
        await settle(until: { job.isRerunScheduled })

        // Release run 1; the rerun `forced` asked for starts and parks on its
        // own gate.
        gates[0].openGate()
        await settle(until: { runs == 2 })

        // This request overlaps run 2, so it is run 2's to answer — and run 2
        // is itself a rerun, which is the case worth pinning.
        async let late: Void = job.request(force: true)
        // Not `runs == 2`, which is already true and would wait for nothing:
        // this has to observe the late request actually registering, or the
        // gate below could open before it ever ran and the assertion would hold
        // for the wrong reason.
        await settle(until: { job.isRerunScheduled })
        gates[1].openGate()
        await settle(until: { runs == 3 })
        gates[2].openGate()
        _ = await (first, forced, late)

        #expect(runs == 3, "the late caller's input gets a run of its own")
    }

    /// Once everything has drained the job is idle again, so a later, unrelated
    /// request starts fresh rather than joining a finished run.
    @Test("a request after the job has drained starts a new run")
    func laterRequestStartsFresh() async {
        var runs = 0
        let job = CoalescedJob { runs += 1 }
        await job.request()
        await job.request()
        #expect(runs == 2)
        #expect(job.runCount == 2)
    }
}
