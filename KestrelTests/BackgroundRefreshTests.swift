import Foundation
import Testing
@testable import Kestrel

/// The background photo-refresh coordinator's one testable piece: the network
/// classification the high-power pass is gated on.
///
/// It matters more than it looks. `isOnUnmeteredNetwork` is the first thing the
/// image-update task awaits, and it is built on a `withCheckedContinuation`,
/// which cannot be cancelled — so a monitor that never reported would park the
/// task forever. The background window would then expire with `setTaskCompleted`
/// uncalled, which iOS scores as a failure and throttles the task's future
/// scheduling against.
@Suite("Background refresh network check")
struct BackgroundRefreshTests {

    /// Whatever the simulator's path looks like, this must come back. The bound
    /// is generous — well past the internal timeout — because the assertion is
    /// "it resolves at all", not "it resolves quickly".
    @Test("the network check always resolves", .timeLimit(.minutes(1)))
    func networkCheckResolves() async {
        let started = Date()
        _ = await BackgroundRefreshCoordinator.isOnUnmeteredNetwork()
        #expect(Date().timeIntervalSince(started) < 20)
    }

    /// Called repeatedly — each background window runs it once — so it must not
    /// leave a monitor or a continuation behind that trips the next call up.
    @Test("repeated checks are independent", .timeLimit(.minutes(1)))
    func repeatedChecksResolve() async {
        for _ in 0..<3 {
            _ = await BackgroundRefreshCoordinator.isOnUnmeteredNetwork()
        }
    }
}

/// The hourly floor on how often the cache-revalidation pass reaches the network.
///
/// There are two passes and they are not interchangeable. The metered foreground
/// pass can only ever *defer* a changed slug; the Wi-Fi-and-power background pass
/// is the one that re-pulls it. Sharing one floor let the pass that can't fix
/// anything spend the budget of the pass that can — a user who opens the app
/// often would find their background sweep returning at the first guard most
/// times it ran.
///
/// The floor is about not hammering the network from one repeated context, so it
/// is scoped to the context. This is thin on purpose: the whole content of the
/// fix is that these are two strings and not one, and that is exactly what a
/// future edit could undo without noticing.
@Suite("Photo revalidation retry floor")
struct RevalidationRetryFloorTests {

    @Test("the metered and high-power passes keep separate budgets")
    func passesDoNotShareABudget() {
        #expect(
            RemoteSpeciesImageStore.lastRevalidationKey(includeChanged: false)
            != RemoteSpeciesImageStore.lastRevalidationKey(includeChanged: true)
        )
    }

    /// The foreground pass keeps the key it has always used, so an install
    /// upgrading into this change doesn't forget when it last checked and
    /// immediately hit the network again.
    @Test("the foreground pass keeps its existing key")
    func foregroundKeyIsUnchanged() {
        #expect(
            RemoteSpeciesImageStore.lastRevalidationKey(includeChanged: false)
            == "photoCacheLastRevalidation"
        )
    }

    /// Neither may collide with the discovery check's own throttle, which is a
    /// separate question ("is a manifest fetch due?") on a separate schedule.
    @Test("neither key collides with the manifest-check throttle")
    func keysAreDistinctFromTheManifestThrottle() {
        let keys = [
            RemoteSpeciesImageStore.lastRevalidationKey(includeChanged: false),
            RemoteSpeciesImageStore.lastRevalidationKey(includeChanged: true),
        ]
        #expect(!keys.contains("photoManifestLastCheck"))
    }
}
