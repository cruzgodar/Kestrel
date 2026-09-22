import SwiftUI

/// The width cap shared by the app's two full-page reading surfaces — the
/// welcome screen and the Settings tab — and the rule for where the capped
/// column sits.
///
/// A phone is narrow enough that a paragraph run edge to edge still reads as a
/// paragraph, and every layout here was tuned against that. A foldable's inner
/// display is not: open in landscape it is well over twice a phone's width, and
/// a line drawn across all of it is long enough to lose your place on the way
/// back to the left margin. So the column simply stops growing.
///
/// Deliberately a cap rather than a pose branch (see `duo.md`): nothing here
/// asks which device this is, which display it is on, or whether the phone is
/// open. Anything narrower than the cap — every iPhone, and a foldable's outer
/// display — never reaches it and is laid out exactly as it was before.
enum ReadableWidth {
    /// Roughly the measure of a page of prose.
    static let cap: CGFloat = 450

    /// The **scroll-content margin** that puts a `cap`-wide column in the
    /// middle of the display, or `nil` where the column already fits and the
    /// scroll view should keep its own margins.
    ///
    /// One value for both sides, because a scroll view's content margins are
    /// measured from its *frame*, and the frame spans the whole display —
    /// bars and all. Equal margins therefore centre the column on the glass,
    /// which is the point: a foldable's safe area is lopsided, a vertical bar
    /// takes one side and nothing takes the other, and a column centred in
    /// what's left sits visibly off-centre.
    ///
    /// Floored at the widest safe inset so the column never lands under a bar;
    /// where that floor bites, the column comes out narrower than the cap
    /// rather than moving.
    ///
    /// - Parameters:
    ///   - available: The width the content has, net of the safe area.
    ///   - leading: The leading safe-area inset that was already taken off it.
    ///   - trailing: Likewise for the trailing side.
    nonisolated static func scrollMargin(
        available: CGFloat,
        leading: CGFloat,
        trailing: CGFloat
    ) -> CGFloat? {
        guard available > cap else { return nil }
        let display = available + leading + trailing
        return max((display - cap) / 2, max(leading, trailing))
    }

    /// The leading/trailing **padding** that centres a `cap`-wide column on the
    /// display, for a view whose frame is the safe area rather than the whole
    /// display — a plain stack, where padding is what narrows it.
    ///
    /// Asymmetric on purpose, and for the same reason the scroll version is
    /// symmetric: these are measured from the safe area's edges, so hitting the
    /// middle of the display means leaning away from whichever side the bar is
    /// on. The two always add up to the same surplus, so the column comes out
    /// exactly `cap` wide however the split lands, and neither is ever negative.
    ///
    /// - Parameters:
    ///   - available: The width the content has, net of the safe area.
    ///   - leading: The leading safe-area inset that was already taken off it.
    ///   - trailing: Likewise for the trailing side.
    nonisolated static func insets(
        available: CGFloat,
        leading: CGFloat,
        trailing: CGFloat
    ) -> (leading: CGFloat, trailing: CGFloat) {
        let surplus = max(0, available - cap)
        // Half the difference between the two safe insets: how far the middle
        // of the usable width sits from the middle of the display.
        let offCentre = (trailing - leading) / 2
        let leading = min(max(surplus / 2 + offCentre, 0), surplus)
        return (leading, surplus - leading)
    }
}

extension View {
    /// Caps this view's width at `ReadableWidth.cap`, centered on the display,
    /// by insetting it — so a background applied outside this still fills the
    /// display, which is what the welcome screen (an opaque cover over the
    /// running app) needs.
    func readableWidth() -> some View {
        modifier(ReadableColumn())
    }

