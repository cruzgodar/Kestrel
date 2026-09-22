import Foundation
import Testing
@testable import Kestrel

/// Where a capped column lands (`ReadableWidth.insets`).
///
/// The rule only does anything on a display wider than the cap, and the only
/// such display is a foldable's inner one — which is also the only display with
/// a lopsided safe area, since a vertical bar takes one side and nothing takes
/// the other. So the interesting case is exactly the one that cannot be reached
/// from the command line, and these stand in for looking at it.
@Suite("Readable width")
struct ReadableWidthTests {

    /// Where the column's own edges land on the glass, given a display and the
    /// safe area taken out of it.
    private func column(
        display: CGFloat, leading: CGFloat, trailing: CGFloat
    ) -> (left: CGFloat, right: CGFloat) {
        let available = display - leading - trailing
        let insets = ReadableWidth.insets(
            available: available, leading: leading, trailing: trailing
        )
        return (leading + insets.leading, display - trailing - insets.trailing)
    }

    /// The case the rule exists for: the inner display in landscape, where a
    /// vertical tab bar holds 84pt of the trailing side.
    @Test("a lopsided safe area still centers the column on the display")
    func lopsidedSafeAreaCentersOnDisplay() {
        let c = column(display: 951, leading: 0, trailing: 84)
        #expect(abs((c.left + c.right) / 2 - 951 / 2) < 0.001)
        #expect(abs((c.right - c.left) - ReadableWidth.cap) < 0.001)
    }

    @Test("an even safe area centers it too")
    func evenSafeAreaCenters() {
        let c = column(display: 900, leading: 20, trailing: 20)
        #expect(abs((c.left + c.right) / 2 - 450) < 0.001)
        #expect(abs((c.right - c.left) - ReadableWidth.cap) < 0.001)
    }

    /// Every iPhone, and the foldable's outer display: narrower than the cap, so
    /// nothing is inset and the layout is exactly what it was.
    @Test("a display narrower than the cap is left alone")
    func narrowDisplayIsUntouched() {
        let insets = ReadableWidth.insets(available: 402, leading: 0, trailing: 0)
        #expect(insets.leading == 0)
        #expect(insets.trailing == 0)
    }

    /// Centering never wins over the safe area: with a bar wide enough that
    /// perfect centering would need the column to start inside it, the column
    /// stops at the edge of the safe area instead — and is still exactly the
    /// cap wide, because the two insets always split the same surplus.
    @Test("centering gives way to the safe area, not the other way round")
    func safeAreaWinsOverCentering() {
        let display: CGFloat = 660, trailing: CGFloat = 200
        let insets = ReadableWidth.insets(
            available: display - trailing, leading: 0, trailing: trailing
        )
        #expect(insets.leading >= 0)
        #expect(insets.trailing >= 0)
        let c = column(display: display, leading: 0, trailing: trailing)
        #expect(abs((c.right - c.left) - ReadableWidth.cap) < 0.001)
        #expect(c.right <= display - trailing + 0.001)
    }

    /// The bar can be on either side; the column leans away from whichever it is.
    @Test("the column leans away from the bar")
    func columnLeansAwayFromTheBar() {
        let trailingBar = ReadableWidth.insets(available: 867, leading: 0, trailing: 84)
        let leadingBar = ReadableWidth.insets(available: 867, leading: 84, trailing: 0)
        #expect(trailingBar.leading > trailingBar.trailing)
        #expect(leadingBar.trailing > leadingBar.leading)
        #expect(abs(trailingBar.leading - leadingBar.trailing) < 0.001)
    }
}
