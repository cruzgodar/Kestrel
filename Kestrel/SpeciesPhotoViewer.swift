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

            // Each bird gets a `pageSpacing` blank gutter between it and the
            // next, like the iOS Photos app. Implemented by making the paging
            // TabView `pageSpacing` wider than the screen (so each page carries
            // an extra `pageSpacing` of width), constraining each photo to the
            // true screen width and centering it within its page (leaving
            // `pageSpacing/2` of black on each side), then shifting the whole
            // TabView left by `pageSpacing/2` so the current photo still fills
            // the screen edge-to-edge. The black gutter only shows mid-swipe.
            //
            // Wrapped in a GeometryReader that places the deliberately over-wide
            // (screen + pageSpacing) TabView at its top-LEADING corner. A bare
            // ZStack instead CENTERS the over-wide TabView, so the `-pageSpacing/2`
            // shift then lands the photo `pageSpacing/2` too far left with a black
            // gap on the right (measured scrollX=-12). The GeometryReader is pinned
            // to the constant `fullHeight`, so `geo.size` never churns under the
            // drag — keeping the photo's viewport (and centering) rock-steady,
            // which is what removed the vertical jitter.
            GeometryReader { geo in
                TabView(selection: $index) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                        ZoomablePhotoPage(
                            item: item,
                            isCurrent: offset == index,
                            isZoomed: $isZoomed,
                            uiVisible: uiVisible,
                            topInset: proxy.safeAreaInsets.top,
                            bottomInset: proxy.safeAreaInsets.bottom,
                            // While the dismiss drag is active the whole card
                            // (photo + chrome) slides as one, so the glass never
                            // moves relative to what's behind it — swap it for a
                            // cheap static fill to avoid re-rendering glass every
                            // frame (the slide was janky otherwise).
                            staticChrome: dragOffset.height > 0,
                            mapButtonTitle: mapButtonTitle,
                            onShowOnMap: onShowOnMap.map { action in { action(item) } },
                            onClose: { dismissViewer() },
                            onToggleUI: {
                                withAnimation(.easeInOut(duration: 0.25)) { uiVisible.toggle() }
                            }
                        )
                        .frame(width: geo.size.width)
                        .frame(maxWidth: .infinity)
                        .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // No paging while zoomed — the scroll view's pan owns the drag —
                // and none once a downward dismiss drag has engaged, so a diagonal
                // swipe can't page to another bird mid-dismiss; down strictly
                // dismisses.
                .scrollDisabled(isZoomed || dismissEngaged)
                .frame(width: geo.size.width + pageSpacing, height: geo.size.height)
                .offset(x: -pageSpacing / 2)
            }
            .frame(width: screenWidth, height: fullHeight)
            // NB: the close button now lives *inside* each page (top-trailing of
            // `ZoomablePhotoPage`) so it pages left/right with the bird, level
            // with that bird's name capsule.
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

/// A single zoomable page within the viewer: the photo (pinch + pan + double-tap
/// zoom, all driven by a `UIScrollView`) and its caption. Reports its zoom state
/// up so the container can disable paging while zoomed, and resets zoom when it
/// scrolls off-screen.
private struct ZoomablePhotoPage: View {
    let item: SpeciesPhotoItem
    let isCurrent: Bool
    @Binding var isZoomed: Bool
    /// Whether the floating chrome (name capsule, bottom details) is shown.
    var uiVisible: Bool
    /// Top / bottom safe-area insets (constants from the viewer's stable outer
    /// proxy). The chrome is positioned off these rather than the live safe area,
    /// which is consumed by the container's `.ignoresSafeArea()`.
    var topInset: CGFloat
    var bottomInset: CGFloat
    /// True while a dismiss drag is in progress. The glass chrome is then drawn
    /// as a cheap static fill instead of live liquid glass, since the whole card
    /// slides as one and the glass isn't moving relative to anything behind it —
    /// re-rendering glass every frame made the slide janky.
    var staticChrome: Bool
    var mapButtonTitle: String?
    /// Pre-bound to this page's bird (the container curries the item in).
    var onShowOnMap: (() -> Void)?
    /// Dismisses the viewer (the per-page close button).
    var onClose: () -> Void
    /// Toggles the chrome's visibility; fired by a single tap on the photo.
    var onToggleUI: () -> Void

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
            imageLayer
                .ignoresSafeArea()