    /// The scroll-view form of `readableWidth()`, plus a floor on how close the
    /// content can start to the top of the display.
    ///
    /// A scroll view can't just be inset the way a stack can: its frame is what
    /// draws the background and what the scroll indicators ride, and squeezing
    /// that down to the column would leave a stripe of scrolling content in the
    /// middle of a page of nothing. Its content margins are set instead, which
    /// leaves the frame — and so the background — spanning the display.
    ///
    /// Content margins rather than safe-area padding, which was the first try:
    /// padding the safe area moves the content but leaves a grouped list still
    /// accounting for the vertical bar, and it spends that inset *as* its
    /// trailing gutter while adding its usual 20pt on the leading side only —
    /// so the cards came out 10pt off-centre inside a column that was itself
    /// centred. Content margins are measured from the frame and replace the
    /// list's own, so both sides are finally the same number.
    ///
    /// - Parameter minimumTopInset: The least distance from the top of the
    ///   scroll view's own container that content may begin at. The safe area
    ///   already supplies this on a phone, where a status bar and a navigation
    ///   bar sit above the content; where the system runs its bars down one side
    ///   instead there is nothing at the top to supply it, and content that
    ///   honors the safe area alone starts hard against the edge of the glass.
    func readableWidth(minimumTopInset: CGFloat) -> some View {
        modifier(ReadableScrollContent(minimumTopInset: minimumTopInset))
    }
}

/// What both modifiers measure. One value so a single `onGeometryChange`
/// covers all of it.
///
/// `nonisolated` because the project is main-actor-by-default, and
/// `onGeometryChange` wants a `Sendable` value — a main-actor-isolated
/// `Equatable` conformance does not satisfy that.
private nonisolated struct ReadableMetrics: Equatable {
    /// Width available to content, which `GeometryProxy.size` already reports
    /// net of the safe area — on a foldable, net of the side a vertical tab bar
    /// or navigation bar has taken.
    let available: CGFloat
    let leading: CGFloat
    let trailing: CGFloat
    let top: CGFloat

    init(_ proxy: GeometryProxy) {
        available = proxy.size.width
        leading = proxy.safeAreaInsets.leading
        trailing = proxy.safeAreaInsets.trailing
        top = proxy.safeAreaInsets.top
    }

    var columnInsets: (leading: CGFloat, trailing: CGFloat) {
        ReadableWidth.insets(available: available, leading: leading, trailing: trailing)
    }
}

/// Backs `readableWidth()`.
private struct ReadableColumn: ViewModifier {
    @State private var insets = EdgeInsets()

    func body(content: Content) -> some View {
        content
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            // Outside the padding, so it measures the space the view was given
            // rather than the space left after insetting it — otherwise each
            // pass would feed the next.
            .onGeometryChange(for: ReadableMetrics.self) { ReadableMetrics($0) } action: { metrics in
                let columns = metrics.columnInsets
                insets = EdgeInsets(
                    top: 0, leading: columns.leading, bottom: 0, trailing: columns.trailing
                )
            }
    }
}

/// Backs `readableWidth(minimumTopInset:)`.
private struct ReadableScrollContent: ViewModifier {
    let minimumTopInset: CGFloat

    /// `nil` where the column fits as it is, which leaves the scroll view's own
    /// margins alone — the whole reason this is optional. An earlier version
    /// passed a plain `0` there and flattened every inset-grouped card on every
    /// iPhone into a full-bleed strip with no gutter and no rounded corners:
    /// content margins *replace* a scroll view's own rather than adding to them.
    @State private var margin: CGFloat?
    /// Extra safe area above the content, when the top edge has none of its own.
    @State private var top: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, margin, for: .scrollContent)
            // The top stays a safe-area pad rather than a content margin: the
            // caller may have zeroed its top content margin deliberately (see
            // `MoreView`), and this has to add to that rather than undo it.
            .safeAreaPadding(.top, top)
            // Outside both, so it measures the space the view was given rather
            // than the space left after insetting it — otherwise each pass
            // would feed the next.
            .onGeometryChange(for: ReadableMetrics.self) { ReadableMetrics($0) } action: { metrics in
                margin = ReadableWidth.scrollMargin(
                    available: metrics.available,
                    leading: metrics.leading,
                    trailing: metrics.trailing
                )
                // An inset *on top of* the safe area, so this is the shortfall
                // rather than the target: where the safe area already clears
                // the minimum, it adds nothing.
                top = max(0, minimumTopInset - metrics.top)
            }
    }
}
