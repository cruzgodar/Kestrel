import SwiftUI
import UIKit

/// One bird shown in the full-screen viewer, plus the sighting metadata its
/// caption needs. A viewer is opened over an *ordered* array of these (life-list
/// order, or the birds within a map card) so the user can swipe between them.
struct SpeciesPhotoItem: Identifiable, Equatable {
    let scientificName: String
    var placeName: String? = nil
    var dateFound: Date? = nil
    /// Whether this item stands for the species as a whole rather than for one
    /// particular sighting. Set by the Life List (and the Identify tab), where a
    /// bird is one row no matter how many times it has been seen, so the info
    /// panel summarizes *every* recorded sighting. A viewer opened from a map
    /// pin leaves it off: that pin is one sighting, and its place and date are
    /// the ones to show.
    var showsAllObservations: Bool = false
    /// The one recorded sighting this item stands for, when it was opened from a
    /// map pin — the *earliest* of them when the pin covers several. `nil` on a
    /// species-scoped item, whose Edit and Delete ask which sighting they mean.
    ///
    /// Drives the caption and the "was this sighting deleted?" check, both of
    /// which are about the one record on screen. What Edit and Delete act on is
    /// `pinnedSightings`.
    var observation: LifeListEntry.Observation? = nil
    /// Every sighting the pin this was opened from stands for, `observation`
    /// included. Empty on a species-scoped item.
    ///
    /// A map thumbnail is one image per *species* (`BirdCluster.uniqueByEarliest`),
    /// so repeat visits to one spot collapse into a single pin. Acting on
    /// `observation` alone would then quietly touch only the earliest of them and
    /// leave the thumbnail sitting there looking untouched — which is precisely
    /// what `MapPointMenu` (the same thumbnail's *long press*) asks a question to
    /// avoid. The viewer asks the same question, over the same list.
    var pinnedSightings: [LifeListEntry.Observation] = []
    var id: String { scientificName }
}

/// App-wide driver for the full-screen photo viewer. Injected into the
/// environment at the root; any `SpeciesPhoto` calls `present(_:)` (singleton)
/// while the Life List passes an ordered sibling list via `present(names:index:)`
/// so the viewer can page between birds. Optional in the environment so previews
/// without it simply don't present.
@MainActor
@Observable
final class SpeciesPhotoPresenter {
    /// A request to open the viewer over `names`, starting on `index`. `id` is
    /// fresh per request so re-presenting the same bird still fires the cover;
    /// the viewer owns its own page selection after that, so internal paging
    /// doesn't rebuild the cover.
    struct Presentation: Identifiable, Equatable {
        let id = UUID()
        var names: [String]
        var index: Int
    }

    var presented: Presentation?

    /// Opens the viewer on a single bird with nothing to swipe to.
    func present(_ scientificName: String) {
        presented = Presentation(names: [scientificName], index: 0)
    }

    /// Opens the viewer over an ordered list of birds, starting on `index`.
    func present(names: [String], index: Int) {
        guard !names.isEmpty else { return }
        presented = Presentation(names: names, index: min(max(index, 0), names.count - 1))
    }
}

/// Shared motion state for the viewer's pages. The viewer is considered "moving"
/// both while the card is sliding in on open (`opened == false`) and while a
/// horizontal swipe is in flight (`swipeSettled == false`); `settled` is true only
/// once both have come to rest. Each `ZoomablePhotoPage` reads `settled` to hold
/// *both* its full-resolution download and the swap until the motion stops, so the
/// heavier full-res work never lands while anything is animating (which read as a
/// hitch). A reference type so every page observes the one instance.
@MainActor
@Observable
final class ViewerPaging {
    /// False while the open slide is still carrying the card onto the screen.
    var opened = false
    /// False while a horizontal page swipe (finger or fling) is in motion.
    var swipeSettled = true
    /// True only when the card is fully open and no swipe is in motion.
    var settled: Bool { opened && swipeSettled }
}

/// Tracks whether the current touch has moved enough to count as a drag rather
/// than a tap. Set while the dismiss drag is in motion so the photo's
/// single-tap-to-toggle-chrome is suppressed for that touch — a slight drag that
/// ends in a near-tap should not hide/show the chrome; only a genuine tap should.
/// A reference type so the toggle closure handed down to each page reads the live
/// value instead of a stale captured snapshot.
@MainActor
final class ViewerTouchTracker {
    var dragged = false
}

/// A request to programmatically turn the pager to `index`. Carries a fresh `id`
/// per request so a repeated target still reads as a new command to act on.
/// What a photo page is sized from, as one comparable value — see
/// `PhotoPager.pageInputs`.
struct PagePlacement: Hashable {
    let spansDisplay: Bool
    let left: CGFloat
    let right: CGFloat
    /// The radius the picture's own corners are cut to. Part of this value
    /// because a page is a snapshot taken when it scrolled in: a radius that
    /// changed afterwards — the pane being handed a new display's curve, or a
    /// rotation giving it a different card — would be honoured by every page
    /// built after the change and ignored by the one actually on screen, which
    /// is a picture that is visibly the wrong shape until it is swiped away.
    var cornerRadius: CGFloat = 0
}

struct PageCommand: Equatable {
    let id = UUID()
    let index: Int
}

