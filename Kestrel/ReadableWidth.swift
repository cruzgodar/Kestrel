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

    /// Splits the width a capped column gives up into a leading and a trailing
    /// inset, chosen so the column ends up centered **on the display** rather
    /// than inside the safe area.
    ///
    /// The two differ whenever the safe area is lopsided, which on a foldable
    /// it always is: a vertical tab bar takes one side and nothing takes the
    /// other, so a column centered in what is left sits visibly left of center
    /// on the glass.
    ///
    /// The two insets always add up to the whole surplus, so the column comes
    /// out exactly `cap` wide however the split lands, and neither is ever
    /// negative: content stays out of the safe area even in the extreme case
    /// where honoring it costs perfect centering.
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
        let offCenter = (trailing - leading) / 2
        let leading = min(max(surplus / 2 + offCenter, 0), surplus)
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
    /// middle of a page of nothing. Its *safe area* is padded instead, which
    /// leaves the frame alone and lets a list keep insetting its own rows from
    /// the safe area exactly as it did.
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

    @State private var insets = EdgeInsets()

    func body(content: Content) -> some View {
        content
            // `safeAreaPadding`, not `contentMargins`: content margins *replace*
            // a scroll view's own, so a zero one (every iPhone, where the column
            // already fits) flattened the inset-grouped cards to full-bleed
            // strips with no gutter and no rounded corners. Padding the safe
            // area instead adds nothing at all when every value is zero.
            .safeAreaPadding(insets)
            .onGeometryChange(for: ReadableMetrics.self) { ReadableMetrics($0) } action: { metrics in
                let columns = metrics.columnInsets
                insets = EdgeInsets(
                    // An inset *on top of* the safe area, so this is the
                    // shortfall rather than the target: where the safe area
                    // already clears the minimum, it adds nothing.
                    top: max(0, minimumTopInset - metrics.top),
                    leading: columns.leading,
                    bottom: 0,
                    trailing: columns.trailing
                )
            }
    }
}
