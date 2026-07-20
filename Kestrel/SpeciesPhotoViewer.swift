import SwiftUI
import UIKit

/// One bird shown in the full-screen viewer, plus the sighting metadata its
/// caption needs. A viewer is opened over an *ordered* array of these (life-list
/// order, or the birds within a map card) so the user can swipe between them.
struct SpeciesPhotoItem: Identifiable, Equatable {
    let scientificName: String
    var placeName: String? = nil
    var dateFound: Date? = nil
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
private struct PageCommand: Equatable {
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

    @Environment(\.dismiss) private var dismiss
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
    /// Whether the floating chrome (name capsule, close button, bottom details)
    /// is shown. A single tap on the photo toggles it.
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
        onShowOnMap: ((SpeciesPhotoItem) -> Void)? = nil
    ) {
        self.items = items
        self.mapButtonTitle = mapButtonTitle
        self.onShowOnMap = onShowOnMap
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
    /// photo is never cluttered by the name capsule / info panel.
    private func hideUIForZoom() {
        guard uiVisible else { return }
        withAnimation(.easeInOut(duration: Self.uiToggleDuration)) { uiVisible = false }
    }

    /// Shows the chrome if it's hidden — used when the photo returns to minimum
    /// zoom, so zooming back out reveals the name capsule / info panel again
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
        GeometryReader { proxy in
        // Width is the real screen width (portrait has no side insets, so this is
        // just `proxy.size.width`); height is the full screen, the safe-area rect
        // grown back by the top+bottom insets. Both are CONSTANTS off the stable
        // outer proxy.
        let screenWidth = proxy.size.width
        let fullHeight = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        // Half the top safe area: the card-top travel at which the white status
        // bar flips, so it switches when the card is *halfway* through the safe
        // area rather than only once it has fully cleared it.
        let statusBarFlipPoint = proxy.safeAreaInsets.top / 2
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
                onSettledChange: { paging.swipeSettled = $0 }
            ) { i in
                ZoomablePhotoPage(
                    item: items[i],
                    paging: paging,
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
            .frame(width: screenWidth, height: fullHeight)

            // Single chrome layer over the *current* bird — name top-center, back
            // button top-left, info panel bottom. Lives in the offsetting inner
            // card so it tracks the dismiss drag 1:1, and is forced dark so the
            // glass + text read as immersive-viewer chrome from the first frame.
            chrome(topInset: proxy.safeAreaInsets.top, bottomInset: proxy.safeAreaInsets.bottom, screenWidth: screenWidth)
                .opacity(uiVisible ? 1 : 0)
                .allowsHitTesting(uiVisible)
                .colorScheme(.dark)
        }
        // Pin the inner card to the constant full-screen size. Because the frame
        // is an explicit constant (not an ignoresSafeArea-expanded proposal), it
        // does NOT churn when the body re-evaluates during the drag.
        .frame(width: screenWidth, height: fullHeight)
        // Translate the inner card for the swipe-to-dismiss. The parent ZStack
        // below already ignores the safe area and is itself never offset, so this
        // moves the ENTIRE card — its top edge over the status bar included — in
        // lockstep with the finger. (Offsetting the `.ignoresSafeArea()` view
        // directly made SwiftUI drop the top extension the instant the offset went
        // nonzero, pinning the top while the rest slid — the lag we're fixing.)
        // A plain `.offset` (not `visualEffect`, which leaves the hosted photo
        // UIScrollView behind) moves the photo with everything else.
        .offset(dragOffset)
        }
        // Pin the (un-offset) outer container to the same constant size and let it
        // ignore the safe area, so the inner card is always full-bleed.
        .frame(width: screenWidth, height: fullHeight)
        .ignoresSafeArea()
        // Keep the dismiss slide-off target in sync with the (stable) card size.
        .onChange(of: fullHeight, initial: true) { _, h in viewSize = CGSize(width: screenWidth, height: h) }
        // Swiping to a new bird starts it fresh: the incoming page is always built
        // at minimum zoom (the pager recreates pages, see `PhotoPager`), so clear
        // any lingering zoom state from the bird we left, and bring the chrome back
        // if a zoom on the previous bird had auto-hidden it (`hideUIForZoom`). Without
        // this the container's `isZoomed`/`uiVisible` stay stuck on the previous
        // page's values — the new, un-zoomed bird would otherwise show with its name
        // capsule and info panel still hidden.
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
        .background(
            StatusBarStyleController(
                lightContent: cardCoveredStatusBar && dragOffset.height < statusBarFlipPoint
            )
        )
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
        // Vertical-down dismiss, alongside (not blocking) the TabView's
        // horizontal paging. Disabled while zoomed so a downward pan of the
        // photo doesn't dismiss.
        .simultaneousGesture(dismissDrag)
        }
    }

    // MARK: - Chrome

    /// Height of the top controls (a 22pt glyph + 13pt padding = 48pt). The name
    /// capsule matches it; the info panel's corner radius is half of it.
    private static let chromeHeight: CGFloat = 48

    private func commonName(for item: SpeciesPhotoItem) -> String {
        SpeciesCatalog.shared.commonName(for: item.scientificName) ?? item.scientificName
    }
    private func info(for item: SpeciesPhotoItem) -> SpeciesPhotoInfo? {
        SpeciesPhotoMetadata.shared.info(for: item.scientificName)
    }

    @ViewBuilder
    private func chrome(topInset: CGFloat, bottomInset: CGFloat, screenWidth: CGFloat) -> some View {
        if let item = currentItem {
            VStack(spacing: 0) {
                // Top row: back button pinned leading, star toggle pinned trailing,
                // name capsule centered.
                ZStack {
                    nameCapsule(for: item, screenWidth: screenWidth)
                    HStack {
                        backButton
                        Spacer()
                        starButton(for: item)
                    }
                }
                .padding(.top, topInset + 8)
                .padding(.horizontal, 16)

                Spacer(minLength: 0)

                // Always shown: it carries the sighting place/date and the photo
                // attribution — or, for a species we don't have a photo for yet, a
                // "coming soon" notice in the attribution's place.
                infoPanel(for: item, screenWidth: screenWidth)
                    .padding(.bottom, bottomInset + 8)
            }
        }
    }

    /// Species name in a liquid-glass capsule, top-center. The capsule hugs the
    /// name; only a name too wide for the cap (`screenWidth - 150`, leaving room
    /// for the back button + symmetric margin) shrinks to fit.
    private func nameCapsule(for item: SpeciesPhotoItem, screenWidth: CGFloat) -> some View {
        let cap = screenWidth - 150
        // `.frame(maxWidth:)` is a *flexible* frame: inside the full-width top-row
        // ZStack it fills to its max, so the old capsule was always `cap` wide.
        // `ViewThatFits` instead picks the natural-width label when it fits within
        // `cap` (capsule hugs the text) and only falls back to the scaled,
        // cap-width label when the name is genuinely too long. The outer
        // `.frame(maxWidth: cap)` exists solely to propose `cap` as the fit budget;
        // its transparent expansion stays centered, so the hugging capsule does too.
        return ViewThatFits(in: .horizontal) {
            // `fixedSize` exposes the label's true ideal width so ViewThatFits can
            // tell whether it actually fits `cap` (a plain line-limited Text would
            // silently truncate to the budget and always "fit").
            nameLabel(for: item)
                .fixedSize(horizontal: true, vertical: false)
            nameLabel(for: item)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: cap)
    }

    private func nameLabel(for item: SpeciesPhotoItem) -> some View {
        Text(commonName(for: item))
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(height: Self.chromeHeight)
            .glassEffect(.regular, in: .capsule)
            // Swallow taps on the capsule so tapping the chrome doesn't also
            // fire the photo's single-tap-to-hide. Only the hugging capsule
            // absorbs; the transparent fit budget around it stays pass-through.
            .contentShape(.capsule)
            .onTapGesture { }
    }

    private var backButton: some View {
        Button { dismissViewer() } label: {
            Image(systemName: "chevron.backward")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .padding(13)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(NoDimButtonStyle())
        .accessibilityLabel("Back")
    }

    /// Blue used for a filled "alert me" star — matched to the Life List tab's
    /// star tint so the same bird reads the same in both places.
    private static let starTint = Color(hue: 220.0 / 360.0, saturation: 0.7, brightness: 1.0)

    /// Top-right star toggle for the current bird's "alert me" state. Identical to
    /// `backButton` apart from position and icon: a white outline star when the
    /// species isn't starred, a filled blue star when it is. Writes through to the
    /// life-list store's starred set (which persists even for a non-lifer).
    private func starButton(for item: SpeciesPhotoItem) -> some View {
        let starred = lifeListStore?.starredNames.contains(item.scientificName) ?? false
        return Button {
            // A single short tap to confirm the star toggled, matching the Life
            // List tab's star button.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            lifeListStore?.setStarred(scientificName: item.scientificName, isStarred: !starred)
        } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(starred ? Self.starTint : .white)
                .frame(width: 22, height: 22)
                .padding(13)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(NoDimButtonStyle())
        .accessibilityLabel(starred ? "Remove alert star" : "Alert me when heard")
    }

    /// Bottom details — place (a blue, tappable link to the map), date, and photo
    /// attribution — in a liquid-glass panel. Non-link text is white like the
    /// name; the panel's width is capped for a generous margin from the edges.
    private func infoPanel(for item: SpeciesPhotoItem, screenWidth: CGFloat) -> some View {
        VStack(spacing: 12) {
            if let dateFound = item.dateFound {
                // Place (blue, the map link) + date stacked together. When the map
                // action is available the *whole block* — place, date, and a little
                // padding around them — is one button, so the tap target is generous
                // rather than just the place-name text.
                let block = VStack(spacing: 3) {
                    if let place = item.placeName, !place.isEmpty {
                        // Tight spacing keeps the pin close to the place name.
                        HStack(spacing: 4) {
                            Text(place)
                            Image(systemName: "mappin.circle")
                        }
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(onShowOnMap != nil ? Color.blue : Color.white)
                    }
                    Text(dateFound, format: .dateTime.year().month(.abbreviated).day())
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }

                if let onShowOnMap {
                    Button { onShowOnMap(item) } label: {
                        block
                            // Generous hit area: padding around the whole place+date
                            // block (plus the date text itself) so taps near it land.
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NoDimButtonStyle())
                    .accessibilityLabel(mapButtonTitle ?? "Show on Map")
                } else {
                    block
                }
            }

            if let info = info(for: item) {
                // The whole attribution block (credit text + the "View source"
                // line) is the tap target, so taps anywhere on the credit open the
                // photo's source page — but only the "View source" line is colored
                // blue; the attribution above it stays white.
                let attributionBlock = VStack(spacing: 4) {
                    Text(info.attribution)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                    if info.sourceURL != nil {
                        Text("View source")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())

                if let sourceURL = info.sourceURL {
                    Link(destination: sourceURL) { attributionBlock }
                        .buttonStyle(NoDimButtonStyle())
                        .accessibilityLabel("View photo source")
                } else {
                    attributionBlock
                }
            } else {
                // No photo for this species yet — reassure the user one is coming,
                // in the same slot the attribution would occupy.
                Text("Photo coming soon")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
        .frame(maxWidth: min(screenWidth - 80, 360))
        .glassEffect(.regular, in: .rect(cornerRadius: Self.chromeHeight / 2))
        // Swallow taps on blank areas of the panel so tapping the chrome doesn't
        // fire the photo's single-tap-to-hide. The inner map button / eBird link
        // keep working — their own gestures take precedence over this no-op.
        .contentShape(.rect(cornerRadius: Self.chromeHeight / 2))
        .onTapGesture { }
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
        // disables the TabView's paging (`scrollDisabled(... || dismissEngaged)`)
        // — before the TabView's own pan threshold is crossed. Otherwise a
        // diagonal close let the bird slide sideways for the first few points
        // before paging was locked out.
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
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = .zero
                    }
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

        withAnimation(.easeOut(duration: duration)) {
            dragOffset = CGSize(width: 0, height: target)
        }
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

/// Drives the presented cover's status bar style with a short (~0.1s) fade as
/// the card covers/uncovers it — quicker than the system's ~0.25s crossfade that
/// `.preferredColorScheme` forces, but no longer an instant flip. Lives as a
/// hidden background inside the cover; SwiftUI forwards the cover hosting
/// controller's status-bar query down to this child controller.
///
/// `lightContent == true` → `.lightContent` (white, for the dark card over the
/// bar). Otherwise `.default`, which adapts to the interface style (dark content
/// in light mode, light in dark) so the uncovered app behind reads correctly.
private struct StatusBarStyleController: UIViewControllerRepresentable {
    var lightContent: Bool

    func makeUIViewController(context: Context) -> Host { Host() }

    func updateUIViewController(_ host: Host, context: Context) {
        host.lightContent = lightContent
    }

    final class Host: UIViewController {
        var lightContent = false {
            didSet {
                guard lightContent != oldValue else { return }
                applyStatusBarStyle()
            }
        }
        override var preferredStatusBarStyle: UIStatusBarStyle {
            lightContent ? .lightContent : .default
        }
        override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            // Re-assert once attached, in case `lightContent` was set before this
            // controller had joined the cover's hierarchy.
            applyStatusBarStyle()
        }

        /// Drives the status-bar appearance update with a short crossfade, then
        /// re-asserts it a few times across the cover's present transition. A single
        /// update issued *during* the present animation is sometimes swallowed by the
        /// system's own status-bar handling, which left the bar stuck on its previous
        /// (dark, invisible over the dark card) style — the intermittent "status bar
        /// stays black" bug. The delayed re-asserts land after the transition settles
        /// so the final resolved style is reliably ours.
        private func applyStatusBarStyle() {
            UIView.animate(withDuration: 0.15) {
                self.setNeedsStatusBarAppearanceUpdate()
            }
            for delay in [0.1, 0.3, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.setNeedsStatusBarAppearanceUpdate()
                }
            }
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
private struct PhotoPager<Page: View>: UIViewControllerRepresentable {
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
            context.coordinator.observeOffset(of: scrollView)
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
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

        init(_ parent: PhotoPager) { self.parent = parent }

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

        /// Watch the paging scroll view's offset and flip the reported index the
        /// instant the swipe is more than halfway to the neighboring page. The
        /// scroll view rests with the current page centered at `contentOffset.x ==
        /// bounds.width`; a drag moves it within ±`bounds.width` of that, so the
        /// signed fraction past center tells us how far toward the next/previous
        /// page the swipe has travelled. We KVO the offset rather than become the
        /// scroll view's delegate, which `UIPageViewController` owns internally.
        func observeOffset(of scrollView: UIScrollView) {
            offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                guard let self else { return }
                let width = scrollView.bounds.width
                guard width > 0 else { return }
                let fraction = (scrollView.contentOffset.x - width) / width
                // Mid-swipe whenever the content is off its resting center; the
                // pager recenters to `width` (fraction 0) at every page boundary,
                // so this reads true again the instant the swipe comes to rest.
                self.reportSettled(abs(fraction) < 0.001)
                let target: Int
                if fraction >= 0.5 {
                    target = self.currentIndex + 1
                } else if fraction <= -0.5 {
                    target = self.currentIndex - 1
                } else {
                    target = self.currentIndex
                }
                let clamped = min(max(target, 0), max(self.parent.count - 1, 0))
                guard clamped != self.lastReportedIndex else { return }
                self.lastReportedIndex = clamped
                self.parent.onIndexChange(clamped)
            }
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
private final class IndexedHost<Content: View>: UIHostingController<Content> {
    var index = 0
}

/// A single zoomable page within the viewer: just the photo (pinch + pan +
/// double-tap zoom, all driven by a `UIScrollView`). All chrome (name, back
/// button, info panel) lives once in the container over the current page. Reports
/// its zoom state up via `onZoomChange` so the container can disable paging while
/// zoomed. The pager creates a fresh page each time one scrolls into view, so a
/// page is never left zoomed.
private struct ZoomablePhotoPage: View {
    let item: SpeciesPhotoItem
    /// Shared paging state — the page holds its full-resolution swap until this
    /// reports the swipe has settled, so the heavier image never swaps in while
    /// the user is still swiping between birds.
    let paging: ViewerPaging
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

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var pageZoomed = false
    /// True once the full-resolution image has been shown (or was already
    /// resident), so the deferred download isn't kicked off again.
    @State private var fullResLoaded = false
    /// The in-flight full-resolution download, so it can be cancelled if the page
    /// scrolls away before it finishes.
    @State private var fullResTask: Task<Void, Never>?

    var body: some View {
        imageLayer
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
        guard paging.settled, !fullResLoaded, fullResTask == nil, image != nil else { return }
        let name = item.scientificName
        fullResTask = Task {
            defer { fullResTask = nil }
            guard let full = await RemoteSpeciesImageStore.shared.fullResolutionImage(for: name) else {
                return
            }
            guard !Task.isCancelled else { return }
            // Settled may have changed during the download (e.g. a new swipe began);
            // only swap while still settled, otherwise the next settle re-runs this.
            guard paging.settled else { return }
            image = full
            fullResLoaded = true
        }
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let image {
            ZoomableImageView(
                image: image,
                isZoomed: $pageZoomed,
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
/// drags fall through to the SwiftUI paging TabView and downward drags to the
/// swipe-to-dismiss; pinch (a separate recognizer) still works at any zoom.
final class CenteringScrollView: UIScrollView {
    var imageView: UIImageView?
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
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
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
        let x = max((reference.width - cs.width) / 2, 0)
        let y = max((reference.height - cs.height) / 2, 0)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
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
