import SwiftUI
import UIKit

/// Gives an iPad the system chrome a foldable's inner display has, so the two
/// behave the same.
///
/// **Why this exists.** Everything the app lays out itself already asks only
/// how much room there is — see `DisplayLayout` — so an iPad gets the inner
/// display's layouts, portrait and landscape, without being told it is an
/// iPad. What `DisplayLayout` cannot reach is the chrome UIKit draws around
/// them, and UIKit decides that from the idiom *and* the horizontal size class
/// together. A foldable is a phone that reports regular width, and keeps a
/// phone's chrome: the tab bar along the bottom, and sheets that rise from the
/// bottom edge and stop at their detents. An iPad reporting the same regular
/// width swaps both for its own — a text-only tab strip across the top, and
/// sheets that float in the middle of the screen at one fixed size, detents
/// ignored — which is not the app the inner display shows, and breaks the map
/// cards outright, since they sit at a detent with the map live behind them.
///
/// Reporting compact width to the window is what turns the phone's chrome back
/// on. It is safe to do wholesale because nothing in the app keys a layout off
/// a size class, which is exactly why `DisplayLayout` measures instead. It has
/// to be the window: the same override on the window scene reads back compact
/// but the tab bar stays across the top.
///
/// What it cannot give an iPad is the vertical bar: a foldable held landscape
/// moves its bars to one side, and the SDK only does that on hardware built
/// for it (`verticalBarEdge` is documented as unspecified everywhere else), so
/// an iPad held landscape keeps the tab bar along the bottom. The layouts inside it are the same either way.
///
/// This is the one place the idiom is asked about, and it is asked about
/// chrome, never layout: the difference being undone is the idiom's.
struct PhoneChrome: UIViewRepresentable {
    func makeUIView(context: Context) -> WindowTraitView { WindowTraitView() }
    func updateUIView(_ uiView: WindowTraitView, context: Context) {}

    final class WindowTraitView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard traitCollection.userInterfaceIdiom == .pad, let window else { return }
            window.traitOverrides.horizontalSizeClass = .compact
        }
    }
}

extension View {
    /// See `PhoneChrome`.
    func phoneChrome() -> some View {
        background { PhoneChrome().allowsHitTesting(false) }
    }
}
