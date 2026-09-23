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
/// name as its first line instead, and stands in whatever the picture left
/// over rather than across the foot of it.
///
/// That leftover is most of the card. The pane is a tall half of a display and
/// a photograph is wider than it is tall, so one fitted to the half fills a
/// band across the top; the card under it is washed the colour the bird's row
/// carries in the list, which is what makes the rest of the half deliberate
/// rather than empty.
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
    /// What the system's bars took out of the display. The pane is laid out
    /// full-bleed, so its own proxy reports none, and the details panel — which
    /// does keep clear of them — has to be told.
    var safeArea = EdgeInsets()
    /// The display's own corner radius, so the card's corners can be cut
    /// concentric with it. `nil` where it could not be read, which falls back
    /// to a plain rounded rectangle.
    var displayCornerRadius: CGFloat?

    /// Only for the name on the capsule and the sightings on the panel.
    /// Optional so previews without a store still render.
    @Environment(LifeListStore.self) private var lifeListStore: LifeListStore?
    /// For two things the card takes from the session rather than from the
    /// bird: whether anything is being listened for at all, and the life list
    /// as it stood when the session began, which is what decides a bird's
    /// colour. Optional for the same reason as the store.
    @Environment(RecordingManager.self) private var manager: RecordingManager?

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
    /// The outgoing pager's, animated 1 to 0 when there is nothing coming in
    /// behind it — the pane being cleared back to its placeholder.
    @State private var outgoingOpacity: Double = 1
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
    /// The swipe in progress, so the card's colour can cross over with the
    /// picture instead of snapping when it lands.
    @State private var swipe = PaneSwipe()
    /// The shape of the photograph on show, so the panel can be placed in what
    /// the picture does not cover. See `pictureSize(in:)`.
    @State private var photoAspect: CGFloat?
    /// How tall the details panel came out, so it can be centred in the band
    /// of spare card *unless* being centred would run it into the bottom safe
    /// area — see `panelInsets(cardRadius:card:)`.
    ///
    /// Measured rather than reckoned: the panel's height is whatever its
    /// content needs, and it is a couple of lines taller for a bird with a
    /// sighting on it than for one without. Nothing here feeds back into it —
    /// the height follows from the width, and only the vertical insets move.
    @State private var panelHeight: CGFloat = 0

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

    /// Whether the details panel is drawn.
    ///
    /// With no bird on the pane the panel says only that the app is listening,
    /// which is worth saying while it is and is a lie the rest of the time —
    /// so an empty panel waits for a session.
    private var showsPanel: Bool {
        shown != nil || manager?.isRecording == true
    }

    /// Which of the Identify list's three washes the card is wearing, for a
    /// given bird. The card and that bird's row are the same colour.
    private func tint(for scientificName: String) -> SpeciesTint {
        SpeciesTint(
            scientificName: scientificName,
            lifeListSnapshot: manager?.lifeListSnapshot ?? [],
            starredNames: lifeListStore?.starredNames ?? []
        )
    }

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
        card box: CGSize
    ) -> (card: CGFloat, photo: CGFloat) {
        let fromDisplay: CGFloat = {
            guard let display, display >= minimumDisplayRadius + inset else {
                return fallbackCornerRadius
            }
            return display - inset
        }()
        // Never more than half the box it is cutting: past that a rounded
        // rectangle is a capsule, and the corner stops answering to the
        // display's curve at all. It is the display's answer that needs the
        // guard — it is read from a proxy, and a pass where the safe area has
        // not landed yet reads a rect that is not the display's.
        let card = min(fromDisplay, min(box.width, box.height) / 2)
        let photoBox = CGSize(
            width: max(0, box.width - inset * 2),
            height: max(0, box.height - inset * 2)
        )
        let photo = min(
            max(0, card - inset),
            min(photoBox.width, photoBox.height) / 2
        )
        return (card: card, photo: photo)
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
            // leave it, a couple of points off the glass in either direction.
            // Measuring the half here makes both edges the display's own,
            // which is what the corner radius answers to.
            let half = CGSize(width: proxy.size.width / 2, height: proxy.size.height)
            // The card's own interior, which is what the photo is fitted to and
            // so what the zoom floor is measured from.
            let card = CGSize(
                width: max(0, half.width - Self.inset * 2),
                height: max(0, half.height - Self.inset * 2)
            )
            let radii = Self.radii(display: displayCornerRadius, card: card)

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
                        .opacity(outgoingOpacity)
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
            .padding(photoInsets)
            // The card under it, washed the colour this bird's row carries in
            // the list beside it. It shows wherever the picture's shape leaves
            // slack — a band down one side, most of a half down the other — so
            // what would be empty tab is the bird's own colour instead.
            .background {
                PaneWash(
                    swipe: swipe,
                    names: current?.names ?? [],
                    lifeListSnapshot: manager?.lifeListSnapshot ?? [],
                    starredNames: lifeListStore?.starredNames ?? [],
                    cornerRadius: radii.card
                )
            }
            // Centred in whatever the photograph left over. One piece of
            // chrome, on the part of the card the picture does not reach: the
            // pane is a tall card standing beside a list, and a name capsule
            // across its top and a panel across its bottom left a column of
            // photograph pinched between them; the name is the panel's first
            // line instead.
            //
            // No map link and no observation list: the pane has no
            // presentation of its own to put either on, and the list beside it
            // already carries both per row. The panel prints the same facts
            // plainly — see `SpeciesInfoPanel`.
            .overlay(alignment: .center) {
                SpeciesInfoPanel(
                    item: shown.map { item(for: $0) },
                    observations: shown.map {
                        lifeListStore?.observations(for: $0) ?? []
                    } ?? [],
                    contentWidth: card.width,
                    // Darker than the viewer's, because it is not over a
                    // photograph — see `SpeciesChrome.paneGlassTint`.
                    glass: SpeciesChrome.paneGlass,
                    // Nothing heard yet: the panel says so rather than
                    // leaving the card captionless.
                    title: shown.map(commonName(for:)) ?? Self.idleTitle
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    panelHeight = $0
                }
                .padding(panelInsets(cardRadius: radii.card, card: card))
                .opacity(panelVisible ? 1 : 0)
                .allowsHitTesting(panelVisible)
                .animation(.easeInOut(duration: Self.chromeToggle), value: panelVisible)
                // Fades where it stands, and never travels. The pane changes
                // shape when the display does, and the panel's corner of the
                // card is somewhere else entirely afterwards; left to inherit
                // the rotation's animation it took that as a journey to make,
                // and flew off the screen to make it. Clearing the inherited
                // transaction leaves the move instant and the fade — which
                // brings its own animation — the only thing that is watched.
                .transaction { $0.animation = nil }
            }
            .padding(Self.inset)
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
        // Whatever is actually on the pane, which a swipe moves ahead of
        // `selection`. Already in memory by the time it is being looked at, so
        // this is a cache read in all but the first instant.
        .task(id: shown) {
            guard let shown else {
                photoAspect = nil
                return
            }
            let size = await RemoteSpeciesImageStore.shared.image(for: shown)?.size
            guard let size, size.height > 0 else { return }
            photoAspect = size.width / size.height
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shown.map { "Photo of \(commonName(for: $0))" } ?? "No bird heard yet")
    }

    /// Whether the details panel is on screen: drawn at all, and not hidden by
    /// a zoom.
    private var panelVisible: Bool { showsPanel && chromeVisible }

    /// How far the details panel sits in from the card's edges.
    ///
    /// Two things at once, and the second wins where they disagree.
    ///
    /// The panel is centred in whatever the photograph left over — the card is
    /// a fixed half of a display and the picture is whatever shape it is, so
    /// one of the two always has slack, and anchored to the top-leading corner
    /// the slack is a band along one far edge. Padding the card by the
    /// picture's own extent on that side leaves the centre of what remains,
    /// which is where the panel goes.
    ///
    /// And it is clear of the bars, unlike the card it sits on: the card is a
    /// picture and belongs against the glass, the panel is something to read
    /// and does not. That is deliberately *not* symmetric — a bar on one side
    /// pushes the panel off the centre of the band rather than being matched
    /// on the other side to preserve it.
    ///
    /// The home indicator is the exception, and it gets the gentler treatment:
    /// the panel is centred in the band and only lifted if being centred there
    /// would actually carry it into the indicator's clearance. A flat bottom
    /// inset would buy that clearance every time, whether it was needed or
    /// not, and pay for it by sitting the panel half of one off centre in
    /// every band big enough to have had room for both.
    ///
    /// Only the bars the pane is actually against, though, which is every edge
    /// but the trailing one: the card's trailing edge is the middle of the
    /// display, where nothing of the system's is drawn. That one is not a
    /// detail. The tab bar floats at the trailing edge of the *display* and
    /// takes a good 90pt of safe area with it, all of it over the list; spent
    /// on the panel as well it shifted it most of a hundred points off the
    /// centre of a card it was supposed to be centred in.
    private func panelInsets(cardRadius: CGFloat, card: CGSize) -> EdgeInsets {
        let corner = Self.panelInset(cardRadius: cardRadius)
        let picture = pictureSize(in: card)
        // Fitted, so exactly one axis falls short of the box and the band of
        // spare card is along one far edge. Padding by the picture's extent on
        // the *other* axis would be padding by the whole card, which leaves the
        // panel a column one letter wide.
        let band = (
            below: card.height - photoInsets.top - photoInsets.bottom - picture.height,
            beside: card.width - photoInsets.leading - photoInsets.trailing - picture.width
        )
        let top = band.below > 0
            ? max(photoInsets.top + picture.height, corner + safeArea.top)
            : corner + safeArea.top
        // Centring in what is left below `top` is what a bottom inset of zero
        // gives; every point of bottom inset lifts the panel by half of one.
        // So buy exactly the lift the clearance is short by, and nothing more.
        let clearance = corner + safeArea.bottom
        let lift = top + panelHeight + clearance * 2 - card.height
        return EdgeInsets(
            top: top,
            leading: band.beside > 0
                ? max(photoInsets.leading + picture.width, corner + safeArea.leading)
                : corner + safeArea.leading,
            bottom: max(0, lift),
            trailing: corner
        )
    }

    /// How big the photograph comes out inside the card: fitted, so one of its
    /// two dimensions matches the box and the other falls short.
    ///
    /// Worked out here rather than reported back from the scroll view that
    /// actually draws it. The fit is a rule — this box, that aspect ratio —
    /// and a value that travels up from the view doing the drawing arrives a
    /// frame late, arrives once per mounted page rather than once for the one
    /// on screen, and has to be threaded through three layers of representable
    /// to get here. The aspect ratio is all that is needed, and the pane can
    /// ask for that directly.
    ///
    /// Falls back to 4:3, which is what the photo set is mostly cut to, until
    /// the picture is in hand.
    private func pictureSize(in card: CGSize) -> CGSize {
        let box = CGSize(
            width: max(0, card.width - photoInsets.leading - photoInsets.trailing),
            height: max(0, card.height - photoInsets.top - photoInsets.bottom)
        )
        guard box.width > 0, box.height > 0 else { return .zero }
        let aspect = photoAspect ?? Self.fallbackPhotoAspect
        guard aspect > 0 else { return box }
        return box.width / box.height > aspect
            ? CGSize(width: box.height * aspect, height: box.height)
            : CGSize(width: box.width, height: box.width / aspect)
    }

    /// The shape most of the species photographs are, used until the one on
    /// show has been measured.
    private static let fallbackPhotoAspect: CGFloat = 4.0 / 3.0

    /// How far the photograph sits in from each edge of the card.
    ///
    /// `inset` on all four, so there is a margin of card around the picture
    /// and its corner is concentric with the card's.
    private var photoInsets: EdgeInsets {
        EdgeInsets(
            top: Self.inset,
            leading: Self.inset,
            bottom: Self.inset,
            trailing: Self.inset
        )
    }

    /// What the panel calls a pane with nothing on it yet.
    private static let idleTitle = "Listening\u{2026}"

    /// The pane before anything has been heard: the bird glyph, centred, the
    /// same placeholder the watch shows while it waits.
    ///
    /// No fill of its own — the card behind it is the fill, and an empty pane
    /// is that card with nothing on it rather than a second surface laid over
    /// it. Grey on grey rather than the watch's white on black: the watch
    /// draws its on a black screen and can spend white on the glyph, and white
    /// at half opacity all but disappeared on this one.
    private var placeholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                Image(systemName: "bird.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.gray.opacity(Self.placeholderGlyphOpacity))
            }
    }

    /// The placeholder glyph's weight against the card behind it.
    private static let placeholderGlyphOpacity: Double = 0.55

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
            // Only the front pager: the one behind it is a picture on its way
            // out, and the card takes its colour from the bird being swiped
            // between, not from that.
            onSwipeProgress: { from, fraction in
                guard isFront else { return }
                swipe.from = from
                swipe.fraction = fraction
            },
            pageInputs: PagePlacement(
                spansDisplay: false,
                left: 0,
                right: 0,
                cornerRadius: cornerRadius
            )
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
        guard let bird else {
            clear()
            return
        }
        guard bird != shown || current == nil else { return }
        let names = self.names.contains(bird) ? self.names : [bird]
        let slot = PaneSlot(
            id: nextSlotID,
            names: names,
            index: names.firstIndex(of: bird) ?? 0
        )
        nextSlotID &+= 1
        pagedIndex = slot.index
        // A fresh snapshot, so the card's colour is this bird's and the swipe
        // that was being tracked (if any) is over.
        swipe.from = slot.index
        swipe.fraction = 0
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

