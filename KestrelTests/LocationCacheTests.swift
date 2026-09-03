import Foundation
import Testing
@testable import Kestrel

/// "Where am I now", and how long that stays true.
///
/// The cache had no freshness bound at all: it kept the first fix of the process
/// forever, refreshed only by a session start or an app foreground. So the map's
/// recenter button flew back to wherever the walk began — and, worse, the
/// observation flow's map picker seeded its pin there, which is the coordinate
/// Save Observation writes onto the life list. A bird logged an hour into a walk
/// went on file a mile from where it was heard.
@Suite("Location cache freshness")
@MainActor
struct LocationCacheTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func later(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A stub fix source that counts how often it was asked, so a test can tell
    /// a served cache from a fresh resolve.
    private final class Fixes {
        var next: (latitude: Double, longitude: Double)?
        private(set) var calls = 0

        init(_ next: (latitude: Double, longitude: Double)?) { self.next = next }

        func fetch() async -> (latitude: Double, longitude: Double)? {
            calls += 1
            return next
        }
    }

    /// A cache whose clock is held at `t0` unless a test moves it.
    ///
    /// Pinned rather than left on the wall clock so the tests below keep saying
    /// what they always said: a resolved fix is stamped at `t0`, which is the
    /// instant they pass as `now`. `resolvingFixIsStampedWhenItArrives` is the one
    /// that moves it, and it is the one about the difference.
    private func cache(_ fixes: Fixes, clock: @escaping @MainActor () -> Date) -> LocationCache {
        LocationCache(fetch: { await fixes.fetch() }, clock: clock)
    }

    private func cache(_ fixes: Fixes) -> LocationCache {
        cache(fixes, clock: { [t0] in t0 })
    }

    @Test("with nothing cached it resolves a fix")
    func resolvesWhenEmpty() async {
        let fixes = Fixes((latitude: 42, longitude: -76))
        let subject = cache(fixes)
        let fix = await subject.current(now: t0)
        #expect(fix?.latitude == 42)
        #expect(fixes.calls == 1)
    }

    @Test("a fix inside the freshness window is served from the cache")
    func servesAFreshFix() async {
        let fixes = Fixes((latitude: 42, longitude: -76))
        let subject = cache(fixes)
        _ = await subject.current(now: t0)

        fixes.next = (latitude: 1, longitude: 1)
        let again = await subject.current(now: later(LocationCache.freshness - 1))
        #expect(again?.latitude == 42, "still the cached fix")
        #expect(fixes.calls == 1, "and nothing was asked for it")
    }

    /// The fix at the heart of this: past the window, "current" has to mean
    /// current again.
    @Test("a stale fix is re-resolved rather than served")
    func refreshesAStaleFix() async {
        let fixes = Fixes((latitude: 42, longitude: -76))
        let subject = cache(fixes)
        _ = await subject.current(now: t0)

        fixes.next = (latitude: 43, longitude: -77)
        let again = await subject.current(now: later(LocationCache.freshness))
        #expect(again?.latitude == 43, "the walk moved; so must the answer")
        #expect(fixes.calls == 2)
    }

    /// The user-visible shape of the bug: a session start stamps a coordinate,
    /// the user walks for an hour, then adds an observation. The picker's default
    /// pin must not still be at the trailhead.
    @Test("an add an hour into a walk doesn't pin the trailhead")
    func longWalkDoesNotReuseTheStartingFix() async {
        let fixes = Fixes(nil)
        let subject = cache(fixes)
        subject.update(latitude: 42.45, longitude: -76.47, at: t0)   // session start

        fixes.next = (latitude: 42.50, longitude: -76.40)            // an hour later
        let pin = await subject.current(now: later(3600))
        #expect(pin?.latitude == 42.50)
    }

    /// Offline, or with the fix timing out, a coordinate from earlier in the
    /// walk is still the best answer available — and it is what the recenter
    /// button and the picker had before. Failing to refresh must not blank it.
    @Test("a failed refresh falls back to the stale coordinate")
    func failedRefreshKeepsTheOldFix() async {
        let fixes = Fixes((latitude: 42, longitude: -76))
        let subject = cache(fixes)
        _ = await subject.current(now: t0)

        fixes.next = nil
        let again = await subject.current(now: later(LocationCache.freshness * 10))
        #expect(again?.latitude == 42)
        #expect(fixes.calls == 2, "it did try")
    }

    @Test("with no fix ever resolved it reports nothing")
    func neverAnyFix() async {
        let fixes = Fixes(nil)
        let subject = cache(fixes)
        #expect(await subject.current(now: t0) == nil)
    }

    /// `lastLatitude` / `lastLongitude` are deliberately *not* freshness-bounded:
    /// their one reader is the offline species-filter fallback, which wants the
    /// last place we know of — a coarse regional list from an hour ago beats no
    /// list at all.
    @Test("the last-known coordinate outlives the freshness window")
    func lastKnownIsNotBounded() async {
        let fixes = Fixes((latitude: 42, longitude: -76))
        let subject = cache(fixes)
        _ = await subject.current(now: t0)

        #expect(!subject.isFresh(at: later(LocationCache.freshness)))
        #expect(subject.lastLatitude == 42, "still the last place we know of")
        #expect(subject.lastLongitude == -76)
    }

    // MARK: when a resolved fix is stamped

    /// A fix is only current as of when it *arrived*.
    ///
    /// `LocationProvider.currentLocation` waits up to five seconds, and the
    /// stamp used to be the `now` the question was asked with — from before that
    /// wait. So a slow fix went on file backdated by however long it took,
    /// shortening the very window this class exists to enforce: ask at T, get an
    /// answer at T+5, and it expires at T+60 rather than T+65. Small, and exactly
    /// the kind of small that makes "current" mean something slightly different
    /// from what it says.
    @Test("a fix resolved slowly is stamped when it arrived, not when it was asked for")
    func resolvingFixIsStampedWhenItArrives() async {
        let fixes = Fixes((latitude: 42, longitude: -76))
        // The clock advances five seconds across the fetch, standing in for a
        // provider that took its time.
        var reading = t0
        let subject = cache(fixes, clock: { reading })
        reading = later(5)

        _ = await subject.current(now: t0)

        #expect(subject.lastFixAt == later(5), "stamped on arrival")
        #expect(
            subject.isFresh(at: later(5 + LocationCache.freshness - 1)),
            "so it stays current for a full window from there"
        )
        #expect(!subject.isFresh(at: later(5 + LocationCache.freshness)))
    }

    /// The read side is unchanged: `now` still decides whether the *cached*
    /// coordinate is fresh enough to serve, which is a question about when it was
    /// asked, not about any fetch.
    @Test("a cache hit is judged against the instant the question was asked")
    func cacheHitStillUsesTheQuestionsInstant() async {
        let fixes = Fixes((latitude: 42, longitude: -76))
        let subject = cache(fixes, clock: { .distantFuture })
        subject.update(latitude: 1, longitude: 2, at: t0)

        let served = await subject.current(now: later(LocationCache.freshness - 1))
        #expect(served?.latitude == 1, "served from the cache")
        #expect(fixes.calls == 0, "the clock plays no part in the freshness read")
    }

    @Test("an explicit update restarts the freshness window")
    func updateStampsTheClock() {
        let subject = cache(Fixes(nil))
        subject.update(latitude: 42, longitude: -76, at: t0)
        #expect(subject.isFresh(at: later(LocationCache.freshness - 1)))
        #expect(!subject.isFresh(at: later(LocationCache.freshness)))
    }

    // MARK: two callers at once

    /// A fix source that parks inside `fetch` until the test lets it go, so a
    /// second caller genuinely arrives while the first is still in flight —
    /// which is the only way to exercise the join branch at all.
    private final class GatedFixes {
        private(set) var calls = 0
        private var waiting: CheckedContinuation<Void, Never>?
        /// What the parked fetch returns once released.
        var result: (latitude: Double, longitude: Double)?

        func fetch() async -> (latitude: Double, longitude: Double)? {
            calls += 1
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiting = c
            }
            return result
        }

        /// Releases the parked fetch, yielding until one has actually arrived so
        /// the test can't open a gate nobody is standing at.
        func release() async {
            while waiting == nil { await Task.yield() }
            let c = waiting
            waiting = nil
            c?.resume()
        }
    }

    private func gatedCache(_ fixes: GatedFixes) -> LocationCache {
        LocationCache(fetch: { await fixes.fetch() }, clock: { [t0] in t0 })
    }

    /// **The fallback belongs to every caller.** A second ask that lands while a
    /// fix is in flight joins it rather than starting a second one — and that
    /// join used to hand back the task's raw `nil`, so which of two callers got
    /// the stale coordinate came down to which of them asked first.
    ///
    /// The shape on screen: opening the Map tab starts a warm-up fix, a recenter
    /// tap a moment later joins it, and a fix that then times out left the button
    /// doing nothing at all while a perfectly usable coordinate sat in the cache.
    @Test("a caller that joins an in-flight fix gets the same stale fallback")
    func joinerGetsTheStaleFallback() async {
        let fixes = GatedFixes()
        let subject = gatedCache(fixes)
        subject.update(latitude: 42.45, longitude: -76.47, at: t0)
        let now = later(LocationCache.freshness * 10)
        fixes.result = nil                                   // the refresh will fail

        async let first = subject.current(now: now)
        async let second = subject.current(now: now)
        await fixes.release()
        let (a, b) = await (first, second)

        #expect(a?.latitude == 42.45, "the caller that started it falls back")
        #expect(b?.latitude == 42.45, "and so does the one that joined")
        #expect(fixes.calls == 1, "they shared one fetch")
    }

    /// The same join, succeeding: both callers get the new fix, and only one
    /// request went out. Coalescing is the whole reason the join branch exists,
    /// so the fallback fix must not have cost it.
    @Test("two callers at once share one fix and both get it")
    func joinerGetsTheFreshFix() async {
        let fixes = GatedFixes()
        let subject = gatedCache(fixes)
        fixes.result = (latitude: 43, longitude: -77)

        async let first = subject.current(now: t0)
        async let second = subject.current(now: t0)
        await fixes.release()
        let (a, b) = await (first, second)

        #expect(a?.latitude == 43)
        #expect(b?.latitude == 43)
        #expect(fixes.calls == 1)
    }

    /// The fallback is the *cache*, not an invention: with nothing ever resolved
    /// there is nothing to fall back to and both callers correctly get nothing.
    @Test("a joined failure with no cache at all still reports nothing")
    func joinerWithNoCacheGetsNil() async {
        let fixes = GatedFixes()
        let subject = gatedCache(fixes)
        fixes.result = nil

        async let first = subject.current(now: t0)
        async let second = subject.current(now: t0)
        await fixes.release()
        let (a, b) = await (first, second)

        #expect(a == nil)
        #expect(b == nil)
        #expect(fixes.calls == 1)
    }
}
