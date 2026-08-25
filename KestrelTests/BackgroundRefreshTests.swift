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
