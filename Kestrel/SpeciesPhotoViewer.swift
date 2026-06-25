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

    /// The page currently shown. Seeded from `initialIndex` in `init`.
    @State private var index: Int
    /// True while the current page is zoomed in — disables horizontal paging and
    /// the swipe-down dismiss so a pan inside the photo doesn't trigger either.
    @State private var isZoomed = false

    // Swipe-to-dismiss (applied to the whole card).
    @State private var dragOffset: CGSize = .zero
    @State private var contentOpacity: Double = 1
    /// Latched true once a drag has been recognized as a downward dismiss, so we
    /// keep following the finger's vertical travel without re-testing horizontal
    /// dominance every frame — that re-test made a *slow* drag stutter near the
    /// top, where tiny horizontal finger noise rivaled the small vertical travel
    /// and toggled the gesture on and off. Reset when the drag ends.
    @State private var dismissEngaged = false
    /// Measured viewer size, used to slide the card fully off on dismiss.
    @State private var viewSize: CGSize = CGSize(width: 400, height: 800)

    /// Blank gutter (in points) shown between birds while paging horizontally,
    /// matching the iOS Photos app. Bump this to widen or tighten the gap.
    private let pageSpacing: CGFloat = 24

    /// Past this much downward travel (or a fast enough downward flick),
    /// release dismisses.
    private let dismissThreshold: CGFloat = 120
    /// Downward velocity (pt/s) past which a short drag still dismisses, so a
    /// quick flick throws the card off even before it has traveled far.
    private let dismissVelocity: CGFloat = 700

    init(
        items: [SpeciesPhotoItem],
        initialIndex: Int = 0,
        mapButtonTitle: String? = nil,
        onShowOnMap: ((SpeciesPhotoItem) -> Void)? = nil
    ) {
        self.items = items
        self.mapButtonTitle = mapButtonTitle
        self.onShowOnMap = onShowOnMap
        _index = State(initialValue: min(max(initialIndex, 0), max(items.count - 1, 0)))
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
        ZStack {
            // The black backdrop + the paged photos slide together with the
            // dismiss drag, revealing the app behind through the clear
            // presentation background.
            Color.black

            // Each bird gets a `pageSpacing` blank gutter between it and the
            // next, like the iOS Photos app. Implemented by making the paging
            // TabView `pageSpacing` wider than the screen (so each page carries
            // an extra `pageSpacing` of width), constraining each photo to the
            // true screen width and centering it within its page (leaving
            // `pageSpacing/2` of black on each side), then shifting the whole
            // TabView left by `pageSpacing/2` so the current photo still fills
            // the screen edge-to-edge. The black gutter only shows mid-swipe.
            //
            // Sized off the constant `screenWidth`/`fullHeight` (not an inner
            // GeometryReader inside `.ignoresSafeArea()`, whose height ramped
            // 874→778 every drag frame and jittered the centered photo). Pinning
            // the TabView to the constant `fullHeight` keeps the photo's viewport
            // — and so its centering — rock-steady as the card slides.
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    ZoomablePhotoPage(
                        item: item,
                        isCurrent: offset == index,
                        isZoomed: $isZoomed,
                        mapButtonTitle: mapButtonTitle,
                        onShowOnMap: onShowOnMap.map { action in { action(item) } }
                    )
                    .frame(width: screenWidth)
                    .frame(maxWidth: .infinity)
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // No paging while zoomed — the scroll view's pan owns the drag.
            .scrollDisabled(isZoomed)
            .frame(width: screenWidth + pageSpacing, height: fullHeight)
            .offset(x: -pageSpacing / 2)

            // Top inset comes from the outer proxy because the ZStack ignores the
            // safe area below.
            closeButton
                .padding(.top, proxy.safeAreaInsets.top)
        }
        // Pin to the constant full-screen size, then ignore the safe area so it
        // covers the screen edge-to-edge. Because the frame is an explicit
        // constant (not an ignoresSafeArea-expanded proposal), it does NOT churn
        // when the body re-evaluates during the drag.
        .frame(width: screenWidth, height: fullHeight)
        .ignoresSafeArea()
        // Keep the dismiss slide-off target in sync with the (stable) card size.
        .onChange(of: fullHeight, initial: true) { _, h in viewSize = CGSize(width: screenWidth, height: h) }
        // Translate the whole card for the swipe-to-dismiss. A plain `.offset`
        // (not `visualEffect`, which leaves the hosted photo UIScrollView behind)
        // moves the photo with everything else; and because the frame above is a
        // constant, the offset only translates — it doesn't re-resolve the safe
        // area, so no relayout churn.
        .offset(dragOffset)
        .opacity(contentOpacity)
        // Clear presentation background so the slide reveals the app behind.
        .presentationBackground(.clear)
        // Vertical-down dismiss, alongside (not blocking) the TabView's
        // horizontal paging. Disabled while zoomed so a downward pan of the
        // photo doesn't dismiss.
        .simultaneousGesture(dismissDrag)
        }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                // Liquid-glass close button, matching the life-list search
                // field's cancel button.
                Button { dismissViewer() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 22, height: 22)
                        .padding(13)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .contentShape(Circle())
                }
                .buttonStyle(NoDimButtonStyle())
                .padding(.trailing, 16)
                .padding(.top, 8)
            }
            Spacer()
        }
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
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                guard !isZoomed else { return }
                if !dismissEngaged {
                    // Decide once, on the first qualifying frame: a downward,
                    // vertical-dominant drag engages dismiss. Horizontal goes to
                    // paging, and the upward "lift off the bottom" is disallowed.
                    guard value.translation.height > 0,
                          abs(value.translation.height) > abs(value.translation.width) else { return }
                    dismissEngaged = true
                }
                // Once engaged, track the finger's vertical travel directly
                // (clamped to downward) without re-checking dominance each frame.
                dragOffset = CGSize(width: 0, height: max(value.translation.height, 0))
            }
            .onEnded { value in
                print(String(
                    format: "[ViewerDrag] ENDED ty=%.1f vy=%.1f offY=%.1f",
                    value.translation.height, value.velocity.height, dragOffset.height
                ))
                defer { dismissEngaged = false }
                guard !isZoomed else { return }
                let verticalDominant = abs(value.translation.height) > abs(value.translation.width)
                let pastThreshold = value.translation.height > dismissThreshold
                let flung = value.velocity.height > dismissVelocity
                if verticalDominant, value.translation.height > 0, pastThreshold || flung {
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
            duration = min(max(Double(remaining / velocity), 0.16), 0.32)
        } else {
            duration = 0.32
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

/// A single zoomable page within the viewer: the photo (pinch + pan + double-tap
/// zoom, all driven by a `UIScrollView`) and its caption. Reports its zoom state
/// up so the container can disable paging while zoomed, and resets zoom when it
/// scrolls off-screen.
private struct ZoomablePhotoPage: View {
    let item: SpeciesPhotoItem
    let isCurrent: Bool
    @Binding var isZoomed: Bool
    var mapButtonTitle: String?
    /// Pre-bound to this page's bird (the container curries the item in).
    var onShowOnMap: (() -> Void)?

    @State private var image: UIImage?
    @State private var loadFailed = false
    /// Per-page zoom flag. Mirrored up into the container's `isZoomed` only while
    /// this page is the current one, so an off-screen page resetting its zoom
    /// can't flip the container's paging gate.
    @State private var pageZoomed = false
    /// Bumped to ask the scroll view to reset back to fit (when the page scrolls
    /// off-screen).
    @State private var resetToken = 0

    private var commonName: String {
        SpeciesCatalog.shared.commonName(for: item.scientificName) ?? item.scientificName
    }
    private var info: SpeciesPhotoInfo? {
        SpeciesPhotoMetadata.shared.info(for: item.scientificName)
    }

    var body: some View {
        ZStack {
            // Fill edge-to-edge: the paging TabView reserves the safe area for its
            // pages (so a page is only the inset height), and this pushes the photo
            // back out to the full screen. It's stable under the dismiss drag now
            // that the container is a constant-height frame translated by a plain
            // `.offset` — the offset no longer re-resolves this safe area.
            imageLayer.ignoresSafeArea()

            VStack {
                Spacer()
                caption
            }
        }
        .contentShape(Rectangle())
        .task(id: item.scientificName) { await load() }
        .onChange(of: pageZoomed) { _, zoomed in
            guard isCurrent else { return }
            if isZoomed != zoomed { isZoomed = zoomed }
        }
        .onChange(of: isCurrent) { _, current in
            if current {
                if isZoomed != pageZoomed { isZoomed = pageZoomed }
            } else {
                // Page scrolled away — reset its zoom so it isn't left zoomed.
                resetToken &+= 1
            }
        }
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let image {
            ZoomableImageView(
                image: image,
                isZoomed: $pageZoomed,
                resetToken: resetToken
            )
        } else if loadFailed {
            Image(systemName: "bird")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.4))
        } else {
            ProgressView().tint(.white)
        }
    }

    @ViewBuilder
    private var caption: some View {
        // Spacing of 12 widens the two gaps the user asked for — name → location
        // and date → attribution — while the place/date pair below stays tight
        // (its own VStack spacing).
        VStack(spacing: 12) {
            // Species name — a touch larger than the metadata below it.
            Text(commonName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            // Sighting: where + when, directly under the name. Only for lifers
            // (a date is always recorded); the place name is the map tap target,
            // with the pin-in-circle glyph to its right.
            if let dateFound = item.dateFound {
                VStack(spacing: 3) {
                    if let place = item.placeName, !place.isEmpty {
                        // Location shrunk to subheadline to match the date below.
                        let row = HStack(spacing: 6) {
                            Text(place)
                            Image(systemName: "mappin.circle")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        if let onShowOnMap {
                            Button(action: onShowOnMap) { row }
                                .buttonStyle(NoDimButtonStyle())
                                .accessibilityLabel(mapButtonTitle ?? "Show on Map")
                        } else {
                            row
                        }
                    }
                    Text(dateFound, format: .dateTime.year().month(.abbreviated).day())
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            // Attribution + eBird link, below the sighting info.
            if let info {
                VStack(spacing: 4) {
                    Text(info.attribution)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                    if let ebirdURL = info.ebirdURL {
                        Link("View on eBird", destination: ebirdURL)
                            .font(.caption2.weight(.semibold))
                            .tint(.white)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        // The frosted panel bleeds to the very bottom of the screen (its fill
        // ignores the bottom safe area) while the text stays above the home
        // indicator.
        .background {
            Color.black.opacity(0.75).ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Loading

    private func load() async {
        image = nil
        loadFailed = false
        let name = item.scientificName
        if let mem = RemoteSpeciesImageStore.shared.memoryImage(for: name) {
            image = mem
            return
        }
        let loaded = await RemoteSpeciesImageStore.shared.image(for: name)
        guard !Task.isCancelled else { return }
        image = loaded
        loadFailed = loaded == nil
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

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        return scroll
    }

    func updateUIView(_ scroll: CenteringScrollView, context: Context) {
        context.coordinator.parent = self
        if scroll.imageView?.image !== image {
            scroll.imageView?.image = image
            scroll.refit()
        }
        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            if scroll.zoomScale != scroll.minimumZoomScale {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: false)
                scroll.refit()
            }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImageView
        weak var scrollView: CenteringScrollView?
        var lastResetToken: Int
        private var didHapticMax = false
        private var didHapticMin = false
        private let haptic = UIImpactFeedbackGenerator(style: .rigid)

        init(_ parent: ZoomableImageView) {
            self.parent = parent
            self.lastResetToken = parent.resetToken
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? CenteringScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? CenteringScrollView)?.centerContent()

            // Boundary haptics: only while a pinch is actively driving the
            // scale past a limit, and only once per excursion.
            let state = scrollView.pinchGestureRecognizer?.state
            let pinching = state == .began || state == .changed
            if pinching {
                if scrollView.zoomScale > scrollView.maximumZoomScale + 0.001 {
                    if !didHapticMax { haptic.impactOccurred(); didHapticMax = true }
                } else {
                    didHapticMax = false
                }
                if scrollView.zoomScale < scrollView.minimumZoomScale - 0.001 {
                    if !didHapticMin { haptic.impactOccurred(); didHapticMin = true }
                } else {
                    didHapticMin = false
                }
            }
            pushZoomed(scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            didHapticMax = false
            didHapticMin = false
            (scrollView as? CenteringScrollView)?.centerContent()
            pushZoomed(scrollView)
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
        print(String(
            format: "[ScrollLayout] bounds=%.0fx%.0f content=%.0fx%.0f zoom=%.2f insetTop=%.1f",
            bounds.width, bounds.height, contentSize.width, contentSize.height,
            zoomScale, contentInset.top
        ))
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
        // Only own the drag once zoomed; otherwise let SwiftUI page / dismiss.
        if gestureRecognizer == panGestureRecognizer {
            return zoomScale > minimumZoomScale + 0.001
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
