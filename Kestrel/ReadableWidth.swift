import SwiftUI

/// The width cap shared by the app's two full-page reading surfaces — the
/// welcome screen and the Settings tab.
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
    /// Roughly the measure of a page of prose, and about a third wider than the
    /// widest phone, so the two open poses land on the same line length as each
    /// other rather than each on their own.
    static let cap: CGFloat = 450
}

extension View {
    /// Caps this view's width at `ReadableWidth.cap` and centers it in whatever
    /// space is left, without letting the cap shrink the *frame* — so a
    /// background applied outside this still fills the display, which is what
    /// the welcome screen (an opaque cover over the running app) needs.
    func readableWidth() -> some View {
        self
            .frame(maxWidth: ReadableWidth.cap)
            .frame(maxWidth: .infinity)
    }

    /// The scroll-view form of `readableWidth()`, plus a floor on how close the
    /// content can start to the top of the display.
    ///
    /// A scroll view can't just be narrowed the way `readableWidth()` narrows
    /// a stack: its frame is what draws the background and what the scroll
    /// indicators ride, and clipping that to the column would leave a stripe of
    /// scrolling content in the middle of a page of nothing. Its *safe area* is
    /// padded instead, which is also what keeps the column centered in the
    /// usable width rather than in the display — content should not sit
    /// visually centered underneath a side bar.
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

/// Backs `readableWidth(minimumTopInset:)`. Both insets are measured rather
/// than assumed, because both answers depend on geometry only the running app
/// knows.
private struct ReadableScrollContent: ViewModifier {
    let minimumTopInset: CGFloat

    /// What the insets are computed from. One value so a single
    /// `onGeometryChange` covers both.
    ///
    /// `nonisolated` because the project is main-actor-by-default, and
    /// `onGeometryChange` wants a `Sendable` value — a main-actor-isolated
    /// `Equatable` conformance does not satisfy that.
    private nonisolated struct Metrics: Equatable {
        /// Width available to content, which `GeometryProxy.size` already
        /// reports net of the safe area — on a foldable, net of the side a
        /// vertical tab bar or navigation bar has taken.
        let available: CGFloat
        let topInset: CGFloat
    }

    @State private var horizontal: CGFloat = 0
    @State private var top: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // `safeAreaPadding`, not `contentMargins`: content margins *replace*
            // a scroll view's own, so a zero one (every iPhone, where the column
            // already fits) flattened the inset-grouped cards to full-bleed
            // strips with no gutter and no rounded corners. Padding the safe
            // area instead leaves the list to inset its cards from it the way it
            // always did, and adds nothing at all when both values are zero.
            .safeAreaPadding(.horizontal, horizontal)
            .safeAreaPadding(.top, top)
            // Outside both, so it measures the space the view was given rather
            // than the space left after padding it — otherwise each pass would
            // feed the next.
            .onGeometryChange(for: Metrics.self) { proxy in
                Metrics(available: proxy.size.width, topInset: proxy.safeAreaInsets.top)
            } action: { metrics in
                horizontal = max(0, metrics.available - ReadableWidth.cap) / 2
                // An inset *on top of* the safe area, so this is the shortfall
                // rather than the target: where the safe area already clears the
                // minimum, it adds nothing.
                top = max(0, minimumTopInset - metrics.topInset)
            }
    }
}