/// Full-screen, swipeable, zoomable viewer over an ordered set of species
/// photos. Horizontal swipes page between birds; a single-item viewer has
/// nothing to page to. A downward drag (only when not zoomed) slides the whole
/// card off to dismiss, carrying the throw velocity through so the release
/// stays smooth.
struct SpeciesPhotoFullScreen: View {
    let items: [SpeciesPhotoItem]
    /// Title used as the accessibility label on the tappable place name
    /// ("Show on Map" / "Pinpoint on Map").
    var mapButtonTitle: String? = nil
    /// Action for the place-name tap: focus / pinpoint the *current* bird on the
    /// map. `nil` makes the place name non-interactive (and is the case for the
    /// Identify tab / lone map pins).
    var onShowOnMap: ((SpeciesPhotoItem) -> Void)? = nil
    /// Action for a row tapped in the observation list — focus the map on that
    /// particular sighting. `nil` makes the rows non-interactive.
    var onShowObservationOnMap: ((LifeListEntry.Observation) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    /// Chooses how the photo is sized at rest. Regular width means the app has a
    /// large display to itself (a foldable's inner display), where the photo is
    /// grown to span it edge to edge. Compact — an ordinary phone, the outer
    /// display, or one pane of a split — keeps the photo inside the horizontal
    /// safe area, so a vertical system bar never crosses it.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Paired with the horizontal class to tell the big inner display of a
    /// foldable from its outer one. The brief is explicit that the inner display
    /// is regular in *both* axes; an outer display or a phone turned landscape
    /// can report regular width but stays compact in height, and keying off
    /// width alone let the outer display take layouts meant for the inner one.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Maps the photo's resting insets from leading/trailing onto physical
    /// left/right for the UIKit scroll view underneath.
    @Environment(\.layoutDirection) private var layoutDirection
    /// Drives the top-right star toggle. Optional so previews without a store
    /// injected still render (the button just reads as un-starred there).
    @Environment(LifeListStore.self) private var lifeListStore: LifeListStore?

    /// Which page the horizontal paging `ScrollView` is settled on (the page's
    /// integer id). Seeded from `initialIndex` in `init`. `index` derives the
    /// clamped current page from it.
    @State private var scrolledID: Int?
    /// True while the current page is zoomed in — disables horizontal paging and
    /// the swipe-down dismiss so a pan inside the photo doesn't trigger either.
    @State private var isZoomed = false
    /// Whether the current page's zoomed photo is at its top content edge — i.e. it
    /// can't be panned any farther down. When it is, a downward swipe dismisses the
    /// card even though the photo is zoomed (matching the Photos app). Meaningless
    /// while not zoomed (the whole-card swipe-down already handles that case).
    @State private var currentPageAtTopEdge = false

    // Swipe-to-dismiss (applied to the whole card).
    @State private var dragOffset: CGSize = .zero
    @State private var contentOpacity: Double = 1
    /// Latched true once a drag has been recognized as a downward dismiss, so we
    /// keep following the finger's vertical travel without re-testing horizontal
    /// dominance every frame — that re-test made a *slow* drag stutter near the
    /// top, where tiny horizontal finger noise rivaled the small vertical travel
    /// and toggled the gesture on and off. Reset when the drag ends.
    @State private var dismissEngaged = false
    /// The finger's vertical travel at the instant the dismiss engaged, subtracted
    /// from subsequent travel so the card starts following from zero. For the
    /// normal (un-zoomed) swipe this is ~0 since dismiss engages on the first
    /// qualifying frame; it matters for the zoomed case, where the user may have
    /// panned the photo to its top edge before the dismiss takes over — without it
    /// the card would jump down by the already-consumed pan distance.
    @State private var dismissEngageBaseline: CGFloat = 0
    /// Measured viewer size, used to slide the card fully off on dismiss.
    @State private var viewSize: CGSize = CGSize(width: 400, height: 800)
    /// Whether the chrome — the navigation bar carrying Back and More, and the
    /// bottom details panel — is shown. A single tap on the photo toggles it.
    @State private var uiVisible = true
    /// Shared paging state — false while a horizontal swipe is moving, true once
    /// it settles. Pages gate their full-resolution swap on this so the heavier
    /// image only swaps in after the swipe has fully stopped.
    @State private var paging = ViewerPaging()
    /// Whether the in-flight touch has moved (a drag), so a slight drag-and-release
    /// doesn't toggle the chrome the way a real tap does. See `ViewerTouchTracker`.
    @State private var touchTracker = ViewerTouchTracker()
    /// A request to turn the page programmatically, fired when a *zoomed*
    /// horizontal pan is dragged past the photo's content edge so the same
    /// continuous swipe carries on to the next/previous bird (rather than halting
    /// at the edge and needing a second drag). Fresh `id` per request so the pager
    /// acts on each one even when the target index repeats.
    @State private var pageCommand: PageCommand?
    /// True once the open slide has carried the card up over the status bar.
    /// Gates the white (light-content) status bar so it flips *as the card covers
    /// the status bar* — not prematurely at present, while the card is still
    /// sliding up and the light app shows behind the bar (which read as the slow,
    /// mistimed black→white crossfade). Matches the stock Music app's now-playing.
    @State private var cardCoveredStatusBar = false
    /// How the card's translation should reach `dragOffset` — see
    /// `CardTranslation`. Zero while a finger is driving it.
    @State private var cardSlideDuration: Double = 0
    @State private var cardSlideSprings = false
    /// Drives the sheet listing every recorded sighting of the current bird,
    /// raised by the info panel's "N Observations" row.
    @State private var showObservationList = false
    /// Add / edit / delete driven by the top-right menu. Separate from the
    /// observation list's own (`listActions`), which lives inside that sheet so
    /// its presentations layer over it rather than under it.
    @State private var actions = ObservationActions()
    /// The same, for the observation list's swipe actions. Its edits are relayed
    /// on to `actions` (see where it's attached), because that is the trail this
    /// screen's own chrome resolves a held sighting through — two objects, one
    /// answer to "where is that record now".
    @State private var listActions = ObservationActions()

    /// Blank gutter (in points) shown between birds while paging horizontally,
    /// matching the iOS Photos app. Bump this to widen or tighten the gap.
    private let pageSpacing: CGFloat = 24

    /// Past this much downward travel (or a fast enough downward flick),
    /// release dismisses.
    private let dismissThreshold: CGFloat = 120
    /// Downward velocity (pt/s) past which a short drag still dismisses, so a
    /// quick flick throws the card off even before it has traveled far.
    private let dismissVelocity: CGFloat = 700
    /// Duration of the dismiss slide-off (and the upper bound on the
    /// velocity-derived slide). Bump to slow the dismiss, lower to quicken it.
    ///
    /// Note: there is deliberately no matching *opening* duration constant. The
    /// cover's open animation is `fullScreenCover`'s built-in system slide, whose
    /// duration can't be changed without replacing it with a custom transition —
    /// which isn't wanted here.
    private let dismissDuration: Double = 0.32

    init(
        items: [SpeciesPhotoItem],
        initialIndex: Int = 0,
        mapButtonTitle: String? = nil,
        onShowOnMap: ((SpeciesPhotoItem) -> Void)? = nil,
        onShowObservationOnMap: ((LifeListEntry.Observation) -> Void)? = nil
    ) {
        self.items = items
        self.mapButtonTitle = mapButtonTitle
        self.onShowOnMap = onShowOnMap
        self.onShowObservationOnMap = onShowObservationOnMap
        _scrolledID = State(initialValue: min(max(initialIndex, 0), max(items.count - 1, 0)))
    }

    /// Clamped current page.
    private var index: Int {
        min(max(scrolledID ?? 0, 0), max(items.count - 1, 0))
    }
    /// The bird the chrome (name, info panel) currently describes.
    private var currentItem: SpeciesPhotoItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    /// Fallback inset for a corner-tucked pill when the display's own corner
    /// radius cannot be read.
    private static let cornerPillFallbackInset: CGFloat = 20

    /// How far in from a display corner a `SpeciesChrome.cornerPillRadius` pill
    /// has to sit for its curve to be concentric with the display's own.
    ///
    /// Concentric corners share a centre, so the gap between them is constant:
    /// inset = display radius − pill radius. Read from the display at runtime
    /// rather than from a table of device corner radii — those go stale, and the
    /// last one in this project was deleted for that reason.
    private static func cornerInset(for displayRadii: RectangleCornerRadii?) -> CGFloat {
        guard let radius = displayRadii?.bottomTrailing,
              radius > SpeciesChrome.cornerPillRadius else {
            return cornerPillFallbackInset
        }
        return radius - SpeciesChrome.cornerPillRadius
    }

    /// Duration of the chrome show/hide fade. Short so tapping to reveal/hide the
    /// UI feels immediate (and so the auto-hide on zoom gets out of the way fast).
    private static let uiToggleDuration: Double = 0.12

    private func toggleUI() {
        // A slight drag that ends in a near-tap should not toggle the chrome — only
        // a genuine tap (no drag) should.
        guard !touchTracker.dragged else { return }
        withAnimation(.easeInOut(duration: Self.uiToggleDuration)) { uiVisible.toggle() }
    }

    /// Hides the chrome if it's showing — used when a zoom begins, so a zoomed-in
    /// photo is never cluttered by the bar or the info panel.
    private func hideUIForZoom() {
        guard uiVisible else { return }
        withAnimation(.easeInOut(duration: Self.uiToggleDuration)) { uiVisible = false }
    }

    /// Shows the chrome if it's hidden — used when the photo returns to minimum
    /// zoom, so zooming back out reveals the bar and info panel again
    /// (mirroring `hideUIForZoom`).
    private func revealUIAfterZoom() {
        guard !uiVisible else { return }
        withAnimation(.easeInOut(duration: Self.uiToggleDuration)) { uiVisible = true }
    }

    var body: some View {
        // Sizing is driven entirely off this *outer* GeometryReader's proxy,
        // which sits OUTSIDE `.ignoresSafeArea()` and is therefore rock-steady:
        // its `size` is the safe-area-inset rect (≈402×778) and its insets are
        // constant (top 62, bottom 34). The full-screen size we want is just that
        // rect grown by the insets, computed once as a CONSTANT.
        //
        // Why not let `.ignoresSafeArea()` + an inner GeometryReader report the
        // full height instead? Because during the swipe-to-dismiss drag the body
        // re-evaluates every frame, and the `.ignoresSafeArea()` *expansion* (the
        // +96pt that turns 778 into 874) destabilizes under that churn: the inner
        // GeometryReader's height ramps 874→778 and back, which centered the photo
        // against a moving height and jittered it vertically. Pinning an explicit
        // constant frame derived from the stable outer proxy removes the only
        // value that was changing, so the photo holds dead still as the card
        // slides. (Measured and confirmed: outer proxy steady, inner geo ramped.)
        NavigationStack {
        GeometryReader { proxy in
        // The full-screen size: the safe-area rect grown back by the insets on
        // every edge. Both are CONSTANTS off the stable outer proxy.
        //
        // The width grows by the leading and trailing insets *separately* rather
        // than assuming both are zero. A display that runs a system bar down one
        // side — a foldable's outer display, or its inner display in landscape —
        // has a nonzero inset on that edge only, and `proxy.size.width` there is
        // the narrower safe width; using it as the card width would leave this
        // "full-bleed" photo short of one screen edge. On a phone in portrait
        // both insets are 0 and this is exactly the old value.
        let fullWidth = proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
        let fullHeight = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        // The *safe* width, which caps the info panel so its text can never run
        // under a side bar. Distinct from `fullWidth` above by design.
        let contentWidth = proxy.size.width
        // How much room the viewer has. Not which display it is on and not
        // what pose the phone is in — see `DisplayLayout`.
        let layout = DisplayLayout(proxy)
        // The photo is grown to span the display only where there is a whole
        // large display to span. Anywhere else — a phone, a foldable's outer
        // display, one pane of a split — it rests inside the horizontal safe
        // area instead.
        let photoSpansDisplay = layout.photoSpansDisplay
        // How far in from each side the photo sits *at rest*.
        //
        // With the display to ourselves the photo spans the whole of it, passing
        // under the system's bar so the bar's buttons sit over the image — no
        // inset. Sharing the display — an ordinary phone, the outer display, one
        // pane of a split — it rests inside the horizontal safe area instead, so
        // nothing system-drawn crosses the picture.
        //
        // The inset is handed to the scroll view rather than applied as a frame
        // here, so it governs only the *resting* size: zoom in and the photo is
        // free to grow across the full width, under the bar. Given per edge and
        // never halved and mirrored, since the two are equal only when there is
        // no bar down either side. Mapped to physical left/right, because the
        // scroll view below works in physical coordinates while `safeAreaInsets`
        // is written leading/trailing and swaps under a right-to-left layout.
        let restingInsets: (left: CGFloat, right: CGFloat) = {
            guard !photoSpansDisplay else { return (0, 0) }
            let leading = proxy.safeAreaInsets.leading
            let trailing = proxy.safeAreaInsets.trailing
            return layoutDirection == .rightToLeft
                ? (left: trailing, right: leading)
                : (left: leading, right: trailing)
        }()
        let panelHugsCorner = layout.viewerChromeHugsCorners
        // The display's own corner radii, asked for the full-bleed rect rather
        // than the safe one: this proxy sits inside the safe area, so the
        // full-screen rect is its own grown back by its insets.
        let displayRadii: RectangleCornerRadii? = {
            guard #available(iOS 27.0, *) else { return nil }
            return proxy.concentricCornerRadii(
                in: CGRect(
                    x: -proxy.safeAreaInsets.leading,
                    y: -proxy.safeAreaInsets.top,
                    width: fullWidth,
                    height: fullHeight
                )
            )
        }()
        let cornerInset = Self.cornerInset(for: displayRadii)
        // Half the top safe area: the card-top travel at which the white status
        // bar flips, so it switches when the card is *halfway* through the safe
        // area rather than only once it has fully cleared it.
        let statusBarFlipPoint = proxy.safeAreaInsets.top / 2
        // Whether the card is still over the status bar, and so whether bar
        // contents should be light. Feeds the navigation bar's colour scheme,
        // which is what decides the status bar here — see the note there.
        let statusBarLight = cardCoveredStatusBar && dragOffset.height < statusBarFlipPoint
        // Outer container: ignores the safe area but is NEVER offset. The inner
        // card is what the dismiss drag translates, so the whole card — its top
        // edge over the status bar included — moves in lockstep with the finger,
        // instead of the safe-area extension staying pinned while the rest slides.
        ZStack {
        ZStack {
            // The black backdrop + the paged photos slide together with the
            // dismiss drag, revealing the app behind through the clear
            // presentation background.
            Color.black

            // Horizontal paging via a `UIPageViewController` (see `PhotoPager`),
            // not a SwiftUI ScrollView/TabView, for two reasons SwiftUI can't give
            // us: (1) its internal scroll view's `contentInsetAdjustmentBehavior`
            // is forced to `.never`, so the photo tracks the dismiss drag from the
            // first point instead of being pinned at the safe-area edge until the
            // card clears it; (2) it pages one bird per swipe and queues swipes
            // mid-animation — like the Photos app — rather than flinging across
            // several. `pageSpacing` shows the black backdrop as a gutter mid-swipe.
            PhotoPager(
                count: items.count,
                initialIndex: index,
                // Paging stays enabled while zoomed so a horizontal swipe can still
                // change birds (the zoomed page hands the swipe off to the pager at
                // its content edge — see `CenteringScrollView.gestureRecognizerShouldBegin`).
                // Only a downward dismiss locks paging out, so a diagonal close can't
                // also slide to the next bird.
                pagingDisabled: dismissEngaged,
                interPageSpacing: pageSpacing,
                pageTo: pageCommand,
                onIndexChange: { scrolledID = $0 },
                onSettledChange: { paging.swipeSettled = $0 },
                // A page is sized from these, and they settle a beat after the
                // viewer opens — the safe-area insets arrive with the second
                // layout pass. Without this the first bird kept the insets it was
                // built with (none), so it alone spanned the full width and ran
                // under a side bar, while every bird swiped to afterwards rested
                // inside the safe box correctly.
                pageInputs: PagePlacement(
                    spansDisplay: photoSpansDisplay,
                    left: restingInsets.left,
                    right: restingInsets.right
                )
            ) { i in
                ZoomablePhotoPage(
                    item: items[i],
                    paging: paging,
                    spansDisplay: photoSpansDisplay,
                    restingInsets: restingInsets,
                    onToggleUI: toggleUI,
                    onZoomChange: { zoomed in
                        // Only the current page's zoom gates paging.
                        if i == index {
                            if isZoomed != zoomed { isZoomed = zoomed }
                            if zoomed {
                                // Auto-hide the chrome the moment the photo is zoomed
                                // in at all, so nothing overlaps the magnified image.
                                hideUIForZoom()
                            } else {
                                // Back at minimum zoom: restore the chrome if a zoom
                                // had auto-hidden it.
                                revealUIAfterZoom()
                            }
                        }
                    },
                    onAtTopEdgeChange: { atTop in
                        // Track only the current page's top-edge state; it gates the
                        // zoomed swipe-to-dismiss.
                        if i == index { currentPageAtTopEdge = atTop }
                    },
                    onPageBeyondEdge: { direction in
                        // Only the current page drives the carry-over page turn.
                        guard i == index else { return }
                        let target = min(max(index + direction, 0), max(items.count - 1, 0))
                        guard target != index else { return }
                        pageCommand = PageCommand(index: target)
                    }
                )
            }
            .frame(width: fullWidth, height: fullHeight)

            // The bottom info panel — the one piece of chrome that is not a bar
            // item. It stays inside the offsetting card so it tracks the dismiss
            // drag 1:1, and is forced dark so its glass and text read as
            // immersive-viewer chrome from the first frame. Back, More and the
            // species name are navigation-bar items now.
            chrome(
                bottomInset: proxy.safeAreaInsets.bottom,
                leadingInset: proxy.safeAreaInsets.leading,
                trailingInset: proxy.safeAreaInsets.trailing,
                contentWidth: contentWidth,
                hugsCorner: panelHugsCorner,
                cornerInset: cornerInset
            )
                .opacity(uiVisible ? 1 : 0)
                .allowsHitTesting(uiVisible)
                .colorScheme(.dark)
        }
        // Pin the inner card to the constant full-screen size. Because the frame
        // is an explicit constant (not an ignoresSafeArea-expanded proposal), it
        // does NOT churn when the body re-evaluates during the drag.
        .frame(width: fullWidth, height: fullHeight)
        }
        // Pin the (un-offset) outer container to the same constant size and let it
        // ignore the safe area, so the inner card is always full-bleed.
        .frame(width: fullWidth, height: fullHeight)
        .ignoresSafeArea()
        // Keep the dismiss slide-off target in sync with the (stable) card size.
        .onChange(of: fullHeight, initial: true) { _, h in viewSize = CGSize(width: fullWidth, height: h) }
        // Swiping to a new bird starts it fresh: the incoming page is always built
        // at minimum zoom (the pager recreates pages, see `PhotoPager`), so clear
        // any lingering zoom state from the bird we left, and bring the chrome back
        // if a zoom on the previous bird had auto-hidden it (`hideUIForZoom`). Without
        // this the container's `isZoomed`/`uiVisible` stay stuck on the previous
        // page's values — the new, un-zoomed bird would otherwise show with its bar
        // and info panel still hidden.
        .onChange(of: index) { _, _ in
            if isZoomed { isZoomed = false }
            // A fresh page sits at its top content edge.
            currentPageAtTopEdge = true
            revealUIAfterZoom()
        }
        .opacity(contentOpacity)
        // Light-content (white) status bar exactly while the dark card is over the
        // status bar: only after the open slide settles it there, and only while
        // the dismiss drag hasn't pulled the card top past the halfway-through-the
        // -safe-area point (`statusBarFlipPoint`). Driven through a UIKit
        // controller with `.none` update animation so the flip is INSTANT —
        // tracking the card's edge as it covers/uncovers the bar (like Music),
        // rather than `.preferredColorScheme`'s unavoidable ~0.25s crossfade.
        // Flip the gate on once the present slide has brought the card up over the
        // bar, so opening doesn't whiten the status bar prematurely while the card
        // is still sliding up. Tuned to the default fullScreenCover slide.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                cardCoveredStatusBar = true
            }
            // Treat the card as "moving" until the open slide settles, so the
            // first bird's full-res download + swap is deferred until the card has
            // arrived — not run mid-animation. Tuned to the fullScreenCover slide.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                paging.opened = true
            }
        }
        // Clear presentation background so the slide reveals the app behind.
        .presentationBackground(.clear)
        // Vertical-down dismiss, recognized alongside (not blocking) `PhotoPager`'s
        // horizontal paging. Not gated on zoom: a zoomed photo still dismisses on
        // a downward drag *once it is at its top content edge* and can't be panned
        // any farther, matching the Photos app — see `currentPageAtTopEdge` and
        // the `guard` in `dismissDrag`.
        .simultaneousGesture(dismissDrag)
        // The "N Observations" list, and the edit flow it can raise. Presented
        // from the viewer itself so both open over the photo rather than making
        // it leave first.
        .sheet(isPresented: $showObservationList) {
            observationListSheet
        }
        // Everything the top-right menu can start.
        .observationActions(actions, store: lifeListStore)
        // A delete that leaves one sighting standing makes the list redundant —
        // the info panel goes back to printing that sighting's place and date —
        // so the sheet steps aside rather than sitting there titled
        // "1 Observations".
        .onChange(of: currentObservationCount) { _, count in
            if count < 2 { showObservationList = false }
        }
        // A viewer opened from a map pin stands for exactly one sighting. Delete
        // that sighting from the menu and there is nothing left for this screen
        // to be *of* — the pin behind it is already gone, and the chrome would go
        // on captioning the photo with a place and date that no longer describe
        // anything. Leave the same way the close button does, which also takes
        // the card down when this was opened over one (see `MapCardSheet`).
        .onChange(of: currentSightingWasDeleted) { _, deleted in
            if deleted { dismissViewer() }
        }
        // No navigation title: the name is a capsule of our own (`SpeciesNameCapsule`).
        // A title is text, and text does not go into a vertical bar — where the
        // system runs its bars down one side it keeps the title in a horizontal
        // strip across the top, and that strip draws a background this
        // `toolbarBackgroundVisibility(.hidden)` does not take off, dimming the
        // top of the photo. A capsule also rides the dismiss with the card, which
        // a bar title cannot.
        //
        // Immersive everywhere the system honours it: no material behind the bar,
        // so the photo runs under it.
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        // Light bar contents while the dark card is behind them — without this
        // the title takes the default label color, which a light appearance
        // renders black on black.
        //
        // This is also what drives the status bar. Wrapping the viewer in a
        // `NavigationStack` puts a `UINavigationController` between us and the
        // presentation controller, and a navigation controller answers the
        // status-bar question itself, off its bar's style — so a hard-coded
        // `.dark` here pinned the status bar to white for as long as the cover
        // was up. It stayed white over the app being revealed behind the card on
        // the way out (white on white, so invisible) and only corrected once the
        // cover was gone, which read as the bar snapping back a beat late.
        // Driving it from the same gate as the card hands the status bar back the
        // moment the card starts away.
        .toolbarColorScheme(statusBarLight ? .dark : nil, for: .navigationBar)
        // The same single tap that used to fade the floating chrome now takes the
        // whole bar with it, and a zoom still auto-hides it.
        .toolbar(uiVisible ? .visible : .hidden, for: .navigationBar)
        // Back and More are real bar items rather than glass circles we place
        // ourselves. Only system bar items take part when the system runs its
        // bars vertically — a foldable's outer display, and its inner display in
        // landscape — so this is what puts them on the same edge, at the same
        // positions, as every other screen's bar items, the Life List's filter
        // and import buttons included. It also hands the *choice* of edge to the
        // system: trailing when the app has the display, leading when it is the
        // left pane of a split.
        .toolbar {
            // Leading at the top of a vertical bar, per the platform's placement
            // for a back/close control.
            ToolbarItem(placement: .cancellationAction) {
                backButton
            }
            // The species name, placed by the system in the middle of the bar —
            // which is exactly between Back and More, on any display, with no
            // measuring on our part. A principal item rather than
            // `navigationTitle`, because a title is plain text: the system keeps
            // text in a horizontal strip when it runs its bars vertically, and
            // that strip draws a background nothing will take off. Dropped
            // entirely where the capsule has moved into a corner of its own.
            if !panelHugsCorner, let item = currentItem {
                ToolbarItem(placement: .principal) {
                    SpeciesNameCapsule(
                        name: commonName(for: item),
                        contentWidth: contentWidth
                    )
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let item = currentItem {
                    menuButton(for: item)
                }
            }
        }
        }
        }
        // Translate the WHOLE viewer — navigation bar included — for the
        // swipe-to-dismiss, so the bar's buttons travel with the black card
        // rather than hanging at the top of the screen until the card is gone.
        // The bar is drawn by a `UINavigationController` inside the stack and
        // cannot be offset from within, so the offset goes outside the stack.
        //
        // `.offset` is a render-time translation: it moves what is drawn without
        // re-proposing a size, so the `GeometryReader` inside still reports the
        // same rock-steady geometry it did before and the photo does not churn as
        // the card slides. A plain `.offset` rather than `visualEffect`, which
        // leaves the hosted photo's `UIScrollView` behind.
        .background(
            CardTranslation(
                offset: dragOffset.height,
                duration: cardSlideDuration,
                springs: cardSlideSprings
            )
        )
    }

    /// How many sightings the bird on screen has on record. Drives the
    /// auto-dismiss above; 0 for a map-opened viewer, which never shows the list.
    private var currentObservationCount: Int {
        guard let item = currentItem else { return 0 }
        return observations(for: item).count
    }

    /// The sighting a pin-scoped page stands for, *as it now stands* — the value
    /// the viewer was opened with, carried forward through any edit made from
    /// this screen (see `ObservationActions.current`). `nil` for a
    /// species-scoped item, which stands for no single sighting.
    ///
    /// Everything on this screen that acts on "the sighting under this photo"
    /// goes through here. `item.observation` is a copy captured when the viewer
    /// opened, and an edit gives the record a new date or place — so the raw
    /// copy stops matching anything on record, and using it would ask the store
    /// about a sighting that no longer exists.
    private func liveObservation(for item: SpeciesPhotoItem) -> LifeListEntry.Observation? {
        item.observation.map { actions.current($0) }
    }

    /// Every sighting the pin this page was opened from stands for, each carried
    /// forward through any edit made on this screen — the list Edit and Delete
    /// ask over. Empty for a species-scoped item, which has no pin.
    ///
    /// Followed through `ObservationActions.current` for the same reason
    /// `liveObservation` is, and it matters more here: `ObservationChoice`
    /// narrows the store's live list by `Identity`, so a pre-edit copy would
    /// filter the edited sighting straight out of the chooser it belongs in.
    private func livePinnedSightings(for item: SpeciesPhotoItem) -> [LifeListEntry.Observation] {
        item.pinnedSightings.map { actions.current($0) }
    }

    /// Whether the one sighting the current page stands for has been removed
    /// from the store. Only ever true for a pin-scoped item — a species-scoped
    /// one has the rest of its history to fall back on, and `SpeciesInfoPanel`
    /// handles it going empty. Always false with no store (previews).
    ///
    /// Asked of the *live* sighting, not the one the viewer opened with. An edit
    /// rewrites the record's date or place, which is what `Identity` is made of,
    /// so a raw-copy comparison read every edit as a deletion and shut the
    /// viewer the moment a user corrected a date — taking the map card under it
    /// down too.
    private var currentSightingWasDeleted: Bool {
        guard let item = currentItem,
              let observation = liveObservation(for: item),
              let store = lifeListStore else { return false }
        return !store.observations(for: item.scientificName)
            .contains { $0.identity == observation.identity }
    }

    /// Contents of the observation-list sheet. Only ever reachable with a store
    /// in the environment and more than one sighting on record — the row that
    /// opens it is drawn from exactly that.
    @ViewBuilder
    private var observationListSheet: some View {
        if let item = currentItem, let store = lifeListStore {
            let observations = observations(for: item)
            ObservationPickerSheet(
                title: "\(observations.count) Observations",
                observations: observations,
                // The sheet is deliberately *not* dismissed first: closing the
                // viewer takes the sheet standing on it down in the same
                // animation, so the two leave together instead of the list
                // sliding away and the photo following it a beat later.
                onSelect: { observation in
                    onShowObservationOnMap?(observation)
                },
                // A tap takes the sighting to the map, which needs a coordinate.
                // Rows without one stay plain rather than offering a dead tap.
                canSelect: { observation in
                    onShowObservationOnMap != nil && observation.hasCoordinate
                },
                onEdit: { observation in
                    listActions.edit(
                        scientificName: item.scientificName,
                        commonName: commonName(for: item),
                        observation: observation
                    )
                },
                onDelete: { observation in
                    listActions.delete(
                        scientificName: item.scientificName,
                        commonName: commonName(for: item),
                        observation: observation
                    )
                }
            )
            // Relayed onto the viewer's own `actions`, which is what
            // `liveObservation` / `livePinnedSightings` /
            // `currentSightingWasDeleted` resolve through. An edit made from this
            // list is an edit to a sighting the screen behind it may be holding
            // by value, and a trail written into the sheet's own object is a
            // trail nothing outside the sheet can read.
            .observationActions(listActions, store: store, onEdited: { original, replacement in
                actions.recordEdit(original: original, replacement: replacement)
            })
        }
    }

    // MARK: - Chrome

    /// What to call this bird in the menus and confirmations this screen raises.
    ///
    /// The life list's own name wins over the catalog's: an imported entry keeps
    /// eBird's wording, and a "Delete this X observation?" that quietly swapped in
    /// the catalog's name would be naming a different bird than the row the user
    /// came from. Falls back to the catalog for a species that isn't on the list
    /// yet (a search suggestion opened straight into the viewer), and to the
    /// scientific name if even that has nothing.
    private func commonName(for item: SpeciesPhotoItem) -> String {
        lifeListStore?.commonName(for: item.scientificName)
            ?? SpeciesCatalog.shared.commonName(for: item.scientificName)
            ?? item.scientificName
    }
    private func info(for item: SpeciesPhotoItem) -> SpeciesPhotoInfo? {
        SpeciesPhotoMetadata.shared.info(for: item.scientificName)
    }

    @ViewBuilder
    private func chrome(
        bottomInset: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        contentWidth: CGFloat,
        hugsCorner: Bool,
        cornerInset: CGFloat
    ) -> some View {
        Group {
            if let item = currentItem {
                // Tucked into the display's top-leading corner, mirroring the
                // info panel in the opposite one. Everywhere else the name is a
                // principal bar item instead, so the system centres it between
                // Back and More — see the `.toolbar` on the body.
                if hugsCorner {
                    SpeciesNameCapsule(
                        name: commonName(for: item),
                        contentWidth: contentWidth,
                        hugsCorner: true
                    )
                        .padding(.leading, cornerInset)
                        .padding(.top, cornerInset)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                }

                if hugsCorner {
                    // A wide display with the app to itself leaves a lot of empty
                    // picture between a bottom-centred panel and the controls up
                    // the side, so the panel tucks into the bottom-trailing
                    // corner instead, a constant in from both display edges.
                    // Measured from the display, not the safe area: the inset has
                    // to be the real distance from the corner for the panel's own
                    // corners to be concentric with it.
                    infoPanel(for: item, contentWidth: contentWidth, hugsCorner: true)
                        .padding(.trailing, cornerInset)
                        .padding(.bottom, cornerInset)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .bottomTrailing
                        )
                }

                else {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)

                        // Always shown: it carries the sighting place/date and the
                        // photo attribution — or, for a species we don't have a
                        // photo for yet, a "coming soon" notice in its place.
                        infoPanel(for: item, contentWidth: contentWidth, hugsCorner: false)
                            .padding(.bottom, bottomInset + 8)
                    }
                    // The chrome is interactive foreground content sitting in a
                    // full-bleed card, so it insets from each horizontal
                    // safe-area edge on its own. A symmetric inset would be wrong
                    // on any display whose leading and trailing insets differ (a
                    // system bar down one side), pushing the panel under the bar
                    // on that edge. Both are 0 on a phone in portrait, where this
                    // is a no-op.
                    .padding(.leading, leadingInset)
                    .padding(.trailing, trailingInset)
                }
            }
        }
    }

    /// Carries a title as well as a symbol: a bar item with only an image stays
    /// horizontal when the system lays its bars out vertically, and this one has
    /// to go into the vertical bar with the rest.
    private var backButton: some View {
        Button { dismissViewer() } label: {
            Label("Back", systemImage: "chevron.backward")
        }
    }

    /// Whether this screen has anywhere to send a "show me this on the map" tap.
    /// Either callback will do — see `showOnMap(_:observation:)`.
    private var canShowOnMap: Bool {
        onShowOnMap != nil || onShowObservationOnMap != nil
    }

    /// Sends the sighting under the current photo to the map.
    ///
    /// Prefers the sighting-scoped callback, which takes the record *by value*
    /// and so carries the coordinate as it now stands. `onShowOnMap` takes the
    /// item instead, leaving the host to resolve it back to whatever it was
    /// holding when the viewer opened — a map card's frozen `MapPoint`, or the
    /// species' earliest sighting — which an edit made from this screen has
    /// since moved. With no observation to hand over (a species-scoped item),
    /// the host's own resolution is the only answer there is, and the right one.
    private func showOnMap(_ item: SpeciesPhotoItem, observation: LifeListEntry.Observation?) {
        if let onShowObservationOnMap, let observation {
            onShowObservationOnMap(observation)
        } else {
            onShowOnMap?(item)
        }
    }

    /// Whether this bird has a sighting the menu could edit or delete. A map pin
    /// carries its own; a species-scoped item has to have something on record.
    private func hasSighting(_ item: SpeciesPhotoItem) -> Bool {
        guard let store = lifeListStore else { return false }
        if item.observation != nil { return true }
        return !store.observations(for: item.scientificName).isEmpty
    }

    /// Top-right menu for the current bird — the same actions every species row
    /// in the app offers, minus View Image, which is what this screen already
    /// is. Identical to `backButton` apart from position and glyph.
    private func menuButton(for item: SpeciesPhotoItem) -> some View {
        let starred = lifeListStore?.starredNames.contains(item.scientificName) ?? false
        let actionable = hasSighting(item)
        // Present whenever there is a store to write to, rather than only for a
        // bird with a sighting — see the note at the `star:` argument below.
        let starToggle: (isStarred: Bool, toggle: () -> Void)? = lifeListStore.map { store in
            (isStarred: starred, toggle: {
                // A single short tap to confirm the star toggled, matching the
                // Life List tab's star button.
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.setStarred(scientificName: item.scientificName, isStarred: !starred)
            })
        }
        return Menu {
            SpeciesRowMenu(
                onEdit: actionable ? { editSighting(of: item) } : nil,
                onAddObservation: {
                    actions.add(
                        scientificName: item.scientificName,
                        commonName: commonName(for: item)
                    )
                },
                // Offered for *any* species, on the life list or not — unlike
                // Edit and Delete above, which need a sighting to act on.
                //
                // This screen is the app's only unconditional star control, and
                // it has to be, because `starredNames` outlives the life-list
                // entry: deleting a species' last sighting drops its row but
                // deliberately keeps its star (see
                // `LifeListStore.removeObservation`), and every other star in the
                // app is drawn from an entry — the Life List's rows and its
                // starred-only filter, the map's pin menu, the Identify row menu
                // (gated on `alreadyAdded`). Gating this one too left such a bird
                // firing notifications on every walk with nowhere in the app to
                // turn them off. It is reachable here by searching the species in
                // the Life List tab and opening its photo.
                star: starToggle,
                onDelete: actionable ? { deleteSighting(of: item) } : nil
            )
        } label: {
            // Title as well as symbol, for the vertical bar — see `backButton`.
            // Never tinted for the star: this is a menu button, not a star
            // toggle, and coloring it made it read as a control whose state you
            // could change by tapping it, when tapping only opens a menu. The
            // star's own state is stated plainly inside that menu.
            Label("More actions", systemImage: "ellipsis")
        }
    }

    /// Edit from the menu.
    ///
    /// Three shapes, and the first is the one that used to be missing. A pin that
    /// covers several visits to one spot asks which of *those* is meant —
    /// `among:` acts outright when there is only one, so an ordinary lone pin is
    /// unchanged. A pin with no sightings recorded against it falls back to the
    /// single sighting it was opened with, and a species-scoped item asks over the
    /// bird's whole history.
    private func editSighting(of item: SpeciesPhotoItem) {
        guard let store = lifeListStore else { return }
        let pinned = livePinnedSightings(for: item)
        if !pinned.isEmpty {
            actions.edit(
                scientificName: item.scientificName,
                commonName: commonName(for: item),
                among: pinned
            )
        } else if let observation = liveObservation(for: item) {
            actions.edit(
                scientificName: item.scientificName,
                commonName: commonName(for: item),
                observation: observation
            )
        } else {
            actions.edit(
                scientificName: item.scientificName,
                commonName: commonName(for: item),
                in: store
            )
        }
    }

    /// Delete from the menu, the mirror of `editSighting` — and always one
    /// sighting, after a confirmation.
    private func deleteSighting(of item: SpeciesPhotoItem) {
        guard let store = lifeListStore else { return }
        let pinned = livePinnedSightings(for: item)
        if !pinned.isEmpty {
            actions.delete(
                scientificName: item.scientificName,
                commonName: commonName(for: item),
                among: pinned
            )
        } else if let observation = liveObservation(for: item) {
            actions.delete(
                scientificName: item.scientificName,
                commonName: commonName(for: item),
                observation: observation
            )
        } else {
            actions.delete(
                scientificName: item.scientificName,
                commonName: commonName(for: item),
                in: store
            )
        }
    }

    /// Every recorded sighting of this bird, newest first — but only for a
    /// species-scoped item (see `SpeciesPhotoItem.showsAllObservations`). A
    /// viewer opened from a map pin stands for that one sighting, so it keeps
    /// showing the place and date it was opened with instead.
    private func observations(for item: SpeciesPhotoItem) -> [LifeListEntry.Observation] {
        guard item.showsAllObservations else { return [] }
        return lifeListStore?.observations(for: item.scientificName) ?? []
    }

    /// Bottom details — the sighting and the photo attribution — in the shared
    /// glass panel (see `SpeciesInfoPanel`). This screen hands it everything it
    /// can act on: the sighting as it now stands after any edit made here, the
    /// list of every sighting the bird has, and the two actions only a
    /// presentation can offer — raising that list, and sending a sighting to
    /// the map.
    private func infoPanel(
        for item: SpeciesPhotoItem,
        contentWidth: CGFloat,
        hugsCorner: Bool
    ) -> some View {
        let recorded = observations(for: item)
        return SpeciesInfoPanel(
            item: item,
            observations: recorded,
            observation: liveObservation(for: item),
            // A bird with one sighting has nothing to list, and the panel
            // prints its place and date instead.
            onShowObservations: recorded.count > 1 ? { showObservationList = true } : nil,
            onShowOnMap: canShowOnMap ? { sighting in
                showOnMap(item, observation: sighting)
            } : nil,
            mapButtonTitle: mapButtonTitle,
            contentWidth: contentWidth,
            hugsCorner: hugsCorner
        )
    }

    // MARK: - Dismiss

    private var dismissDrag: some Gesture {
        // Measured in `.global` space, *not* the default `.local`: this gesture
        // lives on the same view that carries `.offset(dragOffset)`, so in local
        // space the coordinate system slides with the card as we offset it, and
        // the measured translation feeds back into the offset — a loop that
        // oscillates frame-to-frame and reads as a jitter during a slow drag.
        // Global space is fixed to the window, so translation tracks the finger
        // alone and the loop is broken.
        //
        // Small `minimumDistance` so a downward drag engages — and thereby
        // disables the pager (`PhotoPager(pagingDisabled: dismissEngaged)`, which
        // clears its scroll view's `isScrollEnabled`) — before the pager's own pan
        // threshold is crossed. Otherwise a diagonal close let the bird slide
        // sideways for the first few points before paging was locked out.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                // Any movement past this gesture's minimumDistance marks the touch as
                // a drag, so the photo's tap-to-toggle-chrome is suppressed for it
                // (see `toggleUI`). A pure tap never reaches `onChanged`, so it still
                // toggles.
                touchTracker.dragged = true
                // Dismiss is available when not zoomed (the whole card swipes), or
                // when zoomed but the photo is at its top edge so it can't be panned
                // any farther down — at which point a downward drag closes the card.
                guard !isZoomed || currentPageAtTopEdge else { return }
                if !dismissEngaged {
                    // Decide once, on the first qualifying frame: a downward,
                    // vertical-dominant drag engages dismiss. Horizontal goes to
                    // paging, and the upward "lift off the bottom" is disallowed.
                    guard value.translation.height > 0,
                          abs(value.translation.height) > abs(value.translation.width) else { return }
                    dismissEngaged = true
                    // The finger is driving from here: the card lands where it is
                    // this frame, with no animation of its own to lag behind.
                    cardSlideDuration = 0
                    // Anchor the card's travel to where the dismiss took over, so it
                    // starts from zero rather than jumping by any pan already consumed.
                    dismissEngageBaseline = value.translation.height
                }
                // Once engaged, track the finger's vertical travel directly
                // (clamped to downward) without re-checking dominance each frame.
                let travel = value.translation.height - dismissEngageBaseline
                dragOffset = CGSize(width: 0, height: max(travel, 0))
            }
            .onEnded { value in
                // Clear the drag mark on the next runloop so the tap fired by this
                // same touch-up (which must see `dragged == true` to be suppressed)
                // still does, while the following touch starts clean.
                DispatchQueue.main.async { touchTracker.dragged = false }
                let wasEngaged = dismissEngaged
                dismissEngaged = false
                // Only settle a drag we actually took over for dismiss; a zoomed pan
                // (or a horizontal page swipe) that never engaged is left alone.
                guard wasEngaged else { return }
                let travel = value.translation.height - dismissEngageBaseline
                let verticalDominant = abs(value.translation.height) > abs(value.translation.width)
                let pastThreshold = travel > dismissThreshold
                let flung = value.velocity.height > dismissVelocity
                if verticalDominant, travel > 0, pastThreshold || flung {
                    // Carry the release velocity through the slide-off so the
                    // throw doesn't snap to a different speed at lift-off.
                    dismissViewer(velocity: value.velocity.height)
                } else {
                    cardSlideSprings = true
                    cardSlideDuration = 0.3
                    dragOffset = .zero
                }
            }
    }

    /// Slides the whole card off the bottom — preserving the swipe-down feel —
    /// and cross-fades only in the final beat of the slide. The cover is then
    /// removed without its own animation so the slide is the only motion seen.
    ///
    /// `velocity` is the downward throw speed (pt/s) when dismissing from a
    /// swipe; the slide duration is derived from it so the card keeps moving at
    /// the speed the finger left it (no abrupt jump). The close button passes no
    /// velocity and gets a fixed, brisk slide tuned to match the cover's
    /// default open speed.
    private func dismissViewer(velocity: CGFloat? = nil) {
        // Hand the status bar back to the app behind *now*, as the card starts
        // away, rather than letting it stay white until the cover is torn down —
        // which read as the bar snapping dark a beat after the card had gone.
        //
        // Dropping the gate here covers both ways out. A drag already darkened
        // the bar on the way down, because `dragOffset` is written live on each
        // frame and the flip point is only half the top inset in; but a drag
        // released *below* that point, and the close button, never moved
        // `dragOffset` through it by hand — and an animated `dragOffset` is set
        // to its final value in the body immediately, so the condition alone
        // could not time the flip to the slide either way. The card clears the
        // status bar within the first few points of an ~800pt slide, so turning
        // it over at the start of the slide is the moment that matches.
        cardCoveredStatusBar = false

        let target = viewSize.height + 300
        let remaining = max(target - dragOffset.height, 1)

        let duration: Double
        if let velocity, velocity > 0 {
            // Time to cover the remaining distance at the release speed, eased
            // out so it decelerates into place rather than stopping dead.
            duration = min(max(Double(remaining / velocity), 0.16), dismissDuration)
        } else {
            duration = dismissDuration
        }

        cardSlideSprings = false
        cardSlideDuration = duration
        dragOffset = CGSize(width: 0, height: target)
        withAnimation(.easeIn(duration: 0.1).delay(max(duration - 0.1, 0))) {
            contentOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }
}

