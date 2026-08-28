import Foundation
import Testing
@testable import Kestrel

/// The per-species clocks that keep a still-singing bird from strobing its row,
/// buzzing every window, and re-notifying every three seconds.
///
/// These were three loose dictionaries on `RecordingManager`, cleared by three
/// parallel lines in each of the two session-start paths — and the notification
/// clock was missing from all of them, so a species heard shortly before a stop
/// had its first banner of the *next* session swallowed. Nothing failed loudly,
/// which is why it survived; gathering them into one value with one `reset()` is
/// what makes that class of miss impossible, and these pin the behavior that
/// reset has to preserve.
///
/// `shouldFlash` and `shouldBuzz` are check-and-claim, so their results are
/// bound to a local before being asserted on — `#expect` can't capture a
/// mutating call, and a claim made twice wouldn't be the same question anyway.
@Suite("Detection cooldowns")
struct DetectionCooldownsTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func later(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: the clocks themselves

    @Test("a species never heard before is due on every clock")
    func firstDetectionIsAlwaysDue() {
        var cooldowns = DetectionCooldowns()
        let flashed = cooldowns.shouldFlash("X y", at: t0)
        let buzzed = cooldowns.shouldBuzz("X y", at: t0)
        #expect(flashed)
        #expect(buzzed)
        #expect(cooldowns.shouldNotify("X y", at: t0))
    }

    @Test("a repeat inside the window is refused, and past it is allowed")
    func flashRespectsItsWindow() {
        var cooldowns = DetectionCooldowns()
        let first = cooldowns.shouldFlash("X y", at: t0)
        let tooSoon = cooldowns.shouldFlash("X y", at: later(DetectionCooldowns.flash - 0.1))
        let due = cooldowns.shouldFlash("X y", at: later(DetectionCooldowns.flash))
        #expect(first)
        #expect(!tooSoon)
        #expect(due)
    }

    @Test("the haptic clock runs on its own, shorter window than the banner")
    func hapticIsShorterThanNotify() {
        #expect(DetectionCooldowns.haptic < DetectionCooldowns.notify)

        var cooldowns = DetectionCooldowns()
        let first = cooldowns.shouldBuzz("X y", at: t0)
        cooldowns.markHeard("X y", at: t0)
        #expect(first)

        // Past the haptic window but well inside the banner's: a still-singing
        // lifer keeps tapping while its notification stays muted.
        let midway = later(DetectionCooldowns.haptic)
        let buzzedAgain = cooldowns.shouldBuzz("X y", at: midway)
        #expect(buzzedAgain)
        #expect(!cooldowns.shouldNotify("X y", at: midway))
    }

    /// The banner clock is stamped by `markHeard` on *every* detection, not by
    /// the check — so a bird that never stops singing keeps pushing its next
    /// banner out instead of earning one every `notify` seconds.
    @Test("a continuously-heard bird never comes back due for a banner")
    func continuousDetectionKeepsTheBannerDeferred() {
        var cooldowns = DetectionCooldowns()
        #expect(cooldowns.shouldNotify("X y", at: t0))
        // Heard every few seconds for well past the notify window.
        for step in stride(from: 0.0, through: DetectionCooldowns.notify * 2, by: 3) {
            cooldowns.markHeard("X y", at: later(step))
        }
        #expect(!cooldowns.shouldNotify("X y", at: later(DetectionCooldowns.notify * 2)))
    }

    /// …but one that goes quiet and comes back does.
    @Test("a bird that falls silent and returns is due again")
    func silenceRearmsTheBanner() {
        var cooldowns = DetectionCooldowns()
        cooldowns.markHeard("X y", at: t0)
        #expect(!cooldowns.shouldNotify("X y", at: later(DetectionCooldowns.notify - 1)))
        #expect(cooldowns.shouldNotify("X y", at: later(DetectionCooldowns.notify)))
    }

    @Test("clocks are per species")
    func speciesDoNotShareClocks() {
        var cooldowns = DetectionCooldowns()
        let one = cooldowns.shouldBuzz("X y", at: t0)
        let other = cooldowns.shouldBuzz("A b", at: t0)
        let oneAgain = cooldowns.shouldBuzz("X y", at: t0)
        #expect(one)
        #expect(other, "a different bird has its own clock")
        #expect(!oneAgain)
    }

    /// `shouldNotify` is a pure read — the stamp is `markHeard`'s job. Asking
    /// twice must not consume the answer, because `merge` asks before deciding
    /// whether the species is even worth alerting about.
    @Test("asking whether to notify doesn't stamp the clock")
    func shouldNotifyDoesNotStamp() {
        let cooldowns = DetectionCooldowns()
        #expect(cooldowns.shouldNotify("X y", at: t0))
        #expect(cooldowns.shouldNotify("X y", at: t0))
    }

    // MARK: reset

    /// The bug this type exists to make impossible: a new session judged against
    /// the previous one's timings. All three clocks have to go, not two.
    @Test("reset clears every clock, banner included")
    func resetClearsAllThree() {
        var cooldowns = DetectionCooldowns()
        _ = cooldowns.shouldFlash("X y", at: t0)
        _ = cooldowns.shouldBuzz("X y", at: t0)
        cooldowns.markHeard("X y", at: t0)

        // A second later — inside every window — nothing would be due.
        let soon = later(1)
        #expect(!cooldowns.shouldNotify("X y", at: soon))

        cooldowns.reset()

        // A fresh session starts owing nothing to the last one.
        let flashed = cooldowns.shouldFlash("X y", at: soon)
        let buzzed = cooldowns.shouldBuzz("X y", at: soon)
        #expect(flashed)
        #expect(buzzed)
        #expect(cooldowns.shouldNotify("X y", at: soon),
                "the notification clock is the one that used to survive a restart")
    }

    /// Stated as its own case because it is the exact user-visible symptom:
    /// stop while a bird is singing, start again a few seconds later, and its
    /// first banner of the new session went missing.
    @Test("restarting a session re-arms a bird heard moments before the stop")
    func restartRearmsARecentlyHeardBird() {
        var cooldowns = DetectionCooldowns()
        cooldowns.markHeard("X y", at: t0)          // heard just before the stop
        cooldowns.reset()                            // …and the session restarts
        #expect(cooldowns.shouldNotify("X y", at: later(2)))
    }
}
