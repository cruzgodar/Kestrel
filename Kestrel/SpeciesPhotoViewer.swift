import SwiftUI

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
/// photos. Horizontal swipes page between birds (with the system's page-style
/// inertia + end rubberbanding); a single-item viewer has nothing to page to. A
/// downward drag (only when not zoomed) slides the whole card off to dismiss.
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

    /// Past this much downward travel, release dismisses.
    private let dismissThreshold: CGFloat = 120

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
            // No paging while zoomed — the pan inside the photo owns the drag.
            .scrollDisabled(isZoomed)

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
                if value.translation.height > dismissThreshold,
                   abs(value.translation.height) > abs(value.translation.width) {
                    dismissViewer()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    /// Slides the whole card off the bottom — preserving the swipe-down feel —
    /// and only cross-fades in the final beat of the slide (rather than fading
    /// throughout). The cover is then removed without its own animation so the
    /// slide is the only motion seen.
    private func dismissViewer() {
        withAnimation(.easeIn(duration: 0.28)) {
            dragOffset = CGSize(width: 0, height: viewSize.height + 300)
        }
        withAnimation(.easeIn(duration: 0.12).delay(0.16)) {
            contentOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }
}

/// A single zoomable page within the viewer: the photo (pinch + pan + double-tap
/// zoom) and its caption. Reports its zoom state up so the container can disable
/// paging while zoomed, and resets zoom when it scrolls off-screen.
private struct ZoomablePhotoPage: View {
    let item: SpeciesPhotoItem
    let isCurrent: Bool
    @Binding var isZoomed: Bool
    var mapButtonTitle: String?
    /// Pre-bound to this page's bird (the container curries the item in).
    var onShowOnMap: (() -> Void)?

    @State private var image: UIImage?
    @State private var loadFailed = false

    // Zoom + pan. Anchored zoom (about the pinch midpoint) keeps panning and
    // zooming on separate state — `scale`/`zoomAnchor` for the pinch,
    // `panOffset` for the drag — so the two gestures never fight over the same
    // value, which is what keeps the interaction smooth.
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var zoomAnchor: UnitPoint = .center
    @State private var panOffset: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    /// True for the duration of a pinch, so its one-time anchor compensation
    /// runs only on the first change event.
    @State private var magnifying = false
    /// This page's measured size, used to compensate the offset when the pinch
    /// anchor changes between gestures (so the image doesn't snap around).
    @State private var pageSize: CGSize = CGSize(width: 400, height: 800)

    /// Maximum pinch-zoom; zooming past it rubberbands and eases back.
    private let maxScale: CGFloat = 4

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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { pageSize = $0 }
        .contentShape(Rectangle())
        .simultaneousGesture(magnify)
        .simultaneousGesture(panWhenZoomed)
        .onTapGesture(count: 2) { toggleZoom() }
        .task(id: item.scientificName) { await load() }
        // Keep the container's paging/dismiss gate in sync with this page, and
        // reset zoom when the page scrolls away so it isn't left zoomed. The
        // guard avoids rewriting the binding on every frame of a pinch.
        .onChange(of: scale) { _, _ in
            guard isCurrent else { return }
            let zoomed = scale > 1.01
            if zoomed != isZoomed { isZoomed = zoomed }
        }
        .onChange(of: isCurrent) { _, current in
            if current {
                isZoomed = scale > 1.01
            } else {
                resetZoom()
            }
        }
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale, anchor: zoomAnchor)
                .offset(panOffset)
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
        VStack(spacing: 8) {
            // Species name — a touch larger than the metadata below it.
            Text(commonName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            // Sighting: where + when, directly under the name. Only for lifers
            // (a date is always recorded); the place name is the map tap target,
            // with the pin-in-circle glyph to its right.
            if let dateFound = item.dateFound {
                VStack(spacing: 2) {
                    if let place = item.placeName, !place.isEmpty {
                        let row = HStack(spacing: 6) {
                            Text(place)
                            Image(systemName: "mappin.circle")
                        }
                        .font(.headline)
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

    // MARK: - Gestures

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !magnifying {
                    magnifying = true
                    // Switching the scale anchor between gestures would visibly
                    // jump the image; compensate the offset so it stays put.
                    let a0 = CGPoint(x: zoomAnchor.x * pageSize.width,
                                     y: zoomAnchor.y * pageSize.height)
                    let a1 = CGPoint(x: value.startAnchor.x * pageSize.width,
                                     y: value.startAnchor.y * pageSize.height)
                    let f = 1 - scale
                    panOffset = CGSize(
                        width: panOffset.width + (a0.x - a1.x) * f,
                        height: panOffset.height + (a0.y - a1.y) * f
                    )
                    lastPan = panOffset
                    zoomAnchor = value.startAnchor
                }
                let raw = lastScale * value.magnification
                if raw > maxScale {
                    // Diminishing resistance past the max — the standard
                    // overscroll feel.
                    scale = maxScale + (raw - maxScale) * 0.3
                } else {
                    scale = max(raw, 1)
                }
            }
            .onEnded { _ in
                magnifying = false
                if scale > maxScale {
                    // Ease straight back to the limit — no spring overshoot.
                    withAnimation(.easeOut(duration: 0.25)) { scale = maxScale }
                    lastScale = maxScale
                } else if scale <= 1 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scale = 1
                        panOffset = .zero
                    }
                    lastScale = 1
                    lastPan = .zero
                } else {
                    lastScale = scale
                }
            }
    }

    /// Pans the zoomed image. A no-op (and so doesn't capture) at rest, leaving
    /// the drag for the container's paging / dismiss.
    private var panWhenZoomed: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                panOffset = CGSize(
                    width: lastPan.width + value.translation.width,
                    height: lastPan.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard scale > 1 else { return }
                lastPan = panOffset
            }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if scale > 1 {
                scale = 1
                panOffset = .zero
            } else {
                zoomAnchor = .center
                scale = 2
                panOffset = .zero
            }
            lastScale = scale
            lastPan = panOffset
        }
    }

    private func resetZoom() {
        scale = 1
        lastScale = 1
        panOffset = .zero
        lastPan = .zero
        zoomAnchor = .center
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