            // All floating chrome lives in this VStack — name + close button at
            // the top, details at the bottom — so it shares the photo's layout
            // and tracks the dismiss-drag offset 1:1 (the name no longer lagged as
            // a separate overlay). Forced to a dark color scheme so the glass and
            // its text read as the immersive viewer's dark chrome from the first
            // frame, rather than flashing light before adapting.
            VStack(spacing: 0) {
                topChrome
                    .opacity(uiVisible ? 1 : 0)
                    // When hidden, don't intercept taps — they fall through to the
                    // photo so a tap anywhere brings the chrome back. (Opacity 0
                    // alone still hit-tests.) The Spacer is left tappable-through.
                    .allowsHitTesting(uiVisible)
                Spacer(minLength: 0)
                caption
                    .opacity(uiVisible ? 1 : 0)
                    .allowsHitTesting(uiVisible)
            }
            .colorScheme(.dark)
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
                resetToken: resetToken,
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

    /// Height of the top chrome controls. The close button is a 22pt glyph with
    /// 13pt padding (a 48pt tap target); the name capsule matches it so the two
    /// sit on the same line, and the bottom panel's corner radius is half of it.
    private static let chromeHeight: CGFloat = 48

    /// Name capsule (leading) + close button (trailing), level with each other.
    /// Lives inside each page so it pages with the bird.
    private var topChrome: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(commonName)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 18)
                .frame(height: Self.chromeHeight)
                .modifier(ChromeGlass(shape: .capsule, isStatic: staticChrome))

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 22, height: 22)
                    .padding(13)
                    .modifier(ChromeGlass(shape: .circle, isStatic: staticChrome, interactive: true))
                    .contentShape(Circle())
            }
            .buttonStyle(NoDimButtonStyle())
            .accessibilityLabel("Close")
        }
        .padding(.top, topInset + 8)
        .padding(.horizontal, 16)
    }

    /// True when the bottom panel has anything to show. With the name now at the
    /// top, a non-lifer with no metadata has an empty caption — render nothing
    /// so no blank black bar appears.
    private var hasCaptionContent: Bool {
        item.dateFound != nil || info != nil
    }

    @ViewBuilder
    private var caption: some View {
        if hasCaptionContent {
        // Spacing of 12 widens the gap the user asked for — date → attribution —
        // while the place/date pair stays tight (its own VStack spacing).
        VStack(spacing: 12) {
            // Sighting: where + when. Only for lifers
            // (a date is always recorded); the place name is the map tap target,
            // with the pin-in-circle glyph to its right.
            if let dateFound = item.dateFound {
                VStack(spacing: 3) {
                    if let place = item.placeName, !place.isEmpty {
                        // Location shrunk to subheadline to match the date below.
                        // Tight spacing keeps the pin close to the place name.
                        let row = HStack(spacing: 4) {
                            Text(place)
                            Image(systemName: "mappin.circle")
                        }
                        .font(.subheadline)
                        // Blue, link-style, when it's tappable (focuses the map);
                        // plain primary when there's nothing to tap.
                        .foregroundStyle(onShowOnMap != nil ? AnyShapeStyle(.blue) : AnyShapeStyle(.primary))
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
                        .foregroundStyle(.secondary)
                }
            }

            // Attribution + eBird link, below the sighting info.
            if let info {
                VStack(spacing: 4) {
                    Text(info.attribution)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let ebirdURL = info.ebirdURL {
                        Link("View on eBird", destination: ebirdURL)
                            .font(.caption2.weight(.semibold))
                            .tint(.accentColor)
                    }
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
        // Liquid-glass panel hugging the details, floating above the home
        // indicator (positioned off the constant bottom inset since the container
        // consumes the live safe area). Corner radius is half the close button's
        // size so the two read as the same family.
        .modifier(ChromeGlass(shape: .rect(cornerRadius: Self.chromeHeight / 2), isStatic: staticChrome))
        .padding(.bottom, bottomInset + 8)
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

/// Backs the viewer's floating chrome with liquid glass — except while a dismiss
/// drag is active (`isStatic`), when it falls back to a cheap translucent fill.
/// During the drag the whole card slides as one, so the glass never moves
/// relative to what's behind it; rendering live glass every frame just churned
/// the GPU and stuttered the slide. The static fill is dark to match the glass's
/// dark-scheme appearance, so the swap isn't visible in motion.
private struct ChromeGlass<S: Shape>: ViewModifier {
    let shape: S
    let isStatic: Bool
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if isStatic {
            content.background(Color.black.opacity(0.55), in: shape)
        } else {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        }
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
