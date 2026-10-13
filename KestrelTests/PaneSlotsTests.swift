import Foundation
import Testing
@testable import Kestrel

/// The Identify pane's two mounted pagers, and when the one underneath is let
/// go.
///
/// A dissolve used to retire whatever was underneath when it finished. With a
/// second bird landing inside the first dissolve, what was underneath by then
/// was the first dissolve's *incoming* picture, still fading in — and taking it
/// away blinked the pane. Each dissolve now lets go of the slot it faded out
/// of, and only that one.
@Suite("Species pane slots")
@MainActor
struct PaneSlotsTests {

    private func slot(_ id: Int) -> PaneSlot {
        PaneSlot(id: id, names: ["Bird \(id)"], index: 0)
    }

    @Test("the first bird has nothing to dissolve out of")
    func firstBird() {
        var slots = PaneSlots()
        let leaving = slots.show(slot(0))
        #expect(leaving == nil)
        #expect(slots.current == slot(0))
        #expect(slots.outgoing == nil)
    }

    @Test("a dissolve finishes by letting go of the slot it left")
    func oneDissolve() {
        var slots = PaneSlots()
        _ = slots.show(slot(0))
        let leaving = slots.show(slot(1))
        #expect(leaving == slot(0))
        #expect(slots.outgoing == slot(0))
        let retired = slots.finish(slot(0))
        #expect(retired)
        #expect(slots.outgoing == nil)
        #expect(slots.current == slot(1))
    }

    @Test("an earlier dissolve finishing late leaves the later one's picture alone")
    func overlappingDissolves() throws {
        var slots = PaneSlots()
        _ = slots.show(slot(0))
        let first = slots.show(slot(1))      // 0 → 1 begins
        let second = slots.show(slot(2))     // 1 → 2 begins before it ends
        #expect(slots.outgoing == slot(1))

        // The 0 → 1 dissolve's completion: slot 1 is still fading out under 2.
        let retiredEarly = slots.finish(try #require(first))
        #expect(!retiredEarly)
        #expect(slots.outgoing == slot(1))

        let retired = slots.finish(try #require(second))
        #expect(retired)
        #expect(slots.outgoing == nil)
        #expect(slots.current == slot(2))
    }

    @Test("clearing fades out what was on show, and only that is let go")
    func clear() {
        var slots = PaneSlots()
        _ = slots.show(slot(0))
        let fading = slots.clear()
        #expect(fading == slot(0))
        #expect(slots.current == nil)
        #expect(slots.outgoing == slot(0))
        let clearedAgain = slots.clear()
        #expect(clearedAgain == nil, "nothing left to clear")

        // A bird lands while the clear is still fading: it shows at once, and
        // the clear's fade carries on underneath it.
        let landed = slots.show(slot(1))
        #expect(landed == nil)
        #expect(slots.outgoing == slot(0))
        let retired = slots.finish(slot(0))
        #expect(retired)
        #expect(slots.outgoing == nil)
    }

    @Test("a clear finishing after a dissolve has started leaves that dissolve alone")
    func clearOvertakenByDissolve() throws {
        var slots = PaneSlots()
        _ = slots.show(slot(0))
        let cleared = slots.clear()          // 0 fades out
        _ = slots.show(slot(1))              // 1 shows at once
        _ = slots.show(slot(2))              // 1 → 2 begins; 1 is underneath now
        let retired = slots.finish(try #require(cleared))
        #expect(!retired)
        #expect(slots.outgoing == slot(1))
    }
}
