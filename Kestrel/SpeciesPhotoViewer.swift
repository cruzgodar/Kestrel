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
    /// Measured viewer size, used to slide the card fully off on dismiss.
    @State private var viewSize: CGSize = CGSize(width: 400, height: 800)

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
        ZStack {
            // The black backdrop + the paged photos slide together with the
            // dismiss drag, revealing the app behind through the clear
            // presentation background.
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    ZoomablePhotoPage(
                        item: item,
                        isCurrent: offset == index,
                        isZoomed: $isZoomed,
                        mapButtonTitle: mapButtonTitle,
                        onShowOnMap: onShowOnMap.map { action in { action(item) } }
                    )
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // No paging while zoomed — the scroll view's pan owns the drag.
            .scrollDisabled(isZoomed)
            // Fill the whole screen: a paging TabView otherwise insets its pages
            // by the safe area, which left black bars top and bottom under the
            // root tab view.
            .ignoresSafeArea()

            closeButton
        }
        .offset(dragOffset)
        .opacity(contentOpacity)
        // Clear presentation background so the slide reveals the app behind.
        .presentationBackground(.clear)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
        // Vertical-down dismiss, alongside (not blocking) the TabView's
        // horizontal paging. Disabled while zoomed so a downward pan of the
        // photo doesn't dismiss.
        .simultaneousGesture(dismissDrag)
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
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isZoomed else { return }
                // Downward, vertical-dominant only — horizontal goes to paging,
                // and the upward "lift off the bottom" is disallowed.
                guard value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = CGSize(width: 0, height: value.translation.height)
            }
            .onEnded { value in
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
            // Button / threshold-without-flick dismiss: brisk, matching the
            // default cover present speed (faster than the old 0.28).
            duration = 0.25
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
        if bounds.size != fittedForBounds {
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
    func centerContent() {
        let cs = contentSize
        let x = max((bounds.width - cs.width) / 2, 0)
        let y = max((bounds.height - cs.height) / 2, 0)
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
