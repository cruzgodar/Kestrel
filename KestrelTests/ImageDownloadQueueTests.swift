import Foundation
import Testing
@testable import Kestrel

/// The prefetch queue's ordering, coalescing, and — the reason this suite
/// exists — what `waitUntilIdle` actually waits for.
///
/// That last one is load-bearing in a way it doesn't look. The background
/// prefetch task holds its `BGTask` runtime assertion open across
/// `waitUntilIdle`, because a foreground-style `URLSession` download is
/// suspended the instant the app is. Waiting on the wrong thing therefore
/// doesn't merely take longer — it spends a scarce, OS-rationed background
/// window on work that isn't the prefetch's.
@Suite("ImageDownloadQueue")
struct ImageDownloadQueueTests {

    /// A download closure whose completion the test controls, so "in flight" is a
    /// state the test can hold the queue in rather than race against.
    ///
    /// `blocking` names the slugs that park until `openGate`; everything else
    /// runs straight through. That's what lets a test occupy the queue's only
    /// worker with one download while it arranges the rest.
    ///
    /// **Signalling, not polling.** An earlier version of this harness spun on
    /// `Task.sleep(5ms)` loops, and with several of these suites running
    /// concurrently that was enough spinning to starve the cooperative pool —
    /// downloads that should have started in microseconds hadn't run seconds
    /// later, and the tests failed on their own scheduling rather than on
    /// anything in the queue. Every wait here now parks on a continuation and is
    /// resumed by the event it was waiting for, so the suite costs no CPU while
    /// it waits.
    private actor Gate {
        private let blocking: Set<String>?
        private var open = false
        private var gateWaiters: [CheckedContinuation<Void, Never>] = []

        /// Slugs whose download body has begun, in order.
        private(set) var started: [String] = []
        private var startWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

        /// Bumped by a caller immediately before it enters the queue, so a test
        /// can wait for a call to be under way rather than sleeping and hoping.
        private(set) var callers = 0
        private var callerWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

        /// `nil` blocks every slug.
        init(blocking: Set<String>? = nil) { self.blocking = blocking }

        // MARK: the download side

        func recordStart(_ slug: String) {
            started.append(slug)
            let met = startWaiters.filter { started.count >= $0.target }
            startWaiters.removeAll { started.count >= $0.target }
            for waiter in met { waiter.continuation.resume() }
        }

        func waitIfBlocking(_ slug: String) async {
            if let blocking, !blocking.contains(slug) { return }
            if open { return }
            await withCheckedContinuation { gateWaiters.append($0) }
        }

        // MARK: the test side

        func openGate() {
            open = true
            let waiting = gateWaiters
            gateWaiters = []
            for continuation in waiting { continuation.resume() }
        }

        func recordCaller() {
            callers += 1
            let met = callerWaiters.filter { callers >= $0.target }
            callerWaiters.removeAll { callers >= $0.target }
            for waiter in met { waiter.continuation.resume() }
        }

        /// Parks until at least `count` downloads have begun.
        func waitForStarts(_ count: Int) async {
            if started.count >= count { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }

        /// Parks until at least `count` callers have announced themselves.
        func waitForCallers(_ count: Int) async {
            if callers >= count { return }
            await withCheckedContinuation { callerWaiters.append((count, $0)) }
        }

        /// Set by a `waitUntilIdle` that has returned, so a test can assert the
        /// wait was still outstanding at a moment it chooses.
        private(set) var drained = false
        func recordDrained() { drained = true }
    }

    private func request(_ slug: String, _ size: ImageSize = .thumb) -> ImageDownloadQueue.Request {
        .init(slug: slug, name: slug, size: size)
    }

    /// A download closure wired to `gate`, which every test here uses.
    private func downloader(_ gate: Gate) -> @Sendable (String, String, ImageSize) async -> Data? {
        { slug, _, _ in
            await gate.recordStart(slug)
            await gate.waitIfBlocking(slug)
            return Data()
        }
    }

    // MARK: waitUntilIdle

    @Test("waitUntilIdle returns immediately when nothing is queued", .timeLimit(.minutes(1)))
    func idleWhenEmpty() async {
        let queue = ImageDownloadQueue { _, _, _ in nil }
        await queue.waitUntilIdle()
    }

    /// Times out rather than fails if the wait stops covering bulk work.
    @Test("waitUntilIdle waits for queued prefetch work to finish", .timeLimit(.minutes(1)))
    func waitsForBulkWork() async {
        let gate = Gate()
        let queue = ImageDownloadQueue(download: downloader(gate))
        await queue.enqueue((0..<4).map { request("bulk\($0)") }, tier: .nearbyThumb)

        let finished = Task {
            await queue.waitUntilIdle()
            await gate.recordDrained()
        }
        await gate.waitForStarts(4)
        // The gate is shut, so no download has returned and the drain cannot have
        // happened — the wait must therefore still be outstanding.
        #expect(await gate.drained == false, "waitUntilIdle returned with four downloads parked")

        await gate.openGate()
        await finished.value
        #expect(await gate.drained)
        #expect(await gate.started.count == 4)
    }

    /// The fix under test. An on-demand `fetch` — a list loading a thumbnail, the
    /// watch bridge asking for a photo — has nothing to do with the prefetch being
    /// drained, but it lives in the same `inFlight` map. Gating the wait on that
    /// map kept a background window open for whatever the UI happened to be
    /// loading. This test hangs to its time limit if that regresses.
    @Test("waitUntilIdle ignores an in-flight on-demand fetch", .timeLimit(.minutes(1)))
    func ignoresOnDemandFetch() async {
        let gate = Gate()
        let queue = ImageDownloadQueue(download: downloader(gate))
        // Start an on-demand fetch and leave it hanging. Nothing is enqueued.
        let onDemand = Task { await queue.fetch(slug: "urgent", name: "urgent", size: .medium) }
        await gate.waitForStarts(1)

        // The prefetch is drained — there was never anything in it — so this must
        // return even though a download is very much in flight.
        await queue.waitUntilIdle()

        await gate.openGate()
        _ = await onDemand.value
    }

    // MARK: ordering

    /// Tier priority is applied **when a worker slot frees**, not retroactively:
    /// the queue starts whatever is available the moment it has room, so a job
    /// enqueued while the queue is idle begins immediately whatever its tier.
    /// That's why `RemoteSpeciesImageStore.enqueuePrefetch` fills the tiers in
    /// priority order to begin with. What this asserts is the part that governs a
    /// real wake, where far more work is queued than there are workers: once the
    /// queue is saturated, the next free slot goes to the highest tier waiting.
    @Test("a freed worker slot goes to the highest waiting tier", .timeLimit(.minutes(1)))
    func freedSlotGoesToHighestTier() async {
        let gate = Gate(blocking: ["filler"])
        // One worker, so the start order *is* the drain order.
        let queue = ImageDownloadQueue(maxConcurrent: 1, download: downloader(gate))
        // Occupy the only worker, then queue the rest behind it in *reverse*
        // priority order so tier — not arrival — has to decide.
        await queue.enqueue([request("filler")], tier: .nearbyThumb)
        await gate.waitForStarts(1)

        await queue.enqueue([request("late", .medium)], tier: .lifeListMedium)
        await queue.enqueue([request("middle")], tier: .lifeListThumb)
        await queue.enqueue([request("early")], tier: .nearbyThumb)

        await gate.openGate()
        await queue.waitUntilIdle()
        let order = await gate.started
        #expect(order == ["filler", "early", "middle", "late"], "\(order)")
    }

    // MARK: coalescing

    /// A species that is both nearby and on the life list is enqueued twice. Two
    /// entries, one download — and at the earlier tier, so it lands with the
    /// group it was first asked for with.
    @Test("a slug queued in two tiers is downloaded once", .timeLimit(.minutes(1)))
    func duplicateEnqueueIsDroppedAtTheLaterTier() async {
        let gate = Gate(blocking: ["filler"])
        let queue = ImageDownloadQueue(maxConcurrent: 1, download: downloader(gate))
        await queue.enqueue([request("filler")], tier: .nearbyThumb)
        await gate.waitForStarts(1)

        await queue.enqueue([request("bird")], tier: .nearbyThumb)
        await queue.enqueue([request("bird")], tier: .lifeListThumb)
        await queue.enqueue([request("other")], tier: .lifeListThumb)

        await gate.openGate()
        await queue.waitUntilIdle()
        // "bird" once, and ahead of the life-list tier it was also asked for in.
        #expect(await gate.started == ["filler", "bird", "other"])
    }

    /// Repeats inside a single batch collapse too.
    @Test("the same request repeated in one batch is downloaded once", .timeLimit(.minutes(1)))
    func repeatedRequestsInOneBatchCollapse() async {
        let gate = Gate(blocking: [])
        let queue = ImageDownloadQueue(download: downloader(gate))
        await queue.enqueue(Array(repeating: request("same"), count: 5), tier: .nearbyThumb)
        await queue.waitUntilIdle()
        #expect(await gate.started == ["same"])
    }

    /// The on-demand path joins a bulk download already in flight rather than
    /// starting a second one — the case that matters when a row scrolls into view
    /// for a species the prefetch is already fetching.
    ///
    /// The delicate part is proving the on-demand call arrived *while* the bulk
    /// download was still running. Waiting only for the caller to announce itself
    /// is not enough: announcing happens before it reaches the queue, so opening
    /// the gate at that point lets the bulk download finish first, and the
    /// on-demand call then legitimately starts its own — which is correct
    /// behavior and a meaningless test. The barrier below closes that window
    /// without resorting to a sleep.
    @Test("an on-demand fetch joins a bulk download in flight", .timeLimit(.minutes(1)))
    func onDemandJoinsBulkDownload() async {
        let gate = Gate(blocking: ["bird"])
        let queue = ImageDownloadQueue(maxConcurrent: 1, download: downloader(gate))
        await queue.enqueue([request("bird")], tier: .lifeListMedium)
        // The bulk download is now running and parked on the shut gate, so
        // `inFlight` holds its task.
        await gate.waitForStarts(1)

        let onDemand = Task { () -> Data? in
            await gate.recordCaller()
            return await queue.fetch(slug: "bird", name: "bird", size: .thumb)
        }
        await gate.waitForCallers(1)

        // Barrier: a fetch for an unrelated, non-blocking slug, issued after the
        // one above. It is enqueued on the queue actor behind that call, so its
        // completion means that call has already been served — it is inside
        // `run`, and has either joined the in-flight download or started its own.
        // Only then is it meaningful to release the gate.
        _ = await queue.fetch(slug: "probe", name: "probe", size: .thumb)

        await gate.openGate()
        _ = await onDemand.value
        await queue.waitUntilIdle()
        // A second download would have appended a second "bird".
        let started = await gate.started
        #expect(started.filter { $0 == "bird" }.count == 1, "\(started)")
        #expect(started.contains("probe"), "the barrier itself ran: \(started)")
    }

    /// The same slug at two sizes is two different assets.
    @Test("size is part of the coalescing key", .timeLimit(.minutes(1)))
    func sizeIsPartOfTheKey() async {
        let gate = Gate(blocking: [])
        let queue = ImageDownloadQueue(maxConcurrent: 1) { slug, _, size in
            await gate.recordStart("\(slug)-\(size.folder)")
            return Data()
        }
        await queue.enqueue([request("bird", .thumb)], tier: .nearbyThumb)
        await queue.enqueue([request("bird", .medium)], tier: .nearbyMedium)
        await queue.waitUntilIdle()
        #expect(await gate.started == ["bird-thumb", "bird-hero"])
    }

    @Test("resetPrefetch drops queued work so a fresh wake can re-prioritize", .timeLimit(.minutes(1)))
    func resetDropsQueuedWork() async {
        let gate = Gate(blocking: ["filler"])
        let queue = ImageDownloadQueue(maxConcurrent: 1, download: downloader(gate))
        await queue.enqueue([request("filler")], tier: .nearbyThumb)
        await gate.waitForStarts(1)

        await queue.enqueue((0..<3).map { request("stale\($0)") }, tier: .lifeListMedium)
        await queue.resetPrefetch()
        await queue.enqueue([request("fresh")], tier: .nearbyThumb)

        await gate.openGate()
        await queue.waitUntilIdle()
        let started = await gate.started
        #expect(started == ["filler", "fresh"], "\(started)")
    }
}
