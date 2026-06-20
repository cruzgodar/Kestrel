import CoreLocation
import MapKit
import SwiftUI

/// A single plotted point on the map. Usually one per life-list entry (its
/// first sighting), but with "Show repeat observations on map" enabled an
/// entry contributes one point per stored observation, so the same species can
/// appear at several locations. `id` is unique per point; `scientificName`
/// stays the species key used for photo lookups.
struct MapPoint: Identifiable, Hashable {
    let id: String
    let scientificName: String
    let commonName: String
    let date: Date
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Carries a request to focus the Map tab on a specific coordinate. Set from
/// the full-screen photo viewer's "Show on Map" / "Pinpoint on Map" button;
/// `MapView` observes `pendingFocus`, animates its camera there, then clears it.
@MainActor
@Observable
final class MapNavigator {
    var pendingFocus: MapFocus?

    func focus(latitude: Double, longitude: Double) {
        // A fresh token guarantees `onChange` fires even when the user asks to
        // focus the same coordinate twice in a row.
        pendingFocus = MapFocus(latitude: latitude, longitude: longitude, token: UUID())
    }
}

/// A one-shot map focus request. `token` makes otherwise-identical requests
/// distinct so SwiftUI's `onChange` always fires.
struct MapFocus: Equatable {
    let latitude: Double
    let longitude: Double
    let token: UUID

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct MapView: View {
    @Environment(LifeListStore.self) private var store
    @Environment(MapNavigator.self) private var navigator: MapNavigator?
    /// Drives whether repeat observations are plotted. `@Bindable` isn't needed
    /// (read-only here) but the `@Observable` model re-renders this view when
    /// the toggle flips.
    private var settings = AppSettings.shared

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

    /// Cached subset of `mapPoints` whose coords fall inside
    /// the current viewport plus a generous buffer. Drives ForEach so we
    /// mount ~the visible neighborhood worth of annotations instead of
    /// every life-list bird. Updated only when the camera moves beyond
    /// the buffer, so panning doesn't churn the annotation list.
    @State private var visiblePoints: [MapPoint] = []
    @State private var lastFilterCenter: CLLocationCoordinate2D?
    @State private var lastFilterSpan: MKCoordinateSpan?
    /// Set once the post-load annotation refresh has actually run (not merely
    /// been scheduled). See `warmUpAnnotations()`.
    @State private var didWarmUpAnnotations = false
    /// Guards against scheduling more than one in-flight warm-up chain at a
    /// time. Reset if the chain gives up so a later rebuild can re-arm it.
    @State private var warmUpScheduled = false
    /// Bounded retry counter for the warm-up — keeps it from looping forever if
    /// annotations never settle (e.g. the camera sits over an empty region).
    @State private var warmUpAttempts = 0
    private static let maxWarmUpAttempts = 8
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
    /// A lone (non-clustered) pin tapped on the map. Presented full-screen here
    /// without a map button — there's nowhere new to take the user.
    @State private var presentedSinglePoint: PresentedSpecies?

    /// Snapshot of a cluster's representative; what each annotation
    /// needs to know to render its label and respond to taps.
    struct RepInfo: Equatable {
        let count: Int
        let coordinate: CLLocationCoordinate2D
        let representative: MapPoint
        let others: [MapPoint]

        static func == (lhs: RepInfo, rhs: RepInfo) -> Bool {
            lhs.representative.id == rhs.representative.id
                && lhs.count == rhs.count
                && lhs.others.map(\.id) == rhs.others.map(\.id)
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

    /// All map points to plot. Always includes each species' earliest sighting
    /// (its displayed `first*` fields); when the setting is on, each stored
    /// repeat observation with coordinates contributes an additional point.
    private var mapPoints: [MapPoint] {
        var points: [MapPoint] = []
        let showRepeats = settings.showRepeatObservationsOnMap
        for entry in store.entries {
            if let lat = entry.firstLatitude, let lon = entry.firstLongitude {
                points.append(MapPoint(
                    id: entry.scientificName,
                    scientificName: entry.scientificName,
                    commonName: entry.commonName,
                    date: entry.firstSeen,
                    latitude: lat,
                    longitude: lon
                ))
            }
            guard showRepeats else { continue }
            for (i, obs) in entry.otherObservations.enumerated() {
                guard let lat = obs.latitude, let lon = obs.longitude else { continue }
                points.append(MapPoint(
                    id: "\(entry.scientificName)#\(i)",
                    scientificName: entry.scientificName,
                    commonName: entry.commonName,
                    date: obs.date,
                    latitude: lat,
                    longitude: lon
                ))
            }
        }
        return points
    }


    var body: some View {
        ZStack {
            GeometryReader { geo in
                Map(position: $position) {
                    UserAnnotation()
                    ForEach(visiblePoints) { point in
                        Annotation(
                            point.commonName,
                            coordinate: point.coordinate,
                            anchor: .center
                        ) {
                            FadingAnnotationContent(
                                point: point,
                                info: visibleReps[point.id],
                                thumbSize: Self.thumbSize,
                                onTap: { tappedInfo in
                                    // Multi-bird stacks open a card; a lone bird
                                    // opens its photo full-screen.
                                    if tappedInfo.count > 1 {
                                        expandedCluster = BirdCluster(
                                            representative: tappedInfo.representative,
                                            coordinate: tappedInfo.coordinate,
                                            others: tappedInfo.others
                                        )
                                    } else {
                                        // Present locally (not via the shared
                                        // presenter) so the full-screen viewer
                                        // shows no map button — a lone pin is
                                        // already pinpointed where you tapped.
                                        presentedSinglePoint = PresentedSpecies(
                                            scientificName: tappedInfo.representative.scientificName
                                        )
                                    }
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
                // Tapping the map background while a card is open closes
                // it. We catch the tap on a transparent overlay that only
                // exists while a card is open, rather than via
                // `.onTapGesture` on the Map itself: a tap gesture on the
                // Map is forced to wait for the map's double-tap-to-zoom
                // recognizer to fail before firing, which adds a visible
                // delay before the card dismisses. A plain overlay has no
                // such recognizer, so it fires the instant the tap ends.
                .overlay {
                    if expandedCluster != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                expandedCluster = nil
                            }
                    }
                }
                .onMapCameraChange(frequency: .continuous) { context in
                    handleCameraChange(context)
                }
                .onAppear { viewSize = geo.size }
                // Clusters before culling in every path (see handleCameraChange)
                // so annotation hosts always mount with their content present.
                .onChange(of: geo.size) { _, new in
                    viewSize = new
                    rebuildClusters(animated: false)
                    updateVisibleEntries(force: true)
                }
                .onChange(of: store.entries) { _, _ in
                    rebuildClusters(animated: true)
                    updateVisibleEntries(force: true)
                }
                // Flipping the repeat-observations setting changes the point
                // set, so rebuild the culled annotations and clusters.
                .onChange(of: settings.showRepeatObservationsOnMap) { _, _ in
                    rebuildClusters(animated: true)
                    updateVisibleEntries(force: true)
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
        // Focus requests can arrive while the Map tab is already on screen
        // (pinpoint from a cluster card) or just before it appears (Show on Map
        // from another tab) — handle both.
        .onChange(of: navigator?.pendingFocus) { _, _ in applyPendingFocus() }
        .onAppear { applyPendingFocus() }
        .sheet(item: $expandedCluster) { cluster in
            ClusterSheet(cluster: cluster) { point in
                expandedCluster = nil
                navigator?.focus(latitude: point.latitude, longitude: point.longitude)
            }
        }
        .fullScreenCover(item: $presentedSinglePoint) { species in
            SpeciesPhotoFullScreen(scientificName: species.scientificName)
        }
    }

    /// Consumes a pending focus request from `MapNavigator`, animating the
    /// camera to a tight region around the coordinate, then clears it.
    private func applyPendingFocus() {
        guard let focus = navigator?.pendingFocus else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            position = .region(MKCoordinateRegion(
                center: focus.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
        }
        navigator?.pendingFocus = nil
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

        // Rebuild clusters (which fills `visibleReps`, the annotation *content*)
        // before culling `visiblePoints` (which mounts the annotation *hosts*),
        // so each host is created with its content already present. If a host is
        // mounted while its rep info is still missing, it renders empty and
        // MapKit caches a zero-size hit area that it never re-measures — that's
        // the root cause of fresh stacks silently swallowing the first taps.
        if step != lastZoomStep {
            lastZoomStep = step
            rebuildClusters(animated: true)
        }

        // Refresh the viewport-culled set whenever pan or zoom crosses a
        // meaningful threshold. Cheap relative to the cluster compute.
        updateVisibleEntries(force: false)
    }

    /// Update the cached `visiblePoints` set. When `force` is false,
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
        let filtered = mapPoints.filter { point in
            abs(point.latitude - centerLat) <= latRange
                && abs(point.longitude - centerLon) <= lonRange
        }
        visiblePoints = filtered
        lastFilterCenter = lastCenter
        lastFilterSpan = span
    }

    private func rebuildClusters(animated: Bool) {
        guard let span = lastSpan, viewSize.width > 0, viewSize.height > 0 else {
            return
        }
        let computed = Self.computeClusters(
            points: mapPoints,
            span: span,
            centerLatitude: lastCenter.latitude,
            viewSize: viewSize,
            footprint: Self.annotationFootprint,
            gutter: Self.clusterGutter
        )
        var next: [String: RepInfo] = [:]
        next.reserveCapacity(computed.count)
        for cluster in computed {
            next[cluster.representative.id] = RepInfo(
                count: cluster.all.count,
                coordinate: cluster.coordinate,
                representative: cluster.representative,
                others: cluster.others
            )
        }
        guard next != visibleReps else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) {
                visibleReps = next
            }
        } else {
            visibleReps = next
        }

        // Once real cluster data exists, schedule the one-shot annotation
        // refresh (see `warmUpAnnotations`). Armed on the first rebuild that
        // produces clusters and not retried while a chain is already in flight;
        // the chain re-arms itself if it has to wait for annotations to settle.
        if !next.isEmpty, !didWarmUpAnnotations, !warmUpScheduled {
            warmUpScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
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
    /// tap handling. Runs at most once successfully; until then it retries a
    /// bounded number of times if the annotations haven't mounted yet, so a
    /// slow first layout can't leave the stacks permanently untappable.
    private func warmUpAnnotations() {
        guard !didWarmUpAnnotations else { return }
        // Nothing mounted to remount yet — wait and try again rather than
        // consuming the one-shot on an empty set (the bug where an early fire
        // left the stacks dead until the user happened to move the camera).
        guard !visiblePoints.isEmpty else {
            warmUpAttempts += 1
            if warmUpAttempts < Self.maxWarmUpAttempts {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    warmUpAnnotations()
                }
            } else {
                // Give up this chain; a future rebuild may re-arm it.
                warmUpScheduled = false
            }
            return
        }
        didWarmUpAnnotations = true
        let saved = visiblePoints
        visiblePoints = []
        DispatchQueue.main.async {
            visiblePoints = saved
        }
    }

    static func computeClusters(
        points: [MapPoint],
        span: MKCoordinateSpan,
        centerLatitude: Double,
        viewSize: CGSize,
        footprint: CGSize,
        gutter: CGFloat
    ) -> [BirdCluster] {
        guard !points.isEmpty,
              viewSize.width > 0, viewSize.height > 0,
              span.latitudeDelta > 0 else { return [] }

        let degPerPoint = span.latitudeDelta / Double(viewSize.height)
        let thresholdLat = degPerPoint * Double(footprint.height + gutter)
        let cosLat = max(cos(centerLatitude * .pi / 180), 0.05)
        let thresholdLon = (degPerPoint * Double(footprint.width + gutter)) / cosLat

        let sorted = points.sorted { $0.date > $1.date }

        struct WIP {
            let point: MapPoint
            let lat: Double
            let lon: Double
            var others: [MapPoint] = []
        }
        var reps: [WIP] = []
        reps.reserveCapacity(sorted.count)

        for point in sorted {
            let lat = point.latitude
            let lon = point.longitude
            var folded = false
            for i in reps.indices {
                if abs(reps[i].lat - lat) < thresholdLat
                    && abs(reps[i].lon - lon) < thresholdLon {
                    reps[i].others.append(point)
                    folded = true
                    break
                }
            }
            if !folded {
                reps.append(WIP(point: point, lat: lat, lon: lon))
            }
        }

        return reps.map {
            BirdCluster(
                representative: $0.point,
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
    let point: MapPoint
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
                    point: point,
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
    let point: MapPoint
    let clusterCount: Int
    let thumbSize: CGSize

    private var labelText: String {
        clusterCount > 1 ? "\(clusterCount) Birds" : point.commonName
    }

    var body: some View {
        VStack(spacing: 4) {
            BirdMapThumbnail(
                scientificName: point.scientificName,
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
    let representative: MapPoint
    let coordinate: CLLocationCoordinate2D
    let others: [MapPoint]

    var id: String { representative.id }
    var all: [MapPoint] { [representative] + others }

    static func == (lhs: BirdCluster, rhs: BirdCluster) -> Bool {
        lhs.id == rhs.id
            && lhs.others.map(\.id) == rhs.others.map(\.id)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(representative.id)
        hasher.combine(others.map(\.id))
    }
}

// MARK: - Native iOS 26 cluster sheet

private struct ClusterSheet: View {
    let cluster: BirdCluster
    /// Invoked when the user taps "Pinpoint on Map" in the full-screen viewer.
    /// The parent closes this sheet and focuses the map on the tapped point.
    let onShowOnMap: (MapPoint) -> Void
    @State private var detent: PresentationDetent = .medium
    /// Local full-screen presentation. Presenting from the sheet's own context
    /// (rather than the root presenter) avoids a nested-presentation conflict
    /// with this sheet. Holds the tapped point so its coordinate is available
    /// for the "Pinpoint on Map" action.
    @State private var presentedPoint: MapPoint?

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 130), spacing: 12)]
    /// Tuned against the system sheet's top-corner radius at medium
    /// detent.
    private static let thumbCornerRadius: CGFloat = 26

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
                ForEach(cluster.all) { point in
                    ClusterGridItem(
                        point: point,
                        cornerRadius: Self.thumbCornerRadius
                    )
                    .onTapGesture {
                        presentedPoint = point
                    }
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
        .fullScreenCover(item: $presentedPoint) { point in
            SpeciesPhotoFullScreen(
                scientificName: point.scientificName,
                mapButtonTitle: "Pinpoint on Map",
                onShowOnMap: {
                    // Dismiss the whole card (the sheet) directly — that tears
                    // down this full-screen cover along with it, so the card is
                    // already gone the moment the photo finishes dismissing,
                    // rather than lingering until the zoom completes. (Clearing
                    // `presentedPoint` first would dismiss the cover alone and
                    // leave the card behind underneath.)
                    onShowOnMap(point)
                }
            )
        }
    }
}

/// Top-aligned cell so a 2-line caption doesn't shove its neighbor's
/// image down a row.
private struct ClusterGridItem: View {
    let point: MapPoint
    let cornerRadius: CGFloat

    private static let thumbSize = CGSize(width: 116, height: 87)

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            BirdMapThumbnail(
                scientificName: point.scientificName,
                size: Self.thumbSize,
                cornerRadius: cornerRadius,
                showBorder: false
            )
            Text(point.commonName)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
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
        // No attribution caption on map thumbnails (pins or card) — it's shown
        // in the full-screen viewer instead. Taps are handled by the map
        // (annotation / cluster grid), not SpeciesPhoto, so they don't fight
        // MapKit's annotation hit-testing.
        SpeciesPhoto(scientificName: scientificName, showsCredit: false, tappable: false) {
            Color.gray
                .overlay {
                    Image(systemName: "bird")
                        .foregroundStyle(.white)
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
