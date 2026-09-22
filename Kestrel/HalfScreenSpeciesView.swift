import SwiftUI

/// The Identify tab's left-hand pane on a foldable's inner display: the
/// full-screen bird viewer, in half a screen, standing open beside the list.
///
/// The same parts the viewer is made of — `PhotoPager` over `ZoomablePhotoPage`
/// for the photograph, `SpeciesNameCapsule` and `SpeciesInfoPanel` for the
/// chrome — minus the two controls that only make sense over a presentation:
/// Back, because there is nothing to go back to, and More, because the list
/// beside it already carries every one of those actions per row.
///
/// Two differences from the viewer, both because the list next to it is still
/// running. It is *live*: `names` is whatever has been heard, and the tab moves
/// `selection` to the newest bird as it arrives (see `ContentView`). And a
/// change of `selection` from outside **crossfades** rather than turning a
/// page, because nothing swiped and a page turn would look like something did.
/// A swipe inside the pane still pages, and reports where it landed through
/// `onPage` so the tab's idea of what is showing follows the user's.
///
/// The photograph can be zoomed in, and no further out than the pane —
/// `ZoomablePhotoPage` fits it to whatever box it is given and treats that as
/// the minimum zoom, so the picture can never shrink inside its own half.
struct HalfScreenSpeciesView: View {
    /// The birds the pane can page through, in the order the list shows them —
    /// most recently heard first.
    let names: [String]
    /// The bird on show. `nil` before anything has been heard, which draws the
    /// empty card. Changing it from outside crossfades the pane.
    let selection: String?
    /// Reports whether the photo is zoomed in. The tab uses it to decide
    /// whether a newly-heard bird may take the pane over (see `ContentView`):
    /// a zoomed-in photo is someone looking closely at something, and pulling
    /// it out from under them would be rude.
    var onZoomChange: (Bool) -> Void = { _ in }
    /// The bird a swipe landed on, so the tab's `selection` can follow it
    /// rather than yanking the pane back on the next render.
    var onPage: (String) -> Void = { _ in }
    /// The display's own corner radius, so the card's corners can be cut
    /// concentric with it. `nil` where it could not be read, which falls back
    /// to a plain rounded rectangle.
    var displayCornerRadius: CGFloat?

    /// Only for the name on the capsule and the sightings on the panel.
    /// Optional so previews without a store still render.
    @Environment(LifeListStore.self) private var lifeListStore: LifeListStore?

    /// The viewer's page gate, which holds a page's full-resolution download
    /// until motion stops.
    @State private var paging = ViewerPaging()
    /// The pager on show, and the one it is dissolving out of.
    ///
    /// Two of them, both mounted, because a crossfade needs two pictures on
    /// screen at once. Leaving it to `.id` + `.transition(.opacity)` did not:
    /// the incoming page faded in correctly but the outgoing one was torn down
    /// on the frame the identity changed, so the pane blinked black and then
    /// faded up out of it. Holding the old pager still underneath and fading
    /// the new one in over it is the dissolve that was wanted, and it does not
    /// depend on a hosted `UIPageViewController` honouring a removal
    /// transition.
    @State private var current: PaneSlot?
    @State private var outgoing: PaneSlot?
    /// The incoming pager's opacity, animated from 0 to 1 across a crossfade.
    @State private var incomingOpacity: Double = 1
    /// Where the front pager currently sits within its own snapshot.
    @State private var pagedIndex = 0
    /// Distinct per mount, so each slot is its own view.
    @State private var nextSlotID = 0
    /// A request to turn the page programmatically, fired when a zoomed
    /// horizontal pan is dragged past the photo's content edge so the same
    /// continuous swipe carries on to the next bird.
    @State private var pageCommand: PageCommand?
    /// Whether the chrome is shown. A zoom hides it, exactly as in the viewer.
    @State private var chromeVisible = true

    /// How long one bird takes to dissolve into the next.
    private static let crossfade: Double = 0.3

    /// How far the card sits in from every edge of the pane. The pane's outer
    /// three edges are the display's, so this is also its distance from the
    /// glass; adjust to make the card float more or less.
    static let inset: CGFloat = 8