/// The swipe the pane is in the middle of: the page it started from, and how
/// far it has travelled (−1 to 1, negative toward the previous bird).
///
/// An object rather than `@State` on the pane, because a drag writes to it
/// sixty times a second. Held as state it would rebuild the pane's whole body
/// on every tick — both pagers, and the hosted photograph inside each
/// — to repaint one rectangle. Only `PaneWash` reads it, so only
/// `PaneWash` redraws.
@Observable
final class PaneSwipe {
    var from = 0
    var fraction: CGFloat = 0
}

/// The card behind the photograph, washed the colour the bird's row carries in
/// the list beside it, and carrying that colour across as a swipe does.
private struct PaneWash: View {
    let swipe: PaneSwipe
    /// The birds the pager can move between, in its own index order.
    let names: [String]
    let lifeListSnapshot: Set<String>
    let starredNames: Set<String>
    let cornerRadius: CGFloat

    private func tint(_ index: Int) -> SpeciesTint {
        guard names.indices.contains(index) else { return .plain }
        return SpeciesTint(
            scientificName: names[index],
            lifeListSnapshot: lifeListSnapshot,
            starredNames: starredNames
        )
    }

    /// The bird's colour, or the mix of two of them mid-swipe.
    private var color: Color {
        let from = tint(swipe.from)
        let toward = swipe.fraction > 0 ? swipe.from + 1 : swipe.from - 1
        guard swipe.fraction != 0, names.indices.contains(toward) else {
            return from.color
        }
        return SpeciesTint.blend(
            from,
            to: tint(toward),
            fraction: abs(Double(swipe.fraction))
        )
    }

    var body: some View {
        let color = color
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color)
            // Mid-swipe the colour is already moving with the finger and must
            // not be animated on top of that. A change with no swipe under it
            // is the pane being handed a different bird from outside, and
            // crosses over with the picture.
            .animation(
                swipe.fraction == 0
                    ? .easeInOut(duration: HalfScreenSpeciesView.crossfade)
                    : nil,
                value: color
            )
    }
}

/// Dissolves the pane back to its placeholder: whatever is on it fades out
/// over nothing, which is what a new session starting looks like.
///
/// The other direction of `crossfade(to:)`, and it needs its own opacity
/// because there is no incoming picture to fade *in* over the outgoing one.
private extension HalfScreenSpeciesView {
    func clear() {
        guard current != nil else { return }
        outgoing = current
        current = nil
        pagedIndex = 0
        swipe.from = 0
        swipe.fraction = 0
        chromeVisible = true
        onZoomChange(false)
        outgoingOpacity = 1
        withAnimation(.easeInOut(duration: Self.crossfade)) {
            outgoingOpacity = 0
        } completion: {
            outgoing = nil
            outgoingOpacity = 1
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
