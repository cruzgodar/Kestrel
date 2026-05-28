import CoreLocation
import MapKit
import SwiftUI

struct MapView: View {
    @Environment(LifeListStore.self) private var store

    @State private var position: MapCameraPosition = .userLocation(
        fallback: .automatic
    )
    @State private var lastSpan: MKCoordinateSpan?
    @State private var lastCenter: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    /// Discrete zoom level — `floor(log2(camera.distance) * 4)`. Each unit
    /// is roughly a quarter-octave. We only rebuild clusters when this
    /// crosses a step, which keeps the cluster set stable between fine
    /// camera ticks during a pinch (vs. recomputing on every frame and
    /// flickering at boundary cases).
    @State private var lastZoomStep: Int?
    @State private var viewSize: CGSize = .zero

    /// Cached subset of `entriesWithCoordinates` whose coords fall inside
    /// the current viewport plus a generous buffer. Drives ForEach so we
    /// mount ~the visible neighborhood worth of annotations instead of
    /// every life-list bird. Updated only when the camera moves beyond
    /// the buffer, so panning doesn't churn the annotation list.
    @State private var visibleEntries: [LifeListEntry] = []
    @State private var lastFilterCenter: CLLocationCoordinate2D?
    @State private var lastFilterSpan: MKCoordinateSpan?
    /// One-shot guard for the post-load annotation refresh. See
    /// `warmUpAnnotations()`.
    @State private var didWarmUpAnnotations = false
    /// Buffer expressed in spans — render entries within 1.5× the visible
    /// region in each direction. Big enough that gentle panning never
    /// touches the ForEach set; small enough that we're not mounting the
    /// whole life list.
    private static let visibleBufferFactor: Double = 1.5

    /// Currently-visible cluster reps, keyed by scientific name. Every
    /// life-list entry with a coordinate gets its own persistent
    /// Annotation; this dict says which of those annotations should be
    /// opaque (and tappable) right now. State-driven opacity changes
    /// animate cleanly inside MapKit's hosted SwiftUI view, even though
    /// insert/remove transitions do not — that's the workaround for the
    /// "annotations never fade" problem.
    @State private var visibleReps: [String: RepInfo] = [:]

    @State private var expandedCluster: BirdCluster?

    /// Snapshot of a cluster's representative; what each annotation
    /// needs to know to render its label and respond to taps.
    struct RepInfo: Equatable {
        let count: Int
        let coordinate: CLLocationCoordinate2D
        let representative: LifeListEntry
        let others: [LifeListEntry]

        static func == (lhs: RepInfo, rhs: RepInfo) -> Bool {
            lhs.representative.scientificName == rhs.representative.scientificName
                && lhs.count == rhs.count
                && lhs.others.map(\.scientificName) == rhs.others.map(\.scientificName)
        }
    }

    /// Pinned thumbnail dimensions on the map. The total annotation
    /// occupies more space than this — see `Self.annotationFootprint`.
    private static let thumbSize = CGSize(width: 78, height: 60)
    /// Vertical space the label below the thumbnail typically eats up
    /// (capsule height + spacing). Counted as part of the annotation's
    /// footprint so the clustering threshold prevents the label of one
    /// annotation from sliding under a neighbor's image.
    private static let labelHeight: CGFloat = 26
    /// Typical horizontal extent of the on-map label capsule for a
    /// common bird name. Wider than the thumbnail; we cluster on the
    /// larger axis so two annotations' labels don't visually collide.
    private static let labelWidth: CGFloat = 110
    /// Slack added on top of the footprint when comparing centers.
    private static let clusterGutter: CGFloat = 4

    private static var annotationFootprint: CGSize {
        CGSize(
            width: max(thumbSize.width, labelWidth),
            height: thumbSize.height + 4 + labelHeight
        )
    }

    private var entriesWithCoordinates: [LifeListEntry] {
        store.entries.filter { $0.firstLatitude != nil && $0.firstLongitude != nil }
    }