/// Slides the whole presented cover — navigation bar, photo and all — by
/// translating the cover's own view, rather than offsetting anything in SwiftUI.
///
/// A SwiftUI `.offset` on this screen cannot do it. The card is full-bleed by way
/// of `.ignoresSafeArea()`, and the instant an ancestor of that is offset SwiftUI
/// re-resolves the safe area underneath it: measured here, a **one point** drag
/// dropped the card 62pt and the reported top inset flipped 116 → 64 while the
/// content size churned 724 → 661 → 713. Offsetting only the inner card avoids
/// that but leaves the navigation bar behind, because the bar belongs to a
/// `UINavigationController` outside the offset. `.geometryGroup()` does not help.
///
/// A `CGAffineTransform` on the presented view controller's view moves every one
/// of those layers together and runs no layout at all, so there is nothing for
/// the safe area to be recomputed from and everything tracks the finger exactly.
private struct CardTranslation: UIViewRepresentable {
    /// How far down the card currently sits.
    var offset: CGFloat
    /// How it should get there: 0 while a finger is driving it (the card has to
    /// land on the finger's position this frame), otherwise the length of the
    /// animation that is carrying it. SwiftUI's own `withAnimation` cannot do
    /// this for us — it writes the state to its final value straight away, and
    /// the transform below would jump — so the motion is animated in UIKit.
    var duration: Double
    /// Whether that animation springs (the snap back from an abandoned drag) or
    /// eases out (the slide off on dismissal).
    var springs: Bool

