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

    /// Which page the horizontal paging `ScrollView` is settled on (the page's
    /// integer id). Seeded from `initialIndex` in `init`. `index` derives the
    /// clamped current page from it.
    @State private var scrolledID: Int?
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
    /// Whether the floating chrome (name capsule, close button, bottom details)
    /// is shown. A single tap on the photo toggles it.
    @State private var uiVisible = true
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

    private func toggleUI() {
        withAnimation(.easeInOut(duration: 0.25)) { uiVisible.toggle() }
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
                // Disable paging while zoomed (the photo's own pan owns the drag)
                // or once a downward dismiss has engaged (so a diagonal close can't
                // slide to the next bird).
                pagingDisabled: isZoomed || dismissEngaged,
                interPageSpacing: pageSpacing,
                onIndexChange: { scrolledID = $0 }
            ) { i in
                ZoomablePhotoPage(
                    item: items[i],
                    onToggleUI: toggleUI,
                    onZoomChange: { zoomed in
                        // Only the current page's zoom gates paging.
                        if i == index, isZoomed != zoomed { isZoomed = zoomed }
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
    private func hasCaptionContent(for item: SpeciesPhotoItem) -> Bool {
        item.dateFound != nil || info(for: item) != nil
    }

    @ViewBuilder
    private func chrome(topInset: CGFloat, bottomInset: CGFloat, screenWidth: CGFloat) -> some View {
        if let item = currentItem {
            VStack(spacing: 0) {
                // Top row: back button pinned leading, name capsule centered.
                ZStack {
                    nameCapsule(for: item, screenWidth: screenWidth)
                    HStack {
                        backButton
                        Spacer()
                    }
                }
                .padding(.top, topInset + 8)
                .padding(.horizontal, 16)

                Spacer(minLength: 0)

                if hasCaptionContent(for: item) {
                    infoPanel(for: item, screenWidth: screenWidth)
                        .padding(.bottom, bottomInset + 8)
                }
            }
        }
    }

    /// Species name in a liquid-glass capsule, top-center. Width-capped so a long
    /// name truncates instead of sliding under the back button.
    private func nameCapsule(for item: SpeciesPhotoItem, screenWidth: CGFloat) -> some View {
        Text(commonName(for: item))
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
            // Hug the name, but cap at `screenWidth - 150` (leaving room for the
            // back button + symmetric margin). A name that would overflow that cap
            // shrinks to fit rather than truncating.
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 18)
            .frame(height: Self.chromeHeight)
            .frame(maxWidth: screenWidth - 150)
            .glassEffect(.regular, in: .capsule)
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

    /// Bottom details — place (a blue, tappable link to the map), date, and photo
    /// attribution — in a liquid-glass panel. Non-link text is white like the
    /// name; the panel's width is capped for a generous margin from the edges.
    private func infoPanel(for item: SpeciesPhotoItem, screenWidth: CGFloat) -> some View {
        VStack(spacing: 12) {
            if let dateFound = item.dateFound {
                VStack(spacing: 3) {
                    if let place = item.placeName, !place.isEmpty {
                        // Tight spacing keeps the pin close to the place name.
                        let row = HStack(spacing: 4) {
                            Text(place)
                            Image(systemName: "mappin.circle")
                        }
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        if let onShowOnMap {
                            Button { onShowOnMap(item) } label: {
                                row.foregroundStyle(.blue)
                            }
                            .buttonStyle(NoDimButtonStyle())
                            .accessibilityLabel(mapButtonTitle ?? "Show on Map")
                        } else {
                            row.foregroundStyle(.white)
                        }
                    }
                    Text(dateFound, format: .dateTime.year().month(.abbreviated).day())
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }

            if let info = info(for: item) {
                VStack(spacing: 4) {
                    Text(info.attribution)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                    if let ebirdURL = info.ebirdURL {
                        Link("View on eBird", destination: ebirdURL)
                            .font(.caption2.weight(.semibold))
                            .tint(.blue)
                    }
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
        .frame(maxWidth: min(screenWidth - 80, 360))
        .glassEffect(.regular, in: .rect(cornerRadius: Self.chromeHeight / 2))
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
                // A short crossfade rather than an instant flip: driving the
                // appearance update inside a 0.1s UIView animation makes the
                // bar fade over that duration (paired with `.fade` below).
                UIView.animate(withDuration: 0.15) {
                    self.setNeedsStatusBarAppearanceUpdate()
                }
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
    let onIndexChange: (Int) -> Void
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

        // Stop the internal scroll view from insetting its content for the safe
        // area — that adjustment pinned the photo at the safe-area edge until the
        // dismiss-dragged card cleared it, then snapped it down. `.never` keeps the
        // photo in lockstep with the card from the first point. Deferred because
        // the scroll view isn't in the hierarchy yet during `make`.
        DispatchQueue.main.async {
            context.coordinator.pagingScrollView(in: pvc)?.contentInsetAdjustmentBehavior = .never
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // Cancels an in-progress paging pan the instant a dismiss engages.
        context.coordinator.pagingScrollView(in: pvc)?.isScrollEnabled = !pagingDisabled
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PhotoPager
        var currentIndex = 0

        init(_ parent: PhotoPager) { self.parent = parent }

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
            guard completed, let host = pvc.viewControllers?.first as? IndexedHost<Page> else { return }
            currentIndex = host.index
            parent.onIndexChange(host.index)
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
    /// Toggles the chrome's visibility; fired by a single tap on the photo.
    var onToggleUI: () -> Void
    /// Reports this page's zoom state up to the container.
    var onZoomChange: (Bool) -> Void

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var pageZoomed = false

    var body: some View {
        imageLayer
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .task(id: item.scientificName) { await load() }
            .onChange(of: pageZoomed) { _, zoomed in onZoomChange(zoomed) }
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let image {
            ZoomableImageView(
                image: image,
                isZoomed: $pageZoomed,
                resetToken: 0,
                onSingleTap: onToggleUI
            )
        } else if loadFailed {
            Image(systemName: "bird")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.4))
        } else {
            ProgressView().tint(.white)
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
    /// Fired by a single tap on the photo (toggles the viewer's chrome). Requires
    /// the double-tap-to-zoom to fail first, so a zoom double-tap doesn't also
    /// toggle the chrome.
    var onSingleTap: () -> Void

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

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1
        // Don't toggle the chrome when the tap is really the first half of a
        // double-tap zoom.
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)

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
        /// Set true if a pinch pushed the scale past the max or below the min at
        /// any point during the gesture; the boundary haptic then fires once when
        /// the pinch *ends*, not at the instant the threshold is crossed.
        private var didExceedLimit = false
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
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            // Fires after the rubber-band settle, not at finger lift, so the
            // boundary haptic is NOT triggered here — it's driven off the pinch
            // recognizer's `.ended` state instead (see `handlePinch`).
            (scrollView as? CenteringScrollView)?.centerContent()
            pushZoomed(scrollView)
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

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            parent.onSingleTap()
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
        // Only own the drag once zoomed; otherwise let SwiftUI page / dismiss.
        if gestureRecognizer == panGestureRecognizer {
            return zoomScale > minimumZoomScale + 0.001
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