    var body: some View {
        ZStack {
            GeometryReader { geo in
                Map(position: $position) {
                    UserAnnotation()
                    ForEach(visibleEntries) { entry in
                        Annotation(
                            entry.commonName,
                            coordinate: CLLocationCoordinate2D(
                                latitude: entry.firstLatitude ?? 0,
                                longitude: entry.firstLongitude ?? 0
                            ),
                            anchor: .center
                        ) {
                            FadingAnnotationContent(
                                entry: entry,
                                info: visibleReps[entry.scientificName],
                                thumbSize: Self.thumbSize,
                                onTap: { tappedInfo in
                                    expandedCluster = BirdCluster(
                                        representative: tappedInfo.representative,
                                        coordinate: tappedInfo.coordinate,
                                        others: tappedInfo.others
                                    )
                                }
                            )
                        }
                        .annotationTitles(.hidden)
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .onMapCameraChange(frequency: .continuous) { context in
                    handleCameraChange(context)
                }
                .onAppear { viewSize = geo.size }
                .onChange(of: geo.size) { _, new in
                    viewSize = new
                    updateVisibleEntries(force: true)
                    rebuildClusters(animated: false)
                }
                .onChange(of: store.entries) { _, _ in
                    updateVisibleEntries(force: true)
                    rebuildClusters(animated: true)
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .task {
            let manager = CLLocationManager()
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
            _ = await LocationCache.shared.current()
        }
        .sheet(item: $expandedCluster) { cluster in
            ClusterSheet(cluster: cluster)
        }
    }

    // MARK: - Camera + clustering

    private func handleCameraChange(_ context: MapCameraUpdateContext) {
        let span = context.region.span
        let center = context.region.center
        let distance = context.camera.distance

        // Quantize zoom into discrete steps so a continuous pinch doesn't
        // trigger a rebuild on every frame. The step boundary picks up
        // legitimate zoom-level transitions without flickering mid-pinch.
        let step = Int((log2(max(distance, 1)) * 4).rounded(.down))

        lastSpan = span
        lastCenter = center

        // Refresh the viewport-culled set whenever pan or zoom crosses a
        // meaningful threshold. Cheap relative to the cluster compute.
        updateVisibleEntries(force: false)

        if step == lastZoomStep { return }
        lastZoomStep = step
        rebuildClusters(animated: true)
    }

    /// Update the cached `visibleEntries` set. When `force` is false,
    /// skip the work if the camera hasn't moved beyond ~30% of the
    /// current span (so a gentle pan doesn't churn ForEach diffs).
    private func updateVisibleEntries(force: Bool) {
        guard let span = lastSpan else { return }

        if !force,
           let prevCenter = lastFilterCenter,
           let prevSpan = lastFilterSpan {
            let dLat = abs(lastCenter.latitude - prevCenter.latitude)
            let dLon = abs(lastCenter.longitude - prevCenter.longitude)
            let zoomDelta = abs(span.latitudeDelta - prevSpan.latitudeDelta) / prevSpan.latitudeDelta
            // Move threshold: 30% of the *previous* span; once the user
            // has panned that far the buffer would start running out.
            if dLat < prevSpan.latitudeDelta * 0.3
                && dLon < prevSpan.longitudeDelta * 0.3
                && zoomDelta < 0.3 {
                return
            }
        }

        let latRange = span.latitudeDelta * (0.5 + Self.visibleBufferFactor)
        let lonRange = span.longitudeDelta * (0.5 + Self.visibleBufferFactor)
        let centerLat = lastCenter.latitude
        let centerLon = lastCenter.longitude
        let filtered = entriesWithCoordinates.filter { entry in
            guard let lat = entry.firstLatitude,
                  let lon = entry.firstLongitude else { return false }
            return abs(lat - centerLat) <= latRange
                && abs(lon - centerLon) <= lonRange
        }
        visibleEntries = filtered
        lastFilterCenter = lastCenter
        lastFilterSpan = span
    }

    private func rebuildClusters(animated: Bool) {
        guard let span = lastSpan, viewSize.width > 0, viewSize.height > 0 else {
            return
        }
        let computed = Self.computeClusters(
            entries: entriesWithCoordinates,
            span: span,
            centerLatitude: lastCenter.latitude,
            viewSize: viewSize,
            footprint: Self.annotationFootprint,
            gutter: Self.clusterGutter
        )
        var next: [String: RepInfo] = [:]
        next.reserveCapacity(computed.count)
        for cluster in computed {
            next[cluster.representative.scientificName] = RepInfo(
                count: cluster.all.count,
                coordinate: cluster.coordinate,
                representative: cluster.representative,
                others: cluster.others
            )
        }
        guard next != visibleReps else { return }
        let wasEmpty = visibleReps.isEmpty
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) {
                visibleReps = next
            }
        } else {
            visibleReps = next
        }

        // First time we get real cluster data, schedule a one-shot
        // annotation refresh once MapKit has settled (see
        // `warmUpAnnotations`). This is what makes the stacks tappable on
        // first load without the user having to zoom first.
        if wasEmpty, !next.isEmpty, !didWarmUpAnnotations {
            didWarmUpAnnotations = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                warmUpAnnotations()
            }
        }
    }

    /// MapKit hosts each annotation view before its SwiftUI content
    /// exists on first load (cluster data arrives a beat after the map's
    /// initial layout), and it doesn't re-establish hit-testing for those
    /// hosts afterward — so the stacks render but don't respond to taps
    /// until a camera move triggers a fresh annotation layout. Briefly
    /// clearing and restoring the ForEach data forces MapKit to recreate
    /// the annotation views *with* content present, which wires up their
    /// tap handling. Runs exactly once.
    private func warmUpAnnotations() {
        guard !visibleEntries.isEmpty else { return }
        let saved = visibleEntries
        visibleEntries = []
        DispatchQueue.main.async {
            visibleEntries = saved
        }
    }

    static func computeClusters(
        entries: [LifeListEntry],
        span: MKCoordinateSpan,
        centerLatitude: Double,
        viewSize: CGSize,
        footprint: CGSize,
        gutter: CGFloat
    ) -> [BirdCluster] {
        guard !entries.isEmpty,
              viewSize.width > 0, viewSize.height > 0,
              span.latitudeDelta > 0 else { return [] }

        let degPerPoint = span.latitudeDelta / Double(viewSize.height)
        let thresholdLat = degPerPoint * Double(footprint.height + gutter)
        let cosLat = max(cos(centerLatitude * .pi / 180), 0.05)
        let thresholdLon = (degPerPoint * Double(footprint.width + gutter)) / cosLat

        let sorted = entries.sorted { $0.firstSeen > $1.firstSeen }

        struct WIP {
            let entry: LifeListEntry
            let lat: Double
            let lon: Double
            var others: [LifeListEntry] = []
        }
        var reps: [WIP] = []
        reps.reserveCapacity(sorted.count)

        for entry in sorted {
            guard let lat = entry.firstLatitude,
                  let lon = entry.firstLongitude else { continue }
            var folded = false
            for i in reps.indices {
                if abs(reps[i].lat - lat) < thresholdLat
                    && abs(reps[i].lon - lon) < thresholdLon {
                    reps[i].others.append(entry)
                    folded = true
                    break
                }
            }
            if !folded {
                reps.append(WIP(entry: entry, lat: lat, lon: lon))
            }
        }

        return reps.map {
            BirdCluster(
                representative: $0.entry,
                coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                others: $0.others
            )
        }
    }
}

// MARK: - Per-annotation fading wrapper
//
// MapKit's annotation host (a UIKit `MKAnnotationView` wrapping a
// `UIHostingController`) does *not* honor SwiftUI's `.allowsHitTesting`
// on its inner content. Any rendered subview — even one with opacity 0
// — still absorbs taps at the UIKit hit-test layer. That's why the
// previous "persistent annotation, fade via opacity" approach broke
// taps: invisible-but-rendered annotations were eating hits before the
// visible neighbor underneath could see them.
//
// The fix: when an entry isn't a current cluster rep, render *no
// content* inside the Annotation (an empty `if let`), so MapKit's
// hosting view collapses to zero size and can't absorb taps. When the
// entry *is* a rep, the content renders and a local opacity state
// drives a fade-in. When the entry leaves the rep set, we animate the
// opacity to zero first, then clear the rendered content. The
// animation pathway is preserved (we're tweening a state property on a
// mounted view, not a transition), and the dead annotations have no
// footprint.
private struct FadingAnnotationContent: View {
    let entry: LifeListEntry
    let info: MapView.RepInfo?
    let thumbSize: CGSize
    let onTap: (MapView.RepInfo) -> Void

    /// Mirror of `info` lagged behind by the fade-out animation. While
    /// the fade is running, `info` is already nil but `rendered` still
    /// holds the previous value so the content stays mounted long enough
    /// to be visible during the tween. Cleared in the animation's
    /// completion callback.
    @State private var rendered: MapView.RepInfo?
    @State private var opacity: Double = 0

    var body: some View {
        Group {
            if let rendered {
                MapAnnotationContent(
                    entry: entry,
                    clusterCount: rendered.count,
                    thumbSize: thumbSize
                )
                .contentShape(Rectangle())
                .opacity(opacity)
                .onTapGesture {
                    onTap(rendered)
                }
            }
        }
        .onChange(of: info, initial: true) { _, newInfo in
            handle(newInfo)
        }
    }

    private func handle(_ newInfo: MapView.RepInfo?) {
        if let newInfo {
            let wasOff = (rendered == nil)
            rendered = newInfo
            if wasOff {
                opacity = 0
                withAnimation(.easeInOut(duration: 0.3)) {
                    opacity = 1
                }
            }
            // If we were already visible we just refresh the count;
            // no fade needed since the user already sees this thumbnail.
        } else if rendered != nil {
            withAnimation(.easeInOut(duration: 0.3)) {
                opacity = 0
            } completion: {
                rendered = nil
            }
        }
    }
}

// MARK: - On-map annotation content (thumbnail + label)

private struct MapAnnotationContent: View {
    let entry: LifeListEntry
    let clusterCount: Int
    let thumbSize: CGSize

    private var labelText: String {
        clusterCount > 1 ? "\(clusterCount) Birds" : entry.commonName
    }

    var body: some View {
        VStack(spacing: 4) {
            BirdMapThumbnail(
                scientificName: entry.scientificName,
                size: thumbSize,
                cornerRadius: 8,
                showBorder: true
            )
            Text(labelText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.thinMaterial, in: Capsule())
        }
        // MapKit hosts each annotation in a UIHostingController whose
        // frame it derives once from the content's intrinsic size. The
        // label sits below the thumbnail, so when the host under-measures
        // the vertical extent it clips the label off entirely — which is
        // why "some" singletons showed no name. `.fixedSize()` forces the
        // VStack to report (and keep) its full intrinsic size so the
        // label area is always reserved.
        .fixedSize()
    }
}

// MARK: - Cluster model

struct BirdCluster: Identifiable, Hashable {
    let representative: LifeListEntry
    let coordinate: CLLocationCoordinate2D
    let others: [LifeListEntry]

    var id: String { representative.scientificName }
    var all: [LifeListEntry] { [representative] + others }

    static func == (lhs: BirdCluster, rhs: BirdCluster) -> Bool {
        lhs.id == rhs.id
            && lhs.others.map(\.scientificName) == rhs.others.map(\.scientificName)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(representative.scientificName)
        hasher.combine(others.map(\.scientificName))
    }
}

// MARK: - Native iOS 26 cluster sheet

private struct ClusterSheet: View {
    let cluster: BirdCluster
    @State private var detent: PresentationDetent = .medium

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 130), spacing: 12)]
    /// Tuned against the system sheet's top-corner radius at medium
    /// detent.
    private static let thumbCornerRadius: CGFloat = 26

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
                ForEach(cluster.all) { entry in
                    ClusterGridItem(
                        entry: entry,
                        cornerRadius: Self.thumbCornerRadius
                    )
                }
            }
            // Symmetric 12pt inset on all four sides. Bottom gets a bit
            // extra so the last row clears the home indicator at large
            // detent; visually that area is below the safe-area line
            // and the user reads it as "system" space, not "padding".
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .presentationDetents([.medium, .large], selection: $detent)
        // Hide the system grab handle — the sheet is still dismissable
        // by swiping anywhere downward.
        .presentationDragIndicator(.hidden)
        // Intentionally not setting `.presentationCornerRadius` — the
        // system default tracks the device's display corner radius, so
        // the sheet's bottom corners line up with the iPhone's screen
        // bottom corners instead of clipping outside them. Hard-coding a
        // radius (e.g. 28) was the source of the "clips past the
        // screen's curve" regression.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationBackground(.thinMaterial)
    }
}