    /// Blank gutter shown between birds while paging, matching the viewer.
    private static let pageSpacing: CGFloat = 24

    /// Radius used where the display's own curve could not be read — see
    /// `cardRadius(display:)`. Chosen to sit a card inset by `inset` inside a
    /// display corner of the size phones have had for years.
    private static let fallbackCornerRadius: CGFloat = 48

    /// The smallest radius worth calling a display's. Anything under this is
    /// taken as "not the display's curve" rather than as a very square screen.
    private static let minimumDisplayRadius: CGFloat = 24

    /// The card's corner radius: concentric with the display's own curve, which
    /// is what a shared centre means — the gap between the two is `inset` the
    /// whole way round, so the card's corner follows the glass's rather than
    /// cutting across it.
    ///
    /// Falls back to a constant where the display's curve cannot be read.
    /// `GeometryProxy.concentricCornerRadii(in:)` is the only way to ask, and
    /// it does not always answer: on a foldable's outer display it reports 8pt
    /// for the whole display rect, which is no display's corner and which the
    /// subtraction below would turn into a square card.
    private static func cardRadius(display: CGFloat?) -> CGFloat {
        guard let display, display >= minimumDisplayRadius + inset else {
            return fallbackCornerRadius
        }
        return display - inset
    }

    /// Duration of the chrome's show/hide fade, matching the viewer's.
    private static let chromeToggle: Double = 0.12

    /// The bird the pane is actually showing — the page it is on, which a swipe
    /// moves ahead of `selection` for the instant before the tab catches up.
    private var shown: String? {
        guard let names = current?.names, names.indices.contains(pagedIndex) else {
            return selection
        }
        return names[pagedIndex]
    }

    private func commonName(for scientificName: String) -> String {
        lifeListStore?.commonName(for: scientificName)
            ?? SpeciesCatalog.shared.commonName(for: scientificName)
            ?? scientificName
    }

    /// The item the chrome describes: species-scoped, like the Life List's and
    /// the Identify tab's, so the panel summarizes every sighting of the bird
    /// rather than any one of them.
    private func item(for scientificName: String) -> SpeciesPhotoItem {
        SpeciesPhotoItem(scientificName: scientificName, showsAllObservations: true)
    }