    func makeUIView(context: Context) -> ProbeView { ProbeView() }

    func updateUIView(_ view: ProbeView, context: Context) {
        let wanted = offset == 0
            ? CGAffineTransform.identity
            : CGAffineTransform(translationX: 0, y: offset)
        // Straight through once the cover has been found, so a dragging finger is
        // never a frame behind. Only the first resolution waits for the next turn
        // of the runloop, because the probe is not in a window before then.
        if let target = view.resolvedCover {
            apply(wanted, to: target)
        }

        else {
            DispatchQueue.main.async {
                guard let target = view.coverView else { return }
                view.resolvedCover = target
                apply(wanted, to: target)
            }
        }
    }

    private func apply(_ transform: CGAffineTransform, to target: UIView) {
        guard target.layer.affineTransform() != transform else { return }
        guard duration > 0 else {
            // Straight on the layer rather than through `UIView.transform`:
            // setting the view's transform moves the view in the window, and
            // UIKit recomputes the safe area of a view that has moved. That is
            // what snapped the navigation bar down by the status bar's height on
            // the first point of a drag, and then had it creep instead of
            // travelling with the card. A layer transform changes only what is
            // drawn, so no layout — and no safe area — is recomputed.
            target.layer.setAffineTransform(transform)
            return
        }

        if springs {
            UIView.animate(
                withDuration: duration,
                delay: 0,
                usingSpringWithDamping: 0.85,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState]
            ) { target.layer.setAffineTransform(transform) }
        }

