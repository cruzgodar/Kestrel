import SwiftUI

/// How much room the app has been given, what shape it is, and every layout
/// decision that follows from those two facts.
///
/// **Why this exists.** The layouts here used to ask which *display* they were
/// on — the fold is present on a foldable's inner display and nowhere else, so
/// `reservedRegions(kind: .division)` answered it exactly. It answered the
/// wrong question. A tab sharing the inner display with another app in a split
/// is still "on the inner display" and has a phone's worth of room; it was
/// being handed a two-up layout that did not fit. And the answer was
/// unavailable to anything that wasn't a foldable, so every rule had to be
/// written twice.
///
/// So nothing asks any more. What is left is the thing that was actually being
/// approximated: how wide the app is, and whether it is wider than it is tall.
/// A display answering that description gets the layout whether it is a fold,
/// a split, a tablet, or something that doesn't exist yet — which is the rule
/// `duo.md` asks for.
nonisolated struct DisplayLayout: Equatable {
    /// The whole of what the app has, safe area included.
    let size: CGSize
    /// What the system's bars took out of it.
    let safeArea: EdgeInsets
    /// The display's own corner radius, or `nil` where it could not be read.
    let cornerRadius: CGFloat?

    /// The width at which the app stops showing one thing at a time and starts
    /// showing two.
    ///
    /// Above it there is room for a picture and a list side by side, a grid of
    /// photographs instead of a column of rows, and four birds across a card
    /// instead of three. Below it there is room for one of those things.
    ///
    /// Set between the widest thing that must stay single-column — a
    /// foldable's outer display at 466pt, and either half of its inner display
    /// in a split, the wider of which is around 475 — and the narrowest that
    /// must go two-up, the inner display held portrait at 669.
    static let expandedWidth: CGFloat = 600

    /// The height it also takes, which is what keeps an ordinary phone turned
    /// landscape out of it: an iPhone on its side is wider than the breakpoint
    /// and about 400pt tall, and half of that is not a pane, it is a letterbox.
    /// A foldable's inner display is 669pt on its short side.
    static let expandedHeight: CGFloat = 500

    /// Whether there is room to show two things side by side.
    var isExpanded: Bool {
        size.width >= Self.expandedWidth && size.height >= Self.expandedHeight
    }

    /// Whether width is the plentiful axis.
    var isLandscape: Bool { size.width > size.height }

    init(_ proxy: GeometryProxy) {
        let insets = proxy.safeAreaInsets
        // `proxy.size` is already net of the safe area; the display is that
        // plus whatever the bars took.
        size = CGSize(
            width: proxy.size.width + insets.leading + insets.trailing,
            height: proxy.size.height + insets.top + insets.bottom
        )
        safeArea = insets
        cornerRadius = Self.readCornerRadius(proxy, size: size)
    }

    /// The glass's own curve, asked for the full-bleed rect rather than the
    /// safe one: the proxy sits inside the safe area, so the display's rect is
    /// its own grown back by its insets.
    private static func readCornerRadius(_ proxy: GeometryProxy, size: CGSize) -> CGFloat? {
        guard #available(iOS 27.0, *) else { return nil }
        let rect = CGRect(
            x: -proxy.safeAreaInsets.leading,
            y: -proxy.safeAreaInsets.top,
            width: size.width,
            height: size.height
        )
        guard let radius = proxy.concentricCornerRadii(in: rect)?.topLeading,
              radius > 0 else { return nil }
        return radius
    }

    // MARK: - What each screen does with it

    /// The Identify tab's species pane: how much of the tab it takes, and the
    /// display's own corner radius so its card can be cut concentric. `nil`
    /// where there is no room for one.
    ///
    /// Width is the axis it needs. A pane and a list side by side each want a
    /// column, and only a display with width going spare has two to give; a
    /// tall one divided the other way gave the pane a band the wrong shape for
    /// a photograph and took the height from the list to pay for it. Where the
    /// height is what is going spare, the tab spends it on bigger rows
    /// instead — see `identifyRowsAreLarge`.
    var speciesPane: SpeciesPane? {
        guard isExpanded, isLandscape else { return nil }
        let inset = size.width / 2 - safeArea.leading
        guard inset > 0 else { return nil }
        return SpeciesPane(
            contentInset: inset,
            safeArea: safeArea,
            displayCornerRadius: cornerRadius
        )
    }

    /// Whether the Identify list draws its rows at the larger of its two
    /// sizes.
    ///
    /// Where the tab has a display's worth of room and is not giving half of
    /// it to the species pane — which is to say, a large display held
    /// portrait. The list has the whole width and more height than it has
    /// birds to put in it, so it spends both on bigger photographs rather than
    /// on a longer column of the same small ones.
    var identifyRowsAreLarge: Bool { isExpanded && speciesPane == nil }

    /// Whether a new lifer's row carries a full-width photograph under it.
    ///
    /// Only where nothing else on screen is already showing that bird big. On
    /// a phone the hero is the one place its photograph appears, and worth
    /// three rows' height for it. On a large display it is either the same
    /// picture twice — the species pane is showing it beside the list — or a
    /// third one, next to rows whose own thumbnails are already twice the size
    /// (see `identifyRowsAreLarge`). Both cases give the row back the shape
    /// every other row has: name, the purple add button, thumbnail.
    var identifyShowsHeroRows: Bool { !isExpanded }

    /// Whether the Life List draws itself as a grid of photographs rather than
    /// a column of rows.
    var lifeListIsGrid: Bool { isExpanded }

    /// Birds per row in a map cluster card, or `nil` to fit as many as the
    /// width takes — which comes out at three on a phone and on either half of
    /// a split, where four would shrink them past reading.
    var mapCardColumns: Int? { isExpanded ? 4 : nil }

    /// Whether the full-screen viewer grows the photograph to span the display
    /// rather than resting it inside the horizontal safe area.
    var photoSpansDisplay: Bool { isExpanded }

    /// Whether the viewer's name and details tuck into opposite display
    /// corners. Only where width is going spare *and* height is the scarcer
    /// axis: a bottom-centred panel on a wide display leaves a lot of empty
    /// picture between it and the controls up the side.
    var viewerChromeHugsCorners: Bool { isExpanded && isLandscape }
}

/// The half of the Identify tab the list steps out of, so the species pane can
/// stand in it.
nonisolated struct SpeciesPane: Equatable {
    /// How far the tab's content is pushed in from its leading edge, measured
    /// **from the content's own edge** — which the safe area may already have
    /// moved.
    ///
    /// Insetting the content is deliberate, rather than giving it a half-size
    /// frame aligned the other way: SwiftUI hands a child the container's
    /// safe-area insets whether or not the child reaches the unsafe edge, so a
    /// half-size frame pushed to the far side still believes a bar sits beyond
    /// it and lands a bar's width short. Insetting the near edge leaves the far
    /// edge exactly where the container's is, and every inset meaning what it
    /// meant.
    let contentInset: CGFloat

    /// What the system's bars took out of the display, which the pane needs
    /// because it is laid out full-bleed and so is told nothing about them by
    /// its own proxy.
    let safeArea: EdgeInsets

    /// The display's own corner radius, so the pane's card can be cut
    /// concentric with it. `nil` where it could not be read.
    let displayCornerRadius: CGFloat?
}

extension View {
    /// Reports how much room this view has, now and whenever that changes.
    func onDisplayLayoutChange(_ action: @escaping (DisplayLayout) -> Void) -> some View {
        onGeometryChange(for: DisplayLayout.self) { DisplayLayout($0) } action: { action($0) }
    }
}