/// Top-aligned cell so a 2-line caption doesn't shove its neighbor's
/// image down a row.
private struct ClusterGridItem: View {
    let entry: LifeListEntry
    let cornerRadius: CGFloat

    private static let thumbSize = CGSize(width: 116, height: 87)

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            BirdMapThumbnail(
                scientificName: entry.scientificName,
                size: Self.thumbSize,
                cornerRadius: cornerRadius,
                showBorder: false
            )
            Text(entry.commonName)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Thumbnail rendered on the map / inside the grid

private struct BirdMapThumbnail: View {
    let scientificName: String
    let size: CGSize
    var cornerRadius: CGFloat = 8
    /// White hairline border + shadow look right on the map but fight
    /// the frosted card. Caller picks.
    var showBorder: Bool = true

    var body: some View {
        Group {
            if let img = SpeciesImageCache.shared.image(for: scientificName) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray
                    .overlay {
                        Image(systemName: "bird")
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            if showBorder {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: 1.5)
            }
        }
        .shadow(
            color: .black.opacity(showBorder ? 0.3 : 0),
            radius: showBorder ? 3 : 0,
            x: 0,
            y: showBorder ? 1.5 : 0
        )
        .contentShape(Rectangle())
    }
}

#Preview {
    MapView()
        .environment(LifeListStore())
}