        else {
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) { target.layer.setAffineTransform(transform) }
        }
    }

    /// An invisible view whose only job is to find the cover it is inside.
    final class ProbeView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// Cached once found, so the common path costs no runloop hop.
        var resolvedCover: UIView?

        /// The presented cover's own view — the top of the chain of controllers
        /// this probe sits in, which is the one the system slides on and off.
        var coverView: UIView? {
            var responder: UIResponder? = self
            while let current = responder, !(current is UIViewController) {
                responder = current.next
            }
            guard var controller = responder as? UIViewController else { return nil }
            while let parent = controller.parent { controller = parent }
            return controller.viewIfLoaded
        }
    }
}

/// Horizontal photo pager backed by `UIPageViewController` (scroll transition).
/// Chosen over SwiftUI's ScrollView/TabView because it gives us two things they
/// don't: the internal paging scroll view's `contentInsetAdjustmentBehavior` is
/// pinned to `.never` (so the photo isn't shoved by the safe-area inset while the
/// dismiss drag offsets the card), and it pages exactly one item per swipe while
/// still accepting queued swipes mid-animation, like the Photos app. A fresh page
/// view controller is built each time one scrolls in, so pages are never left
/// zoomed and images come straight from the in-memory cache.
struct PhotoPager<Page: View>: UIViewControllerRepresentable {
    let count: Int
    let initialIndex: Int
    let pagingDisabled: Bool
    let interPageSpacing: CGFloat
    /// A programmatic page-turn request (carry-over from a zoomed edge drag). Each
    /// fresh `id` triggers one animated turn in `updateUIViewController`.
    var pageTo: PageCommand? = nil
    let onIndexChange: (Int) -> Void
    /// Reports whether the pager is settled (true) or mid-swipe (false). Used to
    /// hold each page's full-resolution swap until the motion stops.
    var onSettledChange: ((Bool) -> Void)? = nil
    /// The swipe as it happens: the page it started from, and how far it has
    /// travelled — −1 to 1, negative toward the previous page, 0 at rest.
    ///
    /// `onIndexChange` already says *which* page a swipe has committed to, but
    /// it says it once, halfway across. Anything that has to move with the
    /// finger rather than snap when it lands — the pane's card takes its colour
    /// from the bird, and the colour crosses over as the picture does — needs
    /// the whole of the travel.
    var onSwipeProgress: ((_ from: Int, _ fraction: CGFloat) -> Void)? = nil
    /// Everything a built page captured that can still change after it was built.
    /// A page is a snapshot taken by `makeHost` when it scrolled in, and nothing
    /// pushed a later value into one — so whichever page was on screen when such
    /// a value settled went on showing the old one, while every page scrolled to
    /// afterwards was built correctly. Changing this rebuilds the page on screen.
    var pageInputs: AnyHashable = 0
    @ViewBuilder var page: (Int) -> Page

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: interPageSpacing]
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear

        let start = min(max(initialIndex, 0), max(count - 1, 0))
        pvc.setViewControllers([context.coordinator.makeHost(start)], direction: .forward, animated: false)
        context.coordinator.currentIndex = start
        context.coordinator.lastReportedIndex = start

        // Stop the internal scroll view from insetting its content for the safe
        // area — that adjustment pinned the photo at the safe-area edge until the
        // dismiss-dragged card cleared it, then snapped it down. `.never` keeps the
        // photo in lockstep with the card from the first point. Deferred because
        // the scroll view isn't in the hierarchy yet during `make`.
        DispatchQueue.main.async {
            guard let scrollView = context.coordinator.pagingScrollView(in: pvc) else { return }
            scrollView.contentInsetAdjustmentBehavior = .never
            // Report the index switch as soon as the swipe crosses the halfway
            // point, rather than waiting for `didFinishAnimating` (full settle).
            context.coordinator.observeOffset(of: scrollView, in: pvc)
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // Re-render the page on screen when what it was built from has changed.
        // Gated on a change rather than run every pass: this is re-entered on
        // every frame of the dismiss drag, and rehosting each one would be a
        // needless SwiftUI update per frame.
        if context.coordinator.lastPageInputs != pageInputs {
            context.coordinator.lastPageInputs = pageInputs
            if let host = pvc.viewControllers?.first as? IndexedHost<Page> {
                host.rootView = page(host.index)
            }
        }
        // Cancels an in-progress paging pan the instant a dismiss engages.
        context.coordinator.pagingScrollView(in: pvc)?.isScrollEnabled = !pagingDisabled
        // Carry-over page turn from a zoomed edge drag: act on each fresh command.
        if let pageTo, context.coordinator.lastHandledCommandID != pageTo.id {
            context.coordinator.lastHandledCommandID = pageTo.id
            context.coordinator.goTo(pageTo.index, in: pvc)
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PhotoPager
        /// The settled page (updated only by `didFinishAnimating`). The halfway
        /// switch measures the live swipe relative to this.
        var currentIndex = 0
        /// Last index handed up via `onIndexChange`, so a single swipe reports the
        /// switch once (when it crosses halfway) and not on every offset tick.
        var lastReportedIndex = 0
        /// Last settled state handed up via `onSettledChange`, so it only fires on
        /// a transition (mid-swipe ↔ stopped) rather than every offset tick.
        private var lastReportedSettled = true
        private var offsetObservation: NSKeyValueObservation?
        /// The last carry-over page command acted on, so each fresh command turns
        /// the page exactly once.
        var lastHandledCommandID: UUID?

        init(_ parent: PhotoPager) {
            self.parent = parent
            self.lastPageInputs = parent.pageInputs
        }

        /// The `pageInputs` the page on screen was last built from.
        var lastPageInputs: AnyHashable

        /// Programmatically turns the pager to `index` with the standard scroll
        /// animation. Used for the carry-over turn when a zoomed pan is dragged
        /// past the photo's edge — `didFinishAnimating` is *not* called for
        /// programmatic transitions, so the bookkeeping (`currentIndex`,
        /// `lastReportedIndex`, `onIndexChange`) is updated here directly.
        func goTo(_ index: Int, in pvc: UIPageViewController) {
            let clamped = min(max(index, 0), max(parent.count - 1, 0))
            guard clamped != currentIndex else { return }
            let direction: UIPageViewController.NavigationDirection =
                clamped > currentIndex ? .forward : .reverse
            pvc.setViewControllers([makeHost(clamped)], direction: direction, animated: true)
            currentIndex = clamped
            parent.onSwipeProgress?(clamped, 0)
            if lastReportedIndex != clamped {
                lastReportedIndex = clamped
                parent.onIndexChange(clamped)
            }
        }

        /// Reports a settled-state transition up to the viewer, de-duped.
        private func reportSettled(_ settled: Bool) {
            guard settled != lastReportedSettled else { return }
            lastReportedSettled = settled
            parent.onSettledChange?(settled)
        }

        /// Watch the paging scroll view's offset, and read the pager's position
        /// off the pages themselves: which one is under the middle of the
        /// viewport, and how far the next one along has come.
        ///
        /// **Why the pages and not the offset.** The obvious reading is
        /// arithmetic — the scroll view rests with the current page centred at
        /// `contentOffset.x == bounds.width`, so the signed distance past that,
        /// over the width, is how far the swipe has travelled. It is wrong in
        /// three places, and all three showed.
        ///
        /// It needs a page it can call "current", and the only one available
        /// (`currentIndex`) is not updated until the transition *finishes*. A
        /// second swipe started before the first has landed — which is what
        /// moving more than one bird means — is therefore measured from a page
        /// that is already behind, and the whole reading is off by one: the
        /// wrong bird reported, the wrong two colours mixed.
        ///
        /// It assumes the current page rests at `width`, which is only true
        /// with a page on either side of it. At the ends of the list there is
        /// no page on one side, the content is two pages rather than three, and
        /// the arithmetic reads a permanent whole-page offset that is not
        /// there.
        ///
        /// And it is recentred at every page boundary, *before* the transition
        /// is declared finished — so between those two moments it reads "at
        /// rest, on the page this swipe started from", and anything following
        /// it snaps back a bird each time one goes by.
        ///
        /// Asking the pages where they are has none of those problems: they are
        /// laid out at their real positions whatever the pager believes, at
        /// both ends and mid-transition alike.
        ///
        /// We KVO the offset rather than become the scroll view's delegate,
        /// which `UIPageViewController` owns internally.
        func observeOffset(of scrollView: UIScrollView, in pvc: UIPageViewController) {
            offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) {
                [weak self, weak pvc] scrollView, _ in
                guard let self, let pvc,
                      let position = self.position(in: scrollView, of: pvc) else { return }
                self.parent.onSwipeProgress?(position.index, position.fraction)
                // Mid-swipe whenever the nearest page is off centre, which it
                // is for the whole of a drag and at no other time.
                self.reportSettled(abs(position.fraction) < 0.001)
                let clamped = min(max(position.index, 0), max(self.parent.count - 1, 0))
                guard clamped != self.lastReportedIndex else { return }
                self.lastReportedIndex = clamped
                self.parent.onIndexChange(clamped)
            }
        }

        /// Where the pager is: the page nearest the middle of the viewport, and
        /// how far past it the swipe has carried, as a share of one page's
        /// pitch (−1 to 1, negative toward the previous page).
        ///
        /// The nearest page rather than the one under the centre, which is the
        /// same thing away from the boundaries and better defined at them: the
        /// index changes over exactly halfway between two pages, and the
        /// fraction passes through ±0.5 as it does, so the pair either side of
        /// the change describe the same position.
        private func position(
            in scrollView: UIScrollView,
            of pvc: UIPageViewController
        ) -> (index: Int, fraction: CGFloat)? {
            let pages = pvc.children
                .compactMap { $0 as? IndexedHost<Page> }
                .filter { $0.view.superview != nil }
                .map { (index: $0.index, midX: $0.view.convert($0.view.bounds, to: scrollView).midX) }
                .sorted { $0.midX < $1.midX }
            guard let first = pages.first else { return nil }
            let centre = scrollView.contentOffset.x + scrollView.bounds.width / 2
            // Measured between two laid-out pages where there are two, so it
            // is the real pitch — page width plus the gutter — rather than an
            // assumption about either.
            let pitch = pages.count > 1
                ? pages[1].midX - first.midX
                : scrollView.bounds.width + parent.interPageSpacing
            guard pitch > 0 else { return nil }
            let nearest = pages.min { abs($0.midX - centre) < abs($1.midX - centre) } ?? first
            let fraction = (centre - nearest.midX) / pitch
            return (nearest.index, min(max(fraction, -1), 1))
        }

        deinit { offsetObservation?.invalidate() }

        func makeHost(_ index: Int) -> IndexedHost<Page> {
            let host = IndexedHost(rootView: parent.page(index))
            host.index = index
            host.view.backgroundColor = .clear
            return host
        }

        func pagingScrollView(in pvc: UIPageViewController) -> UIScrollView? {
            pvc.view.subviews.compactMap { $0 as? UIScrollView }.first
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let host = vc as? IndexedHost<Page>, host.index > 0 else { return nil }
            return makeHost(host.index - 1)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let host = vc as? IndexedHost<Page>, host.index < parent.count - 1 else { return nil }
            return makeHost(host.index + 1)
        }

        func pageViewController(
            _ pvc: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            // The transition animation has finished (settled or snapped back),
            // so the pager is at rest — backstop the offset-driven settled report.
            reportSettled(true)
            // Un-zoom the page we just left. UIPageViewController keeps the
            // outgoing page alive as the new neighbor (it doesn't rebuild it), so a
            // bird zoomed in before a swipe would otherwise still be zoomed when you
            // swipe back to it. Resetting here — while it's offscreen — is invisible.
            // Exclude whatever is *currently* displayed: an aborted swipe (snap-back)
            // lists the page you stayed on in `previousViewControllers`, and resetting
            // it would un-zoom the bird you're still looking at.
            let current = pvc.viewControllers ?? []
            for vc in previousViewControllers where !current.contains(vc) {
                Self.resetZoom(in: vc)
            }
            guard completed, let host = pvc.viewControllers?.first as? IndexedHost<Page> else { return }
            currentIndex = host.index
            // The offset observer's last word was "at rest" against the page
            // the swipe *started* from — it recentres before the transition is
            // declared finished — so anything tracking the swipe would be left
            // holding the old page. Say it again now the settled page is known.
            parent.onSwipeProgress?(host.index, 0)
            // The halfway observer has usually already reported this index; keep
            // both in sync so the next swipe measures from the settled page and
            // an aborted swipe (snap-back) still re-reports correctly.
            if lastReportedIndex != host.index {
                lastReportedIndex = host.index
                parent.onIndexChange(host.index)
            }
        }

        /// Walks a hosted page's view tree to its `CenteringScrollView` and resets
        /// it to minimum zoom (re-fitting so it's centered). Used to clear the zoom
        /// of a page the pager has scrolled away from but kept mounted.
        static func resetZoom(in viewController: UIViewController) {
            func findScroll(_ view: UIView) -> CenteringScrollView? {
                if let scroll = view as? CenteringScrollView { return scroll }
                for subview in view.subviews {
                    if let found = findScroll(subview) { return found }
                }
                return nil
            }
            guard let scroll = findScroll(viewController.view),
                  scroll.zoomScale != scroll.minimumZoomScale else { return }
            scroll.setZoomScale(scroll.minimumZoomScale, animated: false)
            scroll.refit()
        }
    }
}

