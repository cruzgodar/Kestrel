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

    private func cache(_ fixes: Fixes) -> LocationCache {
        LocationCache(fetch: { await fixes.fetch() })
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

    @Test("an explicit update restarts the freshness window")
    func updateStampsTheClock() {
        let subject = cache(Fixes(nil))
        subject.update(latitude: 42, longitude: -76, at: t0)
        #expect(subject.isFresh(at: later(LocationCache.freshness - 1)))
        #expect(!subject.isFresh(at: later(LocationCache.freshness)))
    }
}
