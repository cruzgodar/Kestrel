import SwiftUI

/// The Identify tab's left-hand pane on a foldable's inner display: the
/// full-screen bird viewer, in half a screen, standing open beside the list.
///
/// The same parts the viewer is made of — `PhotoPager` over `ZoomablePhotoPage`
/// for the photograph, `SpeciesInfoPanel` for the chrome — minus the two
/// controls that only make sense over a presentation: Back, because there is
/// nothing to go back to, and More, because the list beside it already carries
/// every one of those actions per row.
///
/// It also wears less chrome than the viewer does. The pane is a card in half a
/// display, and a name capsule across the top plus a panel across the bottom
/// pinched the photograph into a column between them; the panel carries the
/// name as its first line instead, and in the half that has no room to spare it
/// is not drawn at all.
///
/// The two halves are different shapes, so they are not the same card. Beside
/// the list the pane is tall and a photograph is wide, so the picture fills a
/// band across the top and a grey card under it makes the rest of the half
/// deliberate; above the list the half is already about the shape of a
/// photograph, and the picture is all there is. See `showsBackingCard`.
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
    /// Which half of the display the pane has — see `SpeciesPane.Placement`.
    ///
    /// It decides a good deal more than which corner the panel sits in. The
    /// two halves are different shapes and the pane is drawn differently in
    /// each; see `showsBackingCard`.
    var placement: SpeciesPane.Placement = .leadingHalf
    /// What the system's bars took out of the display. The pane is laid out
    /// full-bleed, so its own proxy reports none, and the placement that keeps
    /// clear of them horizontally has to be told.
    var safeArea = EdgeInsets()
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

    /// How long one bird takes to dissolve into the next. Short: the pane
    /// changes birds on its own as they are heard, and a dissolve slow enough
    /// to watch turns a list that is keeping up into one that is lagging.
    static let crossfade: Double = 0.16

    /// How far the card sits in from every edge of the pane. The pane's outer
    /// three edges are the display's, so this is also its distance from the
    /// glass; adjust to make the card float more or less.
    ///
    /// The same figure is spent twice where there is a backing card: once
    /// between the glass and the card, and again between the card and the
    /// photograph inside it.
    static let inset: CGFloat = 8

    /// Whether the pane draws a grey card behind the photograph, with the
    /// photograph inset inside it, rather than the bare photograph.
    ///
    /// Beside the list, yes. The pane there is a tall half of a display and a
    /// photograph is wider than it is tall, so one fitted to that half fills a
    /// band across the top and leaves the rest of the half empty; a card under
    /// it makes that emptiness deliberate, and gives the details panel
    /// something to sit on.
    ///
    /// Above the list, no. That half is already about the shape of a
    /// photograph, so there is no spare room for a card to show through —
    /// only a rim of grey around the picture, which is a frame nobody asked
    /// for.
    private var showsBackingCard: Bool { placement == .leadingHalf }

    /// Whether the details panel is drawn. It needs room of its own, and the
    /// half that has none would be covering the photograph with it.
    private var showsPanel: Bool { placement == .leadingHalf }

    /// Blank gutter shown between birds while paging, matching the viewer.
    private static let pageSpacing: CGFloat = 24

    /// Radius used where the display's own curve could not be read — see
    /// `cardRadius(display:)`. Chosen to sit a card inset by `inset` inside a
    /// display corner of the size phones have had for years.
    private static let fallbackCornerRadius: CGFloat = 48

    /// The smallest radius worth calling a display's. Anything under this is
    /// taken as "not the display's curve" rather than as a very square screen.
    private static let minimumDisplayRadius: CGFloat = 24

    /// The two curves the pane cuts: the backing card's, and the photograph's
    /// inside it.
    ///
    /// Both concentric with the display's own, which is what a shared centre
    /// means — the gap between the glass and the card is `inset` the whole way
    /// round, and between the card and the photograph another `inset`, so each
    /// corner follows the one outside it rather than cutting across it. With
    /// no backing card there is one curve and the photograph takes it.
    ///
    /// Falls back to a constant where the display's curve cannot be read.
    /// `GeometryProxy.concentricCornerRadii(in:)` is the only way to ask, and
    /// it does not always answer: on a foldable's outer display it reports 8pt
    /// for the whole display rect, which is no display's corner and which the
    /// subtraction below would turn into a square card.
    private static func radii(
        display: CGFloat?,
        backed: Bool
    ) -> (card: CGFloat, photo: CGFloat) {
        let card: CGFloat = {
            guard let display, display >= minimumDisplayRadius + inset else {
                return fallbackCornerRadius
            }
            return display - inset
        }()
        return (card: card, photo: backed ? max(0, card - inset) : card)
    }

    /// How far in from the card's bottom edge the info panel sits.
    ///
    /// The same rule the full-screen viewer uses for its own corner-tucked
    /// panel, measured from the card rather than from the display because the
    /// card is what the panel is inside: concentric corners share a centre, so
    /// the gap between them is the difference of their radii. The panel is
    /// centred rather than tucked into a corner, so this only sets how far it
    /// floats off the bottom — but keeping the two in step means it clears the
    /// card's curve by the same margin whatever the display's is.
    private static func panelInset(cardRadius: CGFloat) -> CGFloat {
        max(panelInsetFloor, cardRadius - SpeciesChrome.cornerPillRadius)
    }

    /// The least the panel may sit in from the edge, for a card whose own
    /// curve is tighter than the pill's.
    private static let panelInsetFloor: CGFloat = 12

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
            // The pane's own half of the display. The view is laid out
            // full-bleed across the whole of it and takes its half here,
            // rather than being handed a half-sized frame to be aligned in:
            // a frame aligned inside the safe area lands wherever the bars
            // leave it, which is what put the card 8pt below the status bar
            // in one placement and a couple of points *above* the glass in
            // the other. Measuring the half here makes both edges the
            // display's own, which is what the corner radius answers to.
            let half = CGSize(
                width: placement == .leadingHalf ? proxy.size.width / 2 : proxy.size.width,
                height: placement == .topHalf ? proxy.size.height / 2 : proxy.size.height
            )
            let radii = Self.radii(display: displayCornerRadius, backed: showsBackingCard)
            // The card's own interior, which is what the photo is fitted to and
            // so what the zoom floor is measured from.
            let cardWidth = max(0, half.width - edgeInsets.leading - edgeInsets.trailing)

            ZStack(alignment: .topLeading) {
                // Nothing heard yet. A quiet grey rectangle with the bird
                // glyph in it, the same placeholder the watch shows while it
                // waits — an empty card would read as something that had
                // failed to load.
                if current == nil {
                    placeholder
                }

                // The picture being left, held still while the new one comes
                // up over it.
                if let outgoing {
                    pager(outgoing, isFront: false, cornerRadius: radii.photo)
                }
                if let current {
                    pager(current, isFront: true, cornerRadius: radii.photo)
                        .opacity(incomingOpacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A zoom can carry the photograph past the edges of its own box;
            // this is what keeps it inside.
            .clipShape(RoundedRectangle(cornerRadius: radii.photo, style: .continuous))
            // Inside the backing card, where there is one. Nothing where there
            // is not, which leaves the photograph the whole of the pane.
            .padding(showsBackingCard ? Self.inset : 0)
            .background {
                RoundedRectangle(cornerRadius: radii.card, style: .continuous)
                    .fill(showsBackingCard ? Self.backingFill : Color.clear)
            }
            // Across the bottom of the card, centred. One piece of chrome, on
            // the part of the card the photograph does not reach: the pane is
            // a tall card standing beside a list, and a name capsule across
            // its top and a panel across its bottom left a column of
            // photograph pinched between them; the name is the panel's first
            // line instead.
            //
            // No map link and no observation list: the pane has no
            // presentation of its own to put either on, and the list beside it
            // already carries both per row. The panel prints the same facts
            // plainly — see `SpeciesInfoPanel`.
            .overlay(alignment: .bottom) {
                SpeciesInfoPanel(
                    item: shown.map { item(for: $0) },
                    observations: shown.map {
                        lifeListStore?.observations(for: $0) ?? []
                    } ?? [],
                    contentWidth: cardWidth,
                    // Nothing heard yet: the panel says so rather than
                    // leaving the card captionless.
                    title: shown.map(commonName(for:)) ?? Self.idleTitle
                )
                .padding(.horizontal, Self.panelInset(cardRadius: radii.card))
                .padding(.bottom, Self.panelInset(cardRadius: radii.card))
                .opacity(showsPanel && chromeVisible ? 1 : 0)
                .allowsHitTesting(showsPanel && chromeVisible)
                .animation(.easeInOut(duration: Self.chromeToggle), value: chromeVisible)
            }
            .padding(edgeInsets)
            .frame(width: half.width, height: half.height, alignment: .topLeading)
        }
        // Top to bottom of the glass. The card's margin from the bezel is
        // `inset` and nothing else: a pane that stopped at the safe area left
        // a band of empty tab above the picture, and the card's top corners
        // were then nowhere near the display's for their radius to answer to.
        .ignoresSafeArea()
        .onChange(of: selection, initial: true) { _, bird in
            crossfade(to: bird)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shown.map { "Photo of \(commonName(for: $0))" } ?? "No bird heard yet")
    }

    /// How far the card sits in from each edge of the pane.
    ///
    /// `inset` on all four, with one exception: the placement that spans the
    /// display's full width keeps clear of the bars horizontally, because
    /// something of the system's is drawn there. Vertically it does not —
    /// the pane runs to the glass, top and bottom, and the corner radius is
    /// cut to suit.
    private var edgeInsets: EdgeInsets {
        EdgeInsets(
            top: Self.inset,
            leading: Self.inset + (placement == .topHalf ? safeArea.leading : 0),
            bottom: Self.inset,
            trailing: Self.inset + (placement == .topHalf ? safeArea.trailing : 0)
        )
    }

    /// What the panel calls a pane with nothing on it yet.
    private static let idleTitle = "Listening\u{2026}"

    /// The card before anything has been heard: a low-opacity grey with the
    /// bird glyph centred in it, the same placeholder the watch shows while it
    /// waits.
    ///
    /// Grey on grey rather than the watch's white on black. The watch draws its
    /// on a black screen and can spend white on the glyph; this card sits on
    /// whatever the tab's background is, and white at half opacity all but
    /// disappeared on a light one.
    private var placeholder: some View {
        Self.backingFill
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                Image(systemName: "bird.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.gray.opacity(Self.placeholderGlyphOpacity))
            }
    }

    /// The placeholder's fill, and the glyph on it.
    private static let placeholderOpacity: Double = 0.25
    private static let placeholderGlyphOpacity: Double = 0.55

    /// The backing card's fill — the placeholder's grey, so an empty pane and
    /// a full one are the same card with and without a picture on it, rather
    /// than two different surfaces.
    private static let backingFill = Color.gray.opacity(placeholderOpacity)

    /// One slot's paged photographs.
    ///
    /// Only the front slot reports anything back: the one behind it is a
    /// picture on its way out, and a zoom or a page turn it announces would be
    /// describing a pane the user is no longer looking at.
    private func pager(_ slot: PaneSlot, isFront: Bool, cornerRadius: CGFloat) -> some View {
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
                // The card is a fixed half of a display and the photograph is
                // whatever shape it is, so one of the two always has slack.
                // Spent below and to the right of the picture rather than split
                // around it: the picture then starts in the card's own top
                // leading corner, and the slack collects at the far end, where
                // the details panel is.
                anchorsTopLeading: true,
                // The picture's own corners, not just the box's. Fitted into a
                // half of a display it rarely fills one, so clipping the box
                // rounds whichever corners the picture happens to reach and
                // leaves the others square against the card.
                photoCornerRadius: cornerRadius
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