/// `UIHostingController` that remembers which page index it hosts, so the pager's
/// data source can walk to the neighboring index.
final class IndexedHost<Content: View>: UIHostingController<Content> {
    var index = 0
}

/// A single zoomable page within the viewer: just the photo (pinch + pan +
/// double-tap zoom, all driven by a `UIScrollView`). All chrome (name, back
/// button, info panel) lives once in the container over the current page. Reports
/// its zoom state up via `onZoomChange` so the container can disable paging while
/// zoomed. The pager creates a fresh page each time one scrolls into view, so a
/// page is never left zoomed.
/// One bird's photo, zoomable, on the viewer's black card. Also the whole of
/// the Identify tab's half-screen species view (`HalfScreenSpeciesView`), which
/// is why this is not private.
struct ZoomablePhotoPage: View {
    let item: SpeciesPhotoItem
    /// Shared paging state — the page holds its full-resolution swap until this
    /// reports the swipe has settled, so the heavier image never swaps in while
    /// the user is still swiping between birds.
    let paging: ViewerPaging
    /// Whether the photo starts grown to span the display's full width rather
    /// than fitted whole inside the page. See `SpeciesPhotoFullScreen`.
    let spansDisplay: Bool
    /// How far in from the page's left and right the photo rests. Zoom is free
    /// to carry it past these. See `CenteringScrollView.restingInsets`.
    let restingInsets: (left: CGFloat, right: CGFloat)
    /// Toggles the chrome's visibility; fired by a single tap on the photo.
    var onToggleUI: () -> Void
    /// Reports this page's zoom state up to the container.
    var onZoomChange: (Bool) -> Void
    /// Reports whether the zoomed photo is at its top content edge (can't be
    /// panned farther down), which the container uses to allow a swipe-to-dismiss
    /// while zoomed.
    var onAtTopEdgeChange: (Bool) -> Void
    /// Fired when a zoomed horizontal pan is dragged past the photo's left/right
    /// content edge (`-1` previous, `+1` next), so the same continuous swipe
    /// carries on to the neighboring bird instead of halting at the edge.
    var onPageBeyondEdge: (Int) -> Void
    /// Whether a letterboxed photo sits in the top-leading corner of the page
    /// rather than in the middle of it. See
    /// `CenteringScrollView.anchorsTopLeading`.
    var anchorsTopLeading: Bool = false
    /// Rounds the picture's own corners, rather than the page it sits in. See
    /// `CenteringScrollView.photoCornerRadius`.
    var photoCornerRadius: CGFloat = 0

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var pageZoomed = false
    /// True once the full-resolution image has been shown (or was already
    /// resident), so the deferred download isn't kicked off again.
    @State private var fullResLoaded = false
    /// The in-flight full-resolution download, so it can be cancelled if the page
    /// scrolls away before it finishes.
    @State private var fullResTask: Task<Void, Never>?
    /// Whether a full-resolution download is under way, set *before* the task is
    /// created and cleared when it finishes.
    ///
    /// The gate used to be `fullResTask == nil`, cleared from a `defer` inside the
    /// task — which is an ordering the language doesn't guarantee: a body that
    /// returned before its first suspension would run that `defer` before
    /// `fullResTask` had been assigned, leaving a stale handle that no later
    /// settle could get past. A flag written on this side of the task can't race
    /// its own assignment.
    @State private var fullResInFlight = false

    var body: some View {
        imageLayer
            // The page is the size its container gives it and nothing else.
            // Left to respect the safe area it subtracts the bars from that
            // box a second time — the container has already placed itself
            // clear of them — and the picture is fitted into, and anchored to,
            // a box that is a status bar short. The half-screen pane is where
            // that showed: full-bleed against the glass, its photograph came to
            // rest 74pt down from a corner it was meant to start in.
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .task(id: item.scientificName) { await load() }
            .onChange(of: pageZoomed) { _, zoomed in onZoomChange(zoomed) }
            // Both the full-res *download* and its swap wait for the viewer to come
            // to a full stop (card opened + no swipe in motion), so the heavier work
            // never lands while anything is animating. Kick it off the moment things
            // settle.
            .onChange(of: paging.settled) { _, settled in
                if settled { startFullResIfNeeded() }
            }
            .onDisappear { fullResTask?.cancel() }
    }

