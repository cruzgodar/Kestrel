import Foundation
import Testing
@testable import Kestrel

/// The wake-up a waiting photo load sleeps on.
///
/// Each wait arms a timer as its backstop. The timer used to sleep out its
/// whole delay — up to five minutes for a species with no photo published —
/// even after its waiter had been woken some other way, and every foreground
/// or network change woke every waiter into another wait with another timer,
/// so they piled up. A timer now stops the moment its waiter is woken.
@Suite("Photo retry signal")
@MainActor
struct PhotoRetrySignalTests {

    /// Long enough that a timer still asleep at the end of a test can only be
    /// one that was never stopped.
    private let longDelay: Duration = .seconds(300)

    @Test("firing wakes every waiter and stops every timer")
    func fireStopsTimers() async {
        let signal = PhotoRetrySignal(watchesSystem: false)
        let waits = (0..<3).map { _ in Task { await signal.wait(upTo: longDelay) } }
        await until { signal.waitingCount == 3 }
        #expect(signal.sleepingTimers == 3)

        signal.fire()
        for wait in waits { await wait.value }

        await until { signal.sleepingTimers == 0 }
        #expect(signal.sleepingTimers == 0)
        #expect(signal.waitingCount == 0)
    }

    @Test("cancelling a waiter stops its timer")
    func cancelStopsTimer() async {
        let signal = PhotoRetrySignal(watchesSystem: false)
        let wait = Task { await signal.wait(upTo: longDelay) }
        await until { signal.waitingCount == 1 }

        wait.cancel()
        await wait.value

        await until { signal.sleepingTimers == 0 }
        #expect(signal.sleepingTimers == 0)
        #expect(signal.waitingCount == 0)
    }

    @Test("a waiter nobody wakes is woken by its own timer")
    func timerWakes() async {
        let signal = PhotoRetrySignal(watchesSystem: false)
        await signal.wait(upTo: .milliseconds(20))
        await until { signal.sleepingTimers == 0 }
        #expect(signal.sleepingTimers == 0)
        #expect(signal.waitingCount == 0)
    }

    /// Yields until `condition` holds, for at most two seconds — far longer
    /// than anything here takes, and far shorter than `longDelay`.
    private func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
