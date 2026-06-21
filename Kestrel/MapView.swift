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
    /// Debounce token for the post-zoom hit-test rehydration (see
    /// `scheduleHitTestRehydration`). Bumped on every cluster change so only
    /// the last one in a continuous pinch actually fires the remount.
    @State private var rehydrateToken = 0
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

    /// The single bottom card currently presented — either a multi-bird cluster
    /// or the map-options settings. Both share one `.sheet(isPresented:)` so that
    /// switching from one to the other (or from one cluster to another) swaps the
    /// sheet's content live, rather than dismissing the old card and waiting for
    /// it to close before presenting the new one. The native sheet is what keeps
    /// the card's corners concentric with the device's display radius and its
    /// layering correct; the content crossfades on a swap (see `MapCardSheet`),
    /// the map stays live behind it, and a tap on the empty map dismisses it.
    @State private var mapCard: MapCard?
    /// A lone (non-clustered) pin tapped on the map. Presented full-screen here
    /// without a map button — there's nowhere new to take the user.
    @State private var presentedSinglePoint: PresentedSpecies?

    /// The two kinds of bottom card the map can show. Routed through a single
    /// sheet (see `mapCard`) so re-targeting it never tears the sheet down.
    enum MapCard: Identifiable {
        case cluster(BirdCluster)
        case settings

        var id: String {
            switch self {
            case .cluster(let cluster): return "cluster-" + cluster.id
            case .settings:             return "settings"
            }
        }
    }

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
                // Rotation (and the 3D pitch that rides with it) is disabled —
                // a birding map only ever wants north-up pan + zoom, and a
                // stray two-finger twist that tilts/spins the map is pure
                // annoyance here.
                Map(position: $position, interactionModes: [.pan, .zoom]) {
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
                                    // Multi-bird stacks open (or swap to) a card.
                                    if tappedInfo.count > 1 {
                                        mapCard = .cluster(BirdCluster(
                                            representative: tappedInfo.representative,
                                            coordinate: tappedInfo.coordinate,
                                            others: tappedInfo.others
                                        ))
                                    } else {
                                        // A lone bird opens its photo full-screen.
                                        // Drop any open card *without* a dismiss
                                        // animation first, so the sheet is gone
                                        // immediately and the root cover presents
                                        // right away instead of waiting for the
                                        // sheet's slide-down to finish.
                                        if mapCard != nil {
                                            var t = Transaction()
                                            t.disablesAnimations = true
                                            withTransaction(t) { mapCard = nil }
                                        }
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
                    // The recenter control is provided as a custom glass button
                    // (see the top-trailing overlay) so it can stack beneath the
                    // map-settings button; only the compass stays a map control.
                    MapCompass()
                }
                // A single tap on the empty map dismisses whatever card is open.
                // This rides on the map's *own* tap gesture rather than a
                // tap-catching overlay, so it only fires on genuine taps — drags
                // still pan/zoom the map untouched, and taps that land on an
                // annotation are consumed by that annotation (opening another
                // bird / cluster) instead of bubbling here. That's what lets the
                // map stay fully live behind the card.
                .onTapGesture {
                    if mapCard != nil { mapCard = nil }
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

            // Liquid-glass controls pinned to the top-right, laid out side by
            // side to mirror the Life List tab's two trailing buttons: a
            // recenter button on the left and the map-settings button on the
            // right (replacing the stock MapUserLocationButton).
            HStack(spacing: 12) {
                GlassMapButton(systemImage: "location.fill", accessibility: "Center on current location") {
                    Task {
                        guard let coord = await LocationCache.shared.current() else { return }
                        withAnimation(.easeInOut(duration: 0.45)) {
                            position = .region(MKCoordinateRegion(
                                center: CLLocationCoordinate2D(
                                    latitude: coord.latitude,
                                    longitude: coord.longitude
                                ),
                                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                            ))
                        }
                    }
                }
                GlassMapButton(systemImage: "gearshape", accessibility: "Map settings") {
                    mapCard = .settings
                }
            }
            .padding(.top, 8)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
        // One sheet for both cards. Bound to `isPresented` (not `item`) so
        // re-pointing `mapCard` swaps the content live; `MapCardSheet` crossfades
        // between cards, keeps the map interactive behind it, and never dims it.
        .sheet(isPresented: Binding(
            get: { mapCard != nil },
            set: { if !$0 { mapCard = nil } }
        )) {
            MapCardSheet(card: mapCard) { point in
                // "Pinpoint on Map" from a bird inside a cluster card.
                mapCard = nil
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
        } else if didWarmUpAnnotations {
            // After the initial load, every *subsequent* cluster change (most
            // commonly a pinch that merges/splits stacks) re-mounts the
            // annotations once the camera settles, so MapKit re-measures the
            // hosts whose footprint changed. Without this, a freshly-formed
            // stack renders but keeps the stale (often zero-size) hit area
            // MapKit cached for the host's previous content — taps fall
            // straight through to the map until the next interaction.
            scheduleHitTestRehydration()
        }
    }

    /// Debounced remount of the annotation hosts to refresh MapKit's cached
    /// hit areas after the cluster set changes. Coalesces a continuous pinch
    /// into a single remount fired ~0.25 s after the last change, so it doesn't
    /// churn mid-gesture. The remount itself is visually silent — annotations
    /// that are still reps reappear solid (see `FadingAnnotationContent`), no
    /// re-fade.
    private func scheduleHitTestRehydration() {
        rehydrateToken &+= 1
        let token = rehydrateToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard token == rehydrateToken, !visiblePoints.isEmpty else { return }
            let saved = visiblePoints
            visiblePoints = []
            DispatchQueue.main.async { visiblePoints = saved }
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
    /// False until the first `info` resolution after this view mounts. Lets us
    /// distinguish a genuine first appearance (or a hit-test rehydration
    /// remount, which destroys + recreates this view) — which should settle to
    /// its final opacity instantly — from a later transition while mounted,
    /// which should animate. This keeps the post-pinch remount silent instead
    /// of flashing every thumbnail through a fresh fade-in.
    @State private var didResolve = false

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
        // First resolution after mount (incl. a rehydration remount): jump
        // straight to the final opacity with no animation, so re-creating an
        // already-visible annotation doesn't replay its fade-in.
        if !didResolve {
            didResolve = true
            rendered = newInfo
            opacity = newInfo == nil ? 0 : 1
            return
        }
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

// MARK: - The shared map card (native sheet)

/// Hosts both map cards inside one native sheet. The sheet itself stays mounted
/// while `card` changes, so the body just crossfades between the cluster grid and
/// the settings pane (keyed by `card.id`) instead of tearing the sheet down and
/// re-presenting it — that's the in-place swap the user sees when tapping a
/// second cluster, or the gear, while a card is already open.
///
/// Presentation modifiers are applied here (once, uniformly) rather than per
/// card, so *both* cards get the frosted, non-dimming, background-interactive
/// treatment: the map stays live behind either one, you can tap another bird /
/// the gear to swap, and a tap on the empty map dismisses (handled by the map's
/// own tap gesture in `MapView`).
private struct MapCardSheet: View {
    let card: MapView.MapCard?
    /// "Pinpoint on Map" for a bird tapped inside a cluster card.
    let onPinpoint: (MapPoint) -> Void

    @State private var detent: PresentationDetent = .medium
    /// Full-screen photo presented from *this sheet's* context (not the root) so
    /// it doesn't collide with the sheet's own presentation. Holds the tapped
    /// point so its coordinate is available to "Pinpoint on Map".
    @State private var presentedPoint: MapPoint?

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 130), spacing: 12)]
    private static let thumbCornerRadius: CGFloat = 26

    var body: some View {
        ZStack {
            switch card {
            case .cluster(let cluster):
                clusterGrid(cluster)
                    .id("cluster-" + cluster.id)
                    .transition(.opacity)
            case .settings:
                MapSettingsContent()
                    .id("settings")
                    .transition(.opacity)
            case .none:
                Color.clear
            }
        }
        // Crossfade whenever the card identity changes (cluster→cluster,
        // cluster→settings, …). The sheet host is unaffected; only the contents
        // animate, so the swap reads as a smooth dissolve rather than a snap.
        .animation(.easeInOut(duration: 0.22), value: card?.id)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        // Keep the map interactive (and undimmed) behind the card at the medium
        // detent — this is what lets you open other things from either card and
        // tap the map to dismiss. At .large the sheet is modal, as expected.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        // Intentionally not setting `.presentationCornerRadius` — the system
        // default tracks the device's display corner radius so the card's bottom
        // corners stay concentric with the screen's curve.
        .presentationBackground(.thinMaterial)
        .fullScreenCover(item: $presentedPoint) { point in
            SpeciesPhotoFullScreen(
                scientificName: point.scientificName,
                mapButtonTitle: "Pinpoint on Map",
                onShowOnMap: { onPinpoint(point) }
            )
        }
    }

    private func clusterGrid(_ cluster: BirdCluster) -> some View {
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
            // Symmetric 12pt inset; a bit more at the bottom so the last row
            // clears the home indicator at the large detent.
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 24)
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

// MARK: - Top-right glass controls

/// A circular liquid-glass map control, matching the search field's glass
/// buttons. Used for the map-settings and recenter buttons.
private struct GlassMapButton: View {
    let systemImage: String
    let accessibility: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .padding(11)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(NoDimButtonStyle())
        .accessibilityLabel(accessibility)
    }
}

// MARK: - Map options card

/// The card opened from the map's settings button. Mirrors the import card's
/// look and holds the single "Show Repeat Observations on Map" toggle that
/// formerly lived in the Settings tab.
private struct MapSettingsContent: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                Text("Map Options")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Show Repeat Observations on Map",
                    isOn: $settings.showRepeatObservationsOnMap
                )
                .font(.body.weight(.semibold))
                Text("Show every recorded observation of a species on the map, rather than only the earliest.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }
}

#Preview {
    MapView()
        .environment(LifeListStore())
}