    /// Starts the deferred full-resolution download — but only once the viewer has
    /// settled (card fully open and no swipe in motion), the medium image is up, and
    /// it hasn't already loaded. The download itself is held until then, not just
    /// the swap, so no full-res network/decoding competes with the animation.
    private func startFullResIfNeeded() {
        guard paging.settled, !fullResLoaded, !fullResInFlight, image != nil else { return }
        let name = item.scientificName
        fullResInFlight = true
        // Assigned from out here, not inside the body: this method and the task
        // are both main-actor isolated, so the assignment is guaranteed to land
        // before the body can run and the handle can never be missed.
        let task = Task {
            let full = await RemoteSpeciesImageStore.shared.fullResolutionImage(for: name)
            // **Cancellation is checked before the clears, not after.**
            // `fullResolutionImage` has no cancellation point of its own, so a
            // cancelled download still runs to completion and resumes here — by
            // which time `load()` has already cleared both of these *and* may
            // have started a newer download for the bird now on screen. Clearing
            // them here would nil that task's handle (leaving `onDisappear` with
            // nothing to cancel) and claim nothing was in flight, so the next
            // settle would start a second full-resolution download — several
            // megabytes — of a photo already being fetched. There is nothing to
            // clean up either way: `load()` did it.
            guard !Task.isCancelled else { return }
            fullResInFlight = false
            fullResTask = nil
            // Settled may have changed during the download (e.g. a new swipe began);
            // only swap while still settled, otherwise the next settle re-runs this.
            guard let full, paging.settled else { return }
            image = full
            fullResLoaded = true
        }
        fullResTask = task
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let image {
            ZoomableImageView(
                image: image,
                isZoomed: $pageZoomed,
                spansDisplay: spansDisplay,
                restingInsets: restingInsets,
                anchorsTopLeading: anchorsTopLeading,
                photoCornerRadius: photoCornerRadius,
                resetToken: 0,
                onSingleTap: onToggleUI,
                onAtTopEdgeChange: onAtTopEdgeChange,
                onPageBeyondEdge: onPageBeyondEdge
            )
        } else if loadFailed {
            // No photo exists for this species yet (or one failed to load) — a
            // centered bird-glyph placeholder. It fills the page and lives inside
            // the paged, offsetting card, so it tracks the swipe-to-dismiss drag
            // 1:1 exactly like a real photo does.
            Image(systemName: "bird")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().tint(.white)
        }
    }

    // MARK: - Loading

    private func load() async {
        fullResTask?.cancel()
        fullResTask = nil
        // Cleared alongside the handle: a cancelled download's own clear may never
        // run, and leaving this set would block the new bird's full-res load.
        fullResInFlight = false
        image = nil
        loadFailed = false
        fullResLoaded = false
        let name = item.scientificName

        // No photo exists for this species (no remote metadata) — show the
        // bird-glyph placeholder immediately, skipping the pointless network
        // round-trip and the loading spinner that a real photo would need.
        guard SpeciesPhotoMetadata.shared.info(for: name) != nil else {
            loadFailed = true
            return
        }

        // Already have the true full-res image resident (a previous open this
        // session): show it straight away, no download or swap needed.
        if let full = RemoteSpeciesImageStore.shared.memoryFullResolutionImage(for: name) {
            image = full
            fullResLoaded = true
            return
        }

        // Show the medium image first (instant from memory if cached) so the photo
        // appears immediately. The full-resolution download is deferred until the
        // viewer settles (see `startFullResIfNeeded`), so it never competes with the
        // open slide or a swipe.
        if let mem = RemoteSpeciesImageStore.shared.memoryImage(for: name) {
            image = mem
        } else {
            let loaded = await RemoteSpeciesImageStore.shared.image(for: name)
            guard !Task.isCancelled else { return }
            image = loaded
            loadFailed = loaded == nil
        }

        guard image != nil else { return }
        // If we're already settled (e.g. opening straight onto this page after the
        // slide), start the full-res download now; otherwise `onChange(paging.settled)`
        // will kick it off the moment motion stops.
        startFullResIfNeeded()
    }
}

// MARK: - UIScrollView-backed zoomable image

/// Pinch-to-zoom + pan image, backed by a `UIScrollView` so the zoom is the
/// system's own — buttery on any device (no custom per-frame pinch math, which
/// previously tanked performance), pinches about the live midpoint anywhere on
/// the image, and rubberbands past the min/max scale. Pan is hard-clamped to the
/// image edges (no overscroll past them, in either axis), and a single haptic
/// fires when a pinch pushes past the max or below the min, matching Photos.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool
    /// Whether the resting size is "as wide as the page" rather than "wholly
    /// inside the page". See `CenteringScrollView.spansWidth`.
    var spansDisplay: Bool = false
    /// Horizontal inset the photo rests inside; zoom carries it past these.
    var restingInsets: (left: CGFloat, right: CGFloat) = (0, 0)
    /// Whether a letterboxed photo sits in the top-leading corner rather than
    /// in the middle. See `CenteringScrollView.anchorsTopLeading`.
    var anchorsTopLeading: Bool = false
    /// Rounds the picture itself. See `CenteringScrollView.photoCornerRadius`.
    var photoCornerRadius: CGFloat = 0
    /// Changing this asks the scroll view to ease back to fit (page scrolled off).
    var resetToken: Int
    /// Fired by a single tap on the photo (toggles the viewer's chrome). Requires
    /// the double-tap-to-zoom to fail first, so a zoom double-tap doesn't also
    /// toggle the chrome.
    var onSingleTap: () -> Void
    /// Reports whether the (zoomed) content is at its top edge — i.e. it can't be
    /// panned any farther down. The container uses this to allow swipe-to-dismiss
    /// while zoomed.
    var onAtTopEdgeChange: (Bool) -> Void = { _ in }
    /// Fired when a zoomed horizontal pan has been dragged past the left/right
    /// content edge (`-1` previous, `+1` next), so the container can carry the same
    /// swipe on to the neighboring bird.
    var onPageBeyondEdge: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CenteringScrollView {
        let scroll = CenteringScrollView()
        scroll.spansWidth = spansDisplay
        scroll.restingInsets = restingInsets
        scroll.anchorsTopLeading = anchorsTopLeading
        scroll.photoCornerRadius = photoCornerRadius
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true
        // No pan overscroll — the image can't be dragged away from its edges.
        scroll.bounces = false
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = false
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        scroll.decelerationRate = .fast

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.layer.cornerCurve = .continuous
        imageView.layer.cornerRadius = photoCornerRadius
        imageView.clipsToBounds = photoCornerRadius > 0
        scroll.imageView = imageView
        scroll.addSubview(imageView)
        context.coordinator.scrollView = scroll

        // Watch the scroll view's pinch recognizer directly so the boundary
        // haptic can fire at finger-lift rather than after the bounce settles.
        scroll.pinchGestureRecognizer?.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )

        // Watch the scroll view's own pan recognizer so a zoomed horizontal drag
        // that reaches the content edge can carry on to the next/previous bird
        // within the same gesture (the carry-over page turn) instead of halting.
        scroll.panGestureRecognizer.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        // Two single-tap recognizers, distinguished by where the tap lands (see
        // the coordinator's `shouldReceive` delegate):
        //  • On the photo itself — must wait for the double-tap-to-zoom to fail,
        //    so a zoom double-tap doesn't also toggle the chrome.
        //  • On the black letterbox background (outside the image) — fires
        //    immediately with no double-tap dependency, so toggling the chrome by
        //    tapping the backdrop feels instant rather than waiting out the
        //    double-tap window.
        let imageTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        imageTap.numberOfTapsRequired = 1
        imageTap.name = Coordinator.imageTapName
        imageTap.delegate = context.coordinator
        imageTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(imageTap)

        let backgroundTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        backgroundTap.numberOfTapsRequired = 1
        backgroundTap.name = Coordinator.backgroundTapName
        backgroundTap.delegate = context.coordinator
        scroll.addGestureRecognizer(backgroundTap)

        return scroll
    }

    func updateUIView(_ scroll: CenteringScrollView, context: Context) {
        context.coordinator.parent = self
        if scroll.photoCornerRadius != photoCornerRadius {
            scroll.photoCornerRadius = photoCornerRadius
        }
        // The resting insets move when the display does — a rotation, or a split
        // being resized — so re-fit to the new box when they change.
        if scroll.restingInsets != restingInsets || scroll.spansWidth != spansDisplay {
            scroll.restingInsets = restingInsets
            scroll.spansWidth = spansDisplay
            scroll.anchorsTopLeading = anchorsTopLeading
            scroll.refit()
        }
        if scroll.imageView?.image !== image {
            let previous = scroll.imageView?.image
            scroll.imageView?.image = image
            // A full-res swap of the *same* photo has an identical aspect ratio, so
            // keep the current fitted frame (and any in-progress zoom/pan) instead of
            // re-fitting — `refit()` resets the zoom to 1. Only re-fit when the aspect
            // ratio actually changed, i.e. a genuinely different image.
            if !Self.sameAspectRatio(previous, image) {
                scroll.refit()
            }
        }
        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            if scroll.zoomScale != scroll.minimumZoomScale {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: false)
                scroll.refit()
            }
        }
    }

    /// Whether two images share the same aspect ratio (within a small tolerance).
    /// `nil` previous → false (a first set must fit). Used to decide whether a
    /// background full-res swap can keep the current fit (same ratio) or needs a
    /// re-fit (a different photo).
    private static func sameAspectRatio(_ a: UIImage?, _ b: UIImage?) -> Bool {
        guard let a, let b,
              a.size.width > 0, a.size.height > 0,
              b.size.width > 0, b.size.height > 0 else { return false }
        let ra = a.size.width / a.size.height
        let rb = b.size.width / b.size.height
        return abs(ra - rb) < 0.01
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        /// Names distinguishing the on-image vs. on-background single-tap
        /// recognizers in the `shouldReceive` delegate.
        static let imageTapName = "kestrel.imageTap"
        static let backgroundTapName = "kestrel.backgroundTap"

        var parent: ZoomableImageView
        weak var scrollView: CenteringScrollView?
        var lastResetToken: Int
        /// Set true if a pinch pushed the scale past the max or below the min at
        /// any point during the gesture; the boundary haptic then fires once when
        /// the pinch *ends*, not at the instant the threshold is crossed.
        private var didExceedLimit = false
        private let haptic = UIImpactFeedbackGenerator(style: .rigid)
        /// Last reported top-edge state, so `onAtTopEdgeChange` only fires on a
        /// change. Starts true (a fresh, un-scrolled page sits at its top).
        private var lastAtTopEdge = true
        /// True once a single pan gesture has already triggered a carry-over page
        /// turn, so one continuous drag past the edge turns the page exactly once.
        private var pageTriggeredThisGesture = false

        init(_ parent: ZoomableImageView) {
            self.parent = parent
            self.lastResetToken = parent.resetToken
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? CenteringScrollView)?.imageView
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            pushAtTopEdge(scrollView)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? CenteringScrollView)?.centerContent()

            // Boundary detection: while a pinch is actively driving the scale
            // past a limit, just remember that it happened. The haptic is held
            // back until the pinch ends so it fires on release, not at the
            // moment the threshold is crossed.
            let state = scrollView.pinchGestureRecognizer?.state
            let pinching = state == .began || state == .changed
            if pinching,
               scrollView.zoomScale > scrollView.maximumZoomScale + 0.001
                || scrollView.zoomScale < scrollView.minimumZoomScale - 0.001 {
                didExceedLimit = true
            }
            pushZoomed(scrollView)
            pushAtTopEdge(scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            // Fires after the rubber-band settle, not at finger lift, so the
            // boundary haptic is NOT triggered here — it's driven off the pinch
            // recognizer's `.ended` state instead (see `handlePinch`).
            (scrollView as? CenteringScrollView)?.centerContent()
            pushZoomed(scrollView)
            pushAtTopEdge(scrollView)
        }

        /// Reports whether the content is at its top edge — it can't be panned any
        /// farther down — so the container can allow a swipe-to-dismiss while
        /// zoomed. Only meaningful while zoomed; when not zoomed the container's
        /// own (un-zoomed) swipe-down handles dismissal regardless. Fired on a
        /// change, off the layout pass like `pushZoomed`.
        private func pushAtTopEdge(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            let atTop = scrollView.contentOffset.y <= -scrollView.contentInset.top + 0.5
            let value = zoomed ? atTop : true
            guard value != lastAtTopEdge else { return }
            lastAtTopEdge = value
            DispatchQueue.main.async { [weak self] in
                self?.parent.onAtTopEdgeChange(value)
            }
        }

        /// Observes the scroll view's own pinch recognizer so the boundary haptic
        /// fires the instant the fingers lift — not when the over/under-zoom
        /// rubber-bands back to the limit (which `scrollViewDidEndZooming`
        /// reports a beat later).
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                didExceedLimit = false
            case .ended, .cancelled:
                if didExceedLimit { haptic.impactOccurred() }
                didExceedLimit = false
            default:
                break
            }
        }

        private func pushZoomed(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            if parent.isZoomed != zoomed {
                // Avoid mutating SwiftUI state inside the layout pass.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.parent.isZoomed != zoomed { self.parent.isZoomed = zoomed }
                }
            }
        }

        /// On release of a zoomed horizontal drag that ended at the photo's
        /// left/right content edge, fires `onPageBeyondEdge` so the swipe carries on
        /// to the neighboring bird. Deciding at release (not mid-drag) is what keeps a
        /// zoomed swipe from snapping to the next bird the instant it reaches the edge
        /// — it commits only when you lift, like the pager does at minimum zoom.
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let scroll = scrollView else { return }
            switch gesture.state {
            case .began, .possible:
                pageTriggeredThisGesture = false
            case .ended:
                // The carry-over page turn is decided only on release, not the
                // instant the drag crosses the edge: dragging past the edge while
                // zoomed should NOT force an immediate jump — the page turns when you
                // let go, matching how the pager settles at minimum zoom.
                guard !pageTriggeredThisGesture,
                      scroll.zoomScale > scroll.minimumZoomScale + 0.001 else { return }
                let t = gesture.translation(in: scroll)
                let v = gesture.velocity(in: scroll)
                // Horizontal-dominant releases only — a vertical pan was panning the
                // zoomed photo up/down (or swiping down to dismiss).
                guard abs(t.x) > abs(t.y) else { return }
                // Turn the page on a far-enough drag past the edge, or a quick flick.
                let threshold: CGFloat = 60
                let flickVelocity: CGFloat = 250
                let atLeft = scroll.contentOffset.x <= -scroll.contentInset.left + 0.5
                let atRight = scroll.contentOffset.x
                    >= scroll.contentSize.width - scroll.bounds.width + scroll.contentInset.right - 0.5
                if atLeft, t.x > 0, t.x > threshold || v.x > flickVelocity {
                    pageTriggeredThisGesture = true
                    parent.onPageBeyondEdge(-1)
                } else if atRight, t.x < 0, t.x < -threshold || v.x < -flickVelocity {
                    pageTriggeredThisGesture = true
                    parent.onPageBeyondEdge(1)
                }
            case .cancelled, .failed:
                pageTriggeredThisGesture = false
            default:
                break
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            parent.onSingleTap()
        }

        /// Routes a single tap to the right recognizer by where it lands: the
        /// on-image recognizer only accepts touches inside the (fitted) image, the
        /// on-background recognizer only those in the surrounding black letterbox.
        /// This is what lets a background tap toggle the chrome immediately while a
        /// tap on the photo still defers to the double-tap-to-zoom.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let imageView = scrollView?.imageView else { return true }
            let inImage = imageView.bounds.contains(touch.location(in: imageView))
            switch gestureRecognizer.name {
            case Self.imageTapName: return inImage
            case Self.backgroundTapName: return !inImage
            default: return true
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = scrollView, let imageView = scroll.imageView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let targetScale = min(scroll.maximumZoomScale, 2.5)
                let point = gesture.location(in: imageView)
                let size = CGSize(
                    width: scroll.bounds.width / targetScale,
                    height: scroll.bounds.height / targetScale
                )
                let rect = CGRect(
                    x: point.x - size.width / 2,
                    y: point.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                scroll.zoom(to: rect, animated: true)
            }
        }
    }
}