    var body: some View {
        GeometryReader { proxy in
            let radius = Self.cardRadius(display: displayCornerRadius)
            // The card's own interior, which is what the photo is fitted to and
            // so what the zoom floor is measured from.
            let cardWidth = max(0, proxy.size.width - Self.inset * 2)

            ZStack {
                // Edge to edge inside the card, and under the photo rather than
                // behind the whole pane, so the card still reads as black while
                // a crossfade has two photos on top of it at partial opacity.
                Color.black

                // The picture being left, held still while the new one comes
                // up over it.
                if let outgoing {
                    pager(outgoing, isFront: false)
                }
                if let current {
                    pager(current, isFront: true)
                        .opacity(incomingOpacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if let shown {
                    SpeciesNameCapsule(
                        name: commonName(for: shown),
                        contentWidth: cardWidth,
                        // No bar, so nothing to leave room for but a margin.
                        reserving: 24
                    )
                    .padding(.top, 12)
                    // The name rides above the photo without taking its taps —
                    // a tap anywhere in the pane belongs to the photo.
                    .allowsHitTesting(false)
                    .opacity(chromeVisible ? 1 : 0)
                    .animation(.easeInOut(duration: Self.chromeToggle), value: chromeVisible)
                }
            }
            .overlay(alignment: .bottom) {
                if let shown {
                    // No map link and no observation list: the pane has no
                    // presentation of its own to put either on, and the list
                    // beside it already carries both per row. The panel prints
                    // the same facts plainly instead — see `SpeciesInfoPanel`.
                    SpeciesInfoPanel(
                        item: item(for: shown),
                        observations: lifeListStore?.observations(for: shown) ?? [],
                        contentWidth: cardWidth
                    )
                    .padding(.bottom, 12)
                    .opacity(chromeVisible ? 1 : 0)
                    .allowsHitTesting(chromeVisible)
                    .animation(.easeInOut(duration: Self.chromeToggle), value: chromeVisible)
                }
            }
            // The photo is fitted to the card, but a zoom can carry it past the
            // edges; this is what keeps it inside its own half.
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .padding(Self.inset)
        }
        .onChange(of: selection, initial: true) { _, bird in
            crossfade(to: bird)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shown.map { "Photo of \(commonName(for: $0))" } ?? "No bird heard yet")
    }

    /// One slot's paged photographs.
    ///
    /// Only the front slot reports anything back: the one behind it is a
    /// picture on its way out, and a zoom or a page turn it announces would be
    /// describing a pane the user is no longer looking at.
    private func pager(_ slot: PaneSlot, isFront: Bool) -> some View {
        PhotoPager(
            count: slot.names.count,
            initialIndex: slot.index,
            pagingDisabled: !isFront,
            interPageSpacing: Self.pageSpacing,
            pageTo: isFront ? pageCommand : nil,
            onIndexChange: { index in
                guard isFront else { return }
                pagedIndex = index
                if slot.names.indices.contains(index) {
                    onPage(slot.names[index])
                }
            },
            onSettledChange: { if isFront { paging.swipeSettled = $0 } },
            pageInputs: PagePlacement(spansDisplay: false, left: 0, right: 0)
        ) { index in
            ZoomablePhotoPage(
                item: item(for: slot.names[index]),
                paging: paging,
                // Fitted inside the card, not grown to span a display: the
                // card *is* the frame, and fitting it is what makes that
                // frame the zoom floor.
                spansDisplay: false,
                restingInsets: (0, 0),
                onToggleUI: {},
                onZoomChange: { zoomed in
                    guard isFront, index == pagedIndex else { return }
                    onZoomChange(zoomed)
                    // Nothing over the magnified picture, matching the
                    // viewer — and the chrome comes back when it does.
                    if chromeVisible == zoomed { chromeVisible = !zoomed }
                },
                onAtTopEdgeChange: { _ in },
                onPageBeyondEdge: { direction in
                    guard isFront, index == pagedIndex else { return }
                    let target = min(
                        max(pagedIndex + direction, 0),
                        max(slot.names.count - 1, 0)
                    )
                    guard target != pagedIndex else { return }
                    pageCommand = PageCommand(index: target)
                },
                expandsIntoSafeArea: false
            )
        }
        .id(slot.id)
    }

    /// Dissolves the pane over to `bird`, retaking the snapshot of what can be
    /// paged through as it goes.
    ///
    /// A no-op when that bird is already the page on show, which is the case
    /// every time the tab is only catching up to a swipe the user just made —
    /// without it, each swipe would be answered by a crossfade back to itself.
    private func crossfade(to bird: String?) {
        guard let bird else { return }
        guard bird != shown || current == nil else { return }
        let names = self.names.contains(bird) ? self.names : [bird]
        let slot = PaneSlot(
            id: nextSlotID,
            names: names,
            index: names.firstIndex(of: bird) ?? 0
        )
        nextSlotID &+= 1
        pagedIndex = slot.index
        // A fresh page is never zoomed, so the chrome comes back with it.
        chromeVisible = true
        onZoomChange(false)
        // Nothing here ever slides in, so the page gate is simply open — the
        // full-resolution swap is free to land as soon as it arrives.
        paging.opened = true

        guard current != nil else {
            // First bird of the session: nothing to dissolve out of.
            current = slot
            incomingOpacity = 1
            return
        }
        outgoing = current
        current = slot
        incomingOpacity = 0
        withAnimation(.easeInOut(duration: Self.crossfade)) {
            incomingOpacity = 1
        } completion: {
            outgoing = nil
        }
    }
}

/// One mounted pager: the birds it can page through and where it started.
///
/// Identified per mount rather than per bird, so putting the same bird back on
/// the pane still counts as a new picture to dissolve to.
private struct PaneSlot: Identifiable, Equatable {
    let id: Int
    let names: [String]
    let index: Int
}