/// A `UIScrollView` that keeps its image fitted to the bounds at zoom 1, centers
/// it when it's smaller than the bounds, and — crucially — only lets its own pan
/// gesture begin while zoomed. At zoom 1 the pan never starts, so horizontal
/// drags fall through to `PhotoPager`'s paging scroll view and downward drags to
/// the swipe-to-dismiss; pinch (a separate recognizer) still works at any zoom.
final class CenteringScrollView: UIScrollView {
    var imageView: UIImageView?
    /// Whether the resting size is the width-filling one rather than the fitting
    /// one — set when the app has a whole large display to itself, where the
    /// photo is meant to reach both of its edges instead of being letterboxed
    /// inside it.
    ///
    /// This changes what zoom 1 *means* rather than starting the view zoomed in.
    /// Starting at a scale above `minimumZoomScale` would read all the way up the
    /// view as "the user has zoomed": paging between birds would be locked out
    /// and the chrome would auto-hide the instant the photo appeared. Making the
    /// grown size the base leaves the photo at minimum zoom, where all of that
    /// behaves exactly as it does on a phone, and a pinch still magnifies from
    /// there up to `maximumZoomScale`.
    var spansWidth = false
    /// How far in from `bounds`' left and right edges the photo rests, so a side
    /// bar never crosses the picture at rest. Only the *resting* size is held
    /// inside them: once zoomed the photo is free to grow across the full width
    /// and pass under the bar, which is what a zoom is for.
    var restingInsets: (left: CGFloat, right: CGFloat) = (0, 0)
    /// Whether the slack around a photo smaller than the view is spent below
    /// and to the right of it rather than split evenly around it — so the
    /// picture sits in the top-leading corner instead of floating in the
    /// middle.
    ///
    /// For a pane whose card is a fixed half of a display: the photo is
    /// letterboxed inside it by however much its shape differs from the card's,
    /// and centring that leaves a band of empty card above the picture and
    /// another below. Anchored, the picture starts at the corner the card's own
    /// curve is cut to and all the slack collects at the far end, where the
    /// details panel is.
    var anchorsTopLeading = false

    /// The radius the picture's own corners are cut to, or 0 to leave them
    /// square.
    ///
    /// Rounding the *page* only rounds whichever of the picture's corners
    /// happen to reach it, which for a photo letterboxed inside a pane is two
    /// of them at best. The image view is exactly the fitted picture — see
    /// `refit` — so a radius on its layer is a radius on the photograph,
    /// wherever in the page it has come to rest.
    ///
    /// It rides the zoom, because a scroll view zooms by transforming its
    /// content: magnify the picture and its corners round more. That only
    /// shows at the edges of a zoomed-in photo, which are off-screen.
    var photoCornerRadius: CGFloat = 0 {
        didSet {
            guard photoCornerRadius != oldValue else { return }
            applyPhotoCornerRadius()
        }
    }

    private func applyPhotoCornerRadius() {
        guard let imageView else { return }
        imageView.layer.cornerCurve = .continuous
        imageView.layer.cornerRadius = photoCornerRadius
        imageView.clipsToBounds = photoCornerRadius > 0
    }

    private var fittedForBounds: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        // Refit on width changes (first layout, rotation, image swap), but NOT on
        // a height-only change while at minimum zoom. During the swipe-to-dismiss
        // drag the live bounds height wobbles between the full-screen and
        // safe-area-inset values (`.offset` re-resolving `.ignoresSafeArea`), and
        // refitting/recentering on that wobble jitters the centered photo every
        // frame. Holding the last fit keeps it rock-steady as the card slides.
        let zoomed = zoomScale > minimumZoomScale + 0.001
        let needsRefit = fittedForBounds == .zero
            || abs(bounds.width - fittedForBounds.width) > 0.5
            || (zoomed && abs(bounds.height - fittedForBounds.height) > 0.5)
        if needsRefit {
            refit()
        }
        centerContent()
    }

    /// Re-fits the image to the current bounds at zoom 1. Called on a bounds
    /// change (rotation / first layout) and when the image swaps.
    func refit() {
        guard let imageView, let image = imageView.image,
              bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        fittedForBounds = bounds.size
        // Fit the whole photo inside the page, or — when the photo is meant to
        // span the display — grow it until its width matches the page's, letting
        // it run past the top and bottom edges if its shape is taller than the
        // page's. A photo wider than the page still letterboxes vertically: the
        // rule is that it touches the left and right edges, which for such a
        // photo is already what fitting does.
        let scale = spansWidth
            ? bounds.width / image.size.width
            : min(restingWidth / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        applyPhotoCornerRadius()
        centerContent()
    }

    /// Inset the content so it stays centered when it's smaller than the
    /// viewport in either axis (e.g. a landscape photo letterboxed at zoom 1).
    ///
    /// Centers against the size we last *fit* to (`fittedForBounds`), not the
    /// live `bounds`: during the dismiss drag the live height wobbles, and
    /// centering off it would bounce the photo. The fitted size is stable between
    /// refits, so the photo holds its position and simply slides with the card.
    /// (When zoomed the content is larger than either, so both clamp to 0 — no
    /// difference there.)
    func centerContent() {
        let reference = fittedForBounds == .zero ? bounds.size : fittedForBounds
        let cs = contentSize
        let slack = max(reference.height - cs.height, 0)
        let top = anchorsTopLeading ? 0 : slack / 2
        let (left, right) = horizontalInsets(contentWidth: cs.width, reference: reference.width)
        contentInset = UIEdgeInsets(top: top, left: left, bottom: slack - top, right: right)
    }

    /// The photo's resting width — the part of `bounds` a side bar doesn't cross.
    private var restingWidth: CGFloat {
        max(bounds.width - restingInsets.left - restingInsets.right, 1)
    }

    /// Left and right `contentInset` for a content of `contentWidth`.
    ///
    /// Two regimes, joined so they meet without a step — a jump here would be a
    /// visible lurch mid-pinch, since this is recomputed on every zoom frame.
    /// While the photo still fits the resting box it is centred *in that box*,
    /// held clear of the side bars. Once it outgrows the box the insets fall away
    /// in step with how far past it the photo has grown, reaching zero exactly as
    /// the photo reaches the full width of the view — from there on it spans the
    /// display, bars included, and pans freely.
    ///
    /// With no side insets (an ordinary phone, or a photo spanning the display)
    /// both regimes collapse to plain centring, which is what this always did.
    private func horizontalInsets(
        contentWidth: CGFloat,
        reference: CGFloat
    ) -> (left: CGFloat, right: CGFloat) {
        let resting = max(reference - restingInsets.left - restingInsets.right, 1)
        if contentWidth <= resting {
            let slack = resting - contentWidth
            let left = anchorsTopLeading ? 0 : slack / 2
            return (restingInsets.left + left, restingInsets.right + slack - left)
        }

        let bars = restingInsets.left + restingInsets.right
        guard bars > 0 else { return (0, 0) }
        // 0 as the photo leaves the resting box, 1 once it fills the view.
        let progress = min((contentWidth - resting) / bars, 1)
        return (restingInsets.left * (1 - progress), restingInsets.right * (1 - progress))
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer == panGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        // At minimum zoom the image fills the frame with nothing to pan, so let the
        // drag fall through to SwiftUI (page between birds / swipe to dismiss).
        guard zoomScale > minimumZoomScale + 0.001 else { return false }

        // Zoomed in: own the pan so the magnified image can be panned — except a
        // horizontal swipe that starts at the image's left/right content edge, which
        // we let through to the pager so the user can still swipe to the next/previous
        // bird while zoomed (matching the Photos app's edge hand-off). Vertical pans
        // always stay with the image (and the swipe-down-at-top still dismisses).
        let velocity = panGestureRecognizer.velocity(in: self)
        guard abs(velocity.x) > abs(velocity.y) else { return true }
        let atLeftEdge = contentOffset.x <= -contentInset.left + 0.5
        let atRightEdge = contentOffset.x >= contentSize.width - bounds.width + contentInset.right - 0.5
        if velocity.x > 0, atLeftEdge { return false }   // swipe right at left edge → previous bird
        if velocity.x < 0, atRightEdge { return false }  // swipe left at right edge → next bird
        return true
    }
}
