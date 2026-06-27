import CoreLocation
import MapKit
import SwiftUI
import UIKit

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
    /// Human-readable place name for this sighting (the CSV's Location column),
    /// shown in the full-screen photo viewer alongside the date. `nil` when the
    /// observation was logged without a location.
    let location: String?
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
    /// Per-frame camera bookkeeping (latest span/center, last zoom step, last
    /// cull center/span). Held in a plain reference type — NOT as individual
    /// `@State` — so the `.continuous` camera callback can record the latest
    /// values every frame without invalidating the view. As `@State`, writing
    /// `lastSpan`/`lastCenter` on every pan frame re-evaluated the whole map body
    /// (re-running the annotation ForEach) each frame, which is what made plain
    /// panning lag. None of these are read in `body`; only the actual rendered
    /// state (`visiblePoints`, `visibleReps`, clusters) is, and that's updated
    /// only when a threshold is crossed.
    @State private var camera = CameraTracker()
    /// Drives the recenter button glyph: filled (`location.fill`) right after a
    /// recenter tap, outline (`location`) otherwise. Set true on tap and cleared
    /// by the next user-driven camera move — there is no re-fill logic; only a
    /// tap fills it again.
    @State private var centeredOnUser = false
    /// Camera changes before this time are ignored when clearing
    /// `centeredOnUser`, so the recenter animation's own camera callbacks don't
    /// immediately flip the freshly-filled button back to an outline.
    @State private var recenterGraceUntil: Date = .distantPast
    /// Discrete zoom level — `floor(log2(camera.distance) * 4)`. Each unit
    /// is roughly a quarter-octave. We only rebuild clusters when this
    /// crosses a step, which keeps the cluster set stable between fine
    /// camera ticks during a pinch (vs. recomputing on every frame and
    /// flickering at boundary cases). Lives on `camera` (see above).
    @State private var viewSize: CGSize = .zero

    /// Cached subset of `mapPoints` whose coords fall inside
    /// the current viewport plus a generous buffer. Drives ForEach so we
    /// mount ~the visible neighborhood worth of annotations instead of
    /// every life-list bird. Updated only when the camera moves beyond
    /// the buffer, so panning doesn't churn the annotation list.
    @State private var visiblePoints: [MapPoint] = []
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
    /// A lone (non-clustered) pin tapped on the map *while no card is open*.
    /// Presented full-screen from the root without a map button — there's nowhere
    /// new to take the user.
    @State private var presentedSinglePoint: MapPoint?
    /// A full-screen photo presented from *inside* the open card's sheet (so it
    /// appears instantly, with no wait for the sheet to dismiss): either a bird
    /// tapped in a cluster grid (`.pinpoint`, keeps the card) or a lone pin
    /// tapped on the map while a card is open (`.lone`, closes the card on exit).
    @State private var sheetPhoto: MapSheetPhoto?
    /// When an annotation was last tapped. The map's own tap-to-dismiss gesture
    /// recognizes simultaneously (so it isn't delayed waiting for double-tap), so
    /// it also sees taps that land on an annotation; this lets it tell those
    /// apart from genuine empty-map taps and skip dismissing for them.
    /// Set by an annotation tap and consumed by the map's simultaneous
    /// dismiss gesture on the same touch, so a tap that opened/swapped a card
    /// doesn't also dismiss it. A boolean token rather than a timestamp — see
    /// the dismiss gesture for why.
    @State private var annotationTapConsumed = false

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
                    location: entry.firstLocation,
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
                    location: obs.location,
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
                            // Snap instantly (the default) or fade in/out, per the
                            // map settings. Both collapse to zero size when not a
                            // current cluster rep so dead annotations never eat taps.
                            if settings.fadeMapThumbnails {
                                FadingAnnotationContent(
                                    point: point,
                                    info: visibleReps[point.id],
                                    thumbSize: Self.thumbSize,
                                    onTap: handleAnnotationTap
                                )
                            } else {
                                CulledAnnotationContent(
                                    point: point,
                                    info: visibleReps[point.id],
                                    thumbSize: Self.thumbSize,
                                    onTap: handleAnnotationTap
                                )
                            }
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
                //
                // It's a `simultaneousGesture`, not `.onTapGesture`: the latter
                // installs a tap that must wait for MapKit's double-tap-to-zoom
                // recognizer to fail before it fires, which is the ~0.3 s delay
                // before the card closes. Recognizing simultaneously drops that
                // require-to-fail dependency, so the tap registers immediately.
                .simultaneousGesture(
                    TapGesture().onEnded {
                        // Defer one runloop so any annotation tap from the same
                        // touch is processed first (it sets `annotationTapConsumed`
                        // and opens/swaps a card); then dismiss only if this tap
                        // landed on the empty map, not on an annotation.
                        //
                        // A boolean token, not a wall-clock comparison: the old
                        // heuristic ("dismiss unless an annotation tap landed in the
                        // last 0.1 s") misfired under main-thread load. Presenting a
                        // fresh card and decoding its thumbnails can push this
                        // deferred block well past 0.1 s after the annotation tap, so
                        // a legitimate cluster tap dismissed its own just-opened card
                        // — the "card appears then instantly disappears" bug, which
                        // cleared up after zooming in (fewer/cheaper annotations =
                        // less jank). Every map tap fires this gesture, so the flag an
                        // annotation tap sets is always consumed by the paired run
                        // here; an empty-map tap finds it clear and dismisses.
                        DispatchQueue.main.async {
                            if annotationTapConsumed {
                                annotationTapConsumed = false
                                return
                            }
                            guard mapCard != nil else { return }
                            mapCard = nil
                        }
                    }
                )
                // Record the camera cheaply every frame into the non-observable
                // `CameraTracker` (no re-render). Annotations are positioned by
                // MapKit from their coordinates, so they pan/zoom with the map
                // natively while we do no SwiftUI work mid-gesture.
                .onMapCameraChange(frequency: .continuous) { context in
                    cacheCamera(context)
                    // When "Update While Moving" is on, rebuild/cull live so
                    // thumbnails appear and disappear (fading, if enabled) during
                    // the pan/zoom rather than waiting for the touch to lift.
                    if settings.updateMapDuringGesture {
                        commitVisibleEntries()
                    }
                }
                // Commit the cull/rebuild the instant a pan/zoom touch lifts, so
                // thumbnails appear/disappear immediately rather than waiting for
                // the map's momentum to decay. `.onEnd` below is the backstop for
                // programmatic camera moves and the post-fling settle.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8).onEnded { _ in commitVisibleEntries() }
                )
                .simultaneousGesture(
                    MagnifyGesture().onEnded { _ in commitVisibleEntries() }
                )
                // Backstop: programmatic camera moves (recenter / focus) and the
                // final settle after a fling aren't a finger-up, so reconcile here
                // too. Idempotent with the gesture commits (threshold-guarded).
                .onMapCameraChange(frequency: .onEnd) { context in
                    cacheCamera(context)
                    commitVisibleEntries()
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
                GlassMapButton(
                    systemImage: centeredOnUser ? "location.fill" : "location",
                    accessibility: "Center on current location"
                ) {
                    Task {
                        guard let coord = await LocationCache.shared.current() else { return }
                        // Fill the icon on recenter; skip clearing it for the
                        // duration of the recenter animation (the grace window).
                        withAnimation(.easeInOut(duration: 0.2)) { centeredOnUser = true }
                        recenterGraceUntil = Date.now + 0.7
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
            MapCardSheet(
                card: mapCard,
                photo: $sheetPhoto,
                onPinpoint: { point in
                    // "Pinpoint on Map" from a bird inside a cluster card. Clear
                    // the photo explicitly: closing the card tears down the cover
                    // visually, but the item binding would otherwise stay set and
                    // re-present the photo the next time a card opens.
                    sheetPhoto = nil
                    mapCard = nil
                    navigator?.focus(latitude: point.latitude, longitude: point.longitude)
                },
                onLoneDismissed: {
                    // The lone-bird photo opened over the card was dismissed —
                    // put the card away instead of returning to it.
                    mapCard = nil
                }
            )
        }
        .fullScreenCover(item: $presentedSinglePoint) { point in
            // A lone pin — nothing to swipe to, no map button.
            SpeciesPhotoFullScreen(
                items: [SpeciesPhotoItem(
                    scientificName: point.scientificName,
                    placeName: point.location,
                    dateFound: point.date
                )]
            )
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

    /// Record the live camera every frame (continuous callback). Mutates only the
    /// non-observable `CameraTracker`, so it never re-renders the map mid-gesture;
    /// the actual cull/rebuild is deferred to `commitVisibleEntries` at touch-up.
    /// Handles a tap on a map annotation: opens a multi-bird card, swaps the photo
    /// inside an already-open card, or presents a lone bird full-screen from the
    /// root. Shared by both the snapping and fading annotation content views.
    private func handleAnnotationTap(_ tappedInfo: RepInfo) {
        // Mark this as an annotation tap so the map's simultaneous dismiss gesture
        // consumes it instead of dismissing the card.
        annotationTapConsumed = true
        // Multi-bird stacks open (or swap to) a card.
        if tappedInfo.count > 1 {
            mapCard = .cluster(BirdCluster(
                representative: tappedInfo.representative,
                coordinate: tappedInfo.coordinate,
                others: tappedInfo.others
            ))
        } else if mapCard != nil {
            // A card is already open. Present the photo from the *sheet's own*
            // context so it appears instantly — a root cover would have to wait for
            // the sheet to finish dismissing first. The card is closed when this
            // photo is dismissed (see MapCardSheet).
            sheetPhoto = .lone(tappedInfo.representative)
        } else {
            // No card open: present full-screen from the root (nothing to wait on).
            presentedSinglePoint = tappedInfo.representative
        }
    }

    private func cacheCamera(_ context: MapCameraUpdateContext) {
        camera.lastSpan = context.region.span
        camera.lastCenter = context.region.center
        // Quantize zoom into discrete steps so a continuous pinch doesn't trigger a
        // rebuild on every frame. The step boundary picks up legitimate zoom-level
        // transitions without flickering mid-pinch.
        camera.pendingZoomStep = Int((log2(max(context.camera.distance, 1)) * 4).rounded(.down))
        // Any user-driven camera move after the recenter grace window clears the
        // filled state; only a recenter tap fills it again.
        if centeredOnUser, Date.now > recenterGraceUntil {
            withAnimation(.easeInOut(duration: 0.2)) { centeredOnUser = false }
        }
    }

    /// Rebuild clusters + viewport-cull from the last cached camera, *instantly*.
    /// Run the moment a pan/zoom touch lifts (gesture `.onEnded`), and again on the
    /// camera's `.onEnd` as a backstop for programmatic moves (recenter / focus)
    /// and the post-fling settle — rather than only once the map fully stops.
    private func commitVisibleEntries() {
        // Rebuild clusters (which fills `visibleReps`, the annotation *content*)
        // before culling `visiblePoints` (which mounts the annotation *hosts*),
        // so each host is created with its content already present. If a host is
        // mounted while its rep info is still missing, it renders empty and
        // MapKit caches a zero-size hit area that it never re-measures — that's
        // the root cause of fresh stacks silently swallowing the first taps.
        if let step = camera.pendingZoomStep, step != camera.lastZoomStep {
            camera.lastZoomStep = step
            rebuildClusters(animated: false)
        }

        // Refresh the viewport-culled set whenever pan or zoom crosses a
        // meaningful threshold. Cheap relative to the cluster compute.
        updateVisibleEntries(force: false)
    }

    /// Update the cached `visiblePoints` set. When `force` is false,
    /// skip the work if the camera hasn't moved beyond ~30% of the
    /// current span (so a gentle pan doesn't churn ForEach diffs).
    private func updateVisibleEntries(force: Bool) {
        guard let span = camera.lastSpan else { return }

        if !force,
           let prevCenter = camera.lastFilterCenter,
           let prevSpan = camera.lastFilterSpan {
            let dLat = abs(camera.lastCenter.latitude - prevCenter.latitude)
            let dLon = abs(camera.lastCenter.longitude - prevCenter.longitude)
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
        let centerLat = camera.lastCenter.latitude
        let centerLon = camera.lastCenter.longitude
        let filtered = mapPoints.filter { point in
            abs(point.latitude - centerLat) <= latRange
                && abs(point.longitude - centerLon) <= lonRange
        }
        visiblePoints = filtered
        camera.lastFilterCenter = camera.lastCenter
        camera.lastFilterSpan = span
    }

    private func rebuildClusters(animated: Bool) {
        guard let span = camera.lastSpan, viewSize.width > 0, viewSize.height > 0 else {
            return
        }
        let computed = Self.computeClusters(
            points: mapPoints,
            span: span,
            centerLatitude: camera.lastCenter.latitude,
            viewSize: viewSize,
            footprint: Self.annotationFootprint,
            gutter: Self.clusterGutter
        )
        var next: [String: RepInfo] = [:]
        next.reserveCapacity(computed.count)
        for cluster in computed {
            next[cluster.representative.id] = RepInfo(
                // Count distinct species, matching the deduped card grid — so a
                // stack of repeat observations of one bird reads as "1" (and is
                // tapped straight through to its photo) rather than "N Birds".
                count: cluster.uniqueByMostRecent.count,
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
    /// that are still reps reappear solid (see `CulledAnnotationContent`), no
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

        // Deterministic order (date desc, then stable tiebreakers) so the
        // representative each stack folds onto — and therefore the stack's
        // identity — doesn't depend on the input array's incidental order.
        let sorted = points.sorted(by: BirdCluster.ordersBefore)

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

// MARK: - Per-annotation cull wrapper
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
// entry *is* a rep, the content renders; when it leaves the rep set the
// content is cleared. Show and hide are instant (no crossfade), in step
// with the touch-up cull, and the dead annotations have no footprint.
private struct CulledAnnotationContent: View {
    let point: MapPoint
    let info: MapView.RepInfo?
    let thumbSize: CGSize
    let onTap: (MapView.RepInfo) -> Void

    // Render directly off `info`: content is present exactly when this entry is a
    // current cluster rep and absent (zero-size, tap-transparent) otherwise. Show
    // and hide are instant, in step with the touch-up cull, so no lagged-mirror or
    // opacity state is needed.
    var body: some View {
        if let info {
            MapAnnotationContent(
                point: point,
                clusterCount: info.count,
                thumbSize: thumbSize
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onTap(info)
            }
        }
    }
}

// MARK: - Per-annotation fading wrapper
//
// The fading counterpart of `CulledAnnotationContent`, used when the "Fade
// Thumbnails" map setting is on. Same hit-testing contract — content is absent
// (zero-size, tap-transparent) when this entry isn't a current cluster rep — but
// the show/hide is animated via a local opacity state rather than instant. The
// `rendered` mirror keeps the content mounted through the fade-out so the tween
// is actually visible before the view collapses.
private struct FadingAnnotationContent: View {
    let point: MapPoint
    let info: MapView.RepInfo?
    let thumbSize: CGSize
    let onTap: (MapView.RepInfo) -> Void

    /// Mirror of `info` lagged behind by the fade-out animation. While the fade is
    /// running, `info` is already nil but `rendered` still holds the previous value
    /// so the content stays mounted long enough to be visible during the tween.
    /// Cleared in the animation's completion callback.
    @State private var rendered: MapView.RepInfo?
    @State private var opacity: Double = 0
    /// False until the first `info` resolution after this view mounts. Lets us
    /// distinguish a genuine first appearance (or a hit-test rehydration remount,
    /// which destroys + recreates this view) — which should settle to its final
    /// opacity instantly — from a later transition while mounted, which should
    /// animate. This keeps the post-pinch remount silent instead of flashing every
    /// thumbnail through a fresh fade-in.
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
        // First resolution after mount (incl. a rehydration remount): jump straight
        // to the final opacity with no animation, so re-creating an already-visible
        // annotation doesn't replay its fade-in.
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
            // Already visible: just refresh the count, no fade needed.
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

    /// One point per species — the most recent observation — newest first.
    /// With repeat observations enabled a cluster can hold several sightings of
    /// the same bird; the card shows a single, latest thumbnail for each instead
    /// of duplicates.
    ///
    /// The sort carries a stable tiebreaker (scientific name, then point id)
    /// after the date, so birds sharing an exact timestamp — several species
    /// logged in one checklist at the same location — always land in the same
    /// order. Without it, `Dictionary.values` is unordered and `sorted(by:)`
    /// isn't guaranteed stable on equal keys, so the card could shuffle its
    /// birds between recomputations (e.g. when opening the full-screen viewer).
    var uniqueByMostRecent: [MapPoint] {
        var latest: [String: MapPoint] = [:]
        for point in all {
            if let existing = latest[point.scientificName] {
                if Self.ordersBefore(point, existing) { latest[point.scientificName] = point }
            } else {
                latest[point.scientificName] = point
            }
        }
        return latest.values.sorted(by: Self.ordersBefore)
    }

    /// Deterministic "newest first" ordering with stable tiebreakers, so equal
    /// dates never reorder. Also used to pick the kept point per species above.
    static func ordersBefore(_ a: MapPoint, _ b: MapPoint) -> Bool {
        if a.date != b.date { return a.date > b.date }
        if a.scientificName != b.scientificName { return a.scientificName < b.scientificName }
        return a.id < b.id
    }

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
    /// Full-screen photo presented from *this sheet's* context (not the root) so
    /// it doesn't collide with the sheet's own presentation — that's what makes
    /// it open instantly over the card. `.pinpoint` carries the map button and
    /// returns to the card; `.lone` has no button and closes the card on exit.
    @Binding var photo: MapSheetPhoto?
    /// "Pinpoint on Map" for a bird tapped inside a cluster card.
    let onPinpoint: (MapPoint) -> Void
    /// The lone-bird photo (opened over a card) was dismissed.
    let onLoneDismissed: () -> Void

    /// Whether dismissing the current photo should also close the card. Tracked
    /// here because `onDismiss` can't read the (already-cleared) `photo` item.
    @State private var closeCardOnPhotoDismiss = false
    /// Current detent. A multi-bird cluster can be pulled up to `.large` to see
    /// every bird; the settings card is medium-only. Reset to `.medium` whenever
    /// the card swaps so settings never inherits a stranded `.large`.
    @State private var detent: PresentationDetent = .medium

    /// The detents allowed for the current card: clusters get medium + large,
    /// the settings card stays at medium (matching the import card).
    private var detents: Set<PresentationDetent> {
        switch card {
        case .cluster: return [.medium, .large]
        default:       return [.medium]
        }
    }

    /// Spacing between thumbnails, both between columns and rows.
    private static let gridSpacing: CGFloat = 12
    /// Target thumbnail width. The column count is chosen so each thumbnail is at
    /// least this wide; the flexible columns then divide the row evenly.
    private static let minThumbWidth: CGFloat = 104
    /// Equal inset of each thumbnail from the card's top and side edges (applied
    /// as `clusterGrid`'s padding). Equal on top and sides so the corner-radius
    /// math below yields *concentric* corners, not just matching ones.
    private static let thumbInset: CGFloat = 12

    /// Builds the grid's columns to fill `width` exactly, leaving no centered
    /// slack at the row's edges. An `.adaptive` grid with a `maximum` item width
    /// can't grow its columns past that cap, so on wider screens the leftover
    /// space is split and centered — which pushes the edge thumbnails inward past
    /// `thumbInset`, making the side gap larger than the top gap (it looked fine
    /// on a 16 Pro, where 3 columns happened to fill the row, but not on a 17 Pro
    /// Max). Flexible columns instead divide the full width evenly, so the edge
    /// thumbnails always sit flush at `thumbInset` — equal to the top inset — and
    /// the corners stay concentric on every iOS 26 phone. The count is the most
    /// columns that keep each thumbnail at least `minThumbWidth` wide.
    private static func columns(forWidth width: CGFloat) -> [GridItem] {
        guard width > 0 else {
            return [GridItem(.flexible(), spacing: gridSpacing)]
        }
        let count = max(1, Int((width + gridSpacing) / (minThumbWidth + gridSpacing)))
        return Array(
            repeating: GridItem(.flexible(), spacing: gridSpacing),
            count: count
        )
    }
    /// The presenting sheet's actual top corner radius, measured at runtime (see
    /// `SheetTopCornerRadiusReader`). iOS rounds a non-full sheet's top corners to
    /// a fixed, device-independent system value — its bottom corners are square
    /// and simply sit inside the phone's rounded display corner — but that value
    /// isn't public API, so we read it off the presentation layer. Seeded with a
    /// sane default until the probe resolves the real one.
    @State private var sheetTopCornerRadius: CGFloat = 34
    /// Points added to the strictly-concentric thumbnail radius. The concentric
    /// value (top radius − inset) reads a hair too tight, so nudge it up by this
    /// much. Tune to taste; 0 restores exact concentricity.
    private static let thumbCornerRadiusAdjust: CGFloat = 4
    /// Thumbnail corner radius, concentric with the card's top corners (the outer
    /// radius minus the equal inset between them) plus `thumbCornerRadiusAdjust`.
    /// Tracks the measured top radius, so it holds on every device.
    private var thumbCornerRadius: CGFloat {
        max(0, sheetTopCornerRadius - Self.thumbInset + Self.thumbCornerRadiusAdjust)
    }

    var body: some View {
        // A plain native sheet, matching the life-list import card: the system
        // draws the frosted surface and the corners (tight top, phone-concentric
        // bottom on iOS 26), so we no longer hand-roll the card shape. The body is
        // just the content, crossfading between cards on an in-place swap.
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
        // Read the real top corner radius off the live presentation so the
        // thumbnails can be made concentric with it on any device.
        .background(
            SheetTopCornerRadiusReader { radius in
                if abs(radius - sheetTopCornerRadius) > 0.5 {
                    sheetTopCornerRadius = radius
                }
            }
        )
        // Crossfade whenever the card identity changes (cluster→cluster,
        // cluster→settings, …). The sheet host is unaffected; only the contents
        // animate, so the swap reads as a smooth dissolve rather than a snap.
        .animation(.easeInOut(duration: 0.14), value: card?.id)
        // A cluster can expand to .large; settings stays medium. Snap back to
        // medium on a swap so the settings card never opens stranded at large.
        .onChange(of: card?.id) { _, _ in
            if case .settings = card { detent = .medium }
        }
        // Diagnostics for the present-time horizontal slide (see modifier).
        .logSheetPresentGeometry("MapCard")
        .presentationDetents(detents, selection: $detent)
        .presentationDragIndicator(.hidden)
        // Keep the map interactive (and undimmed) behind the card — this is what
        // lets you open other things from either card and tap the map to dismiss.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        // Remember (before the item clears) whether to close the card on exit.
        .onChange(of: photo) { _, newValue in
            switch newValue {
            case .lone:     closeCardOnPhotoDismiss = true
            case .pinpoint: closeCardOnPhotoDismiss = false
            case .none:     break   // keep the flag for onDismiss to read
            }
        }
        .fullScreenCover(
            item: $photo,
            onDismiss: {
                if closeCardOnPhotoDismiss {
                    closeCardOnPhotoDismiss = false
                    onLoneDismissed()
                }
            }
        ) { photo in
            switch photo {
            case .pinpoint(let points, let startIndex):
                // Swipe between the birds in this card; the place-name tap
                // pinpoints whichever bird is showing.
                SpeciesPhotoFullScreen(
                    items: points.map {
                        SpeciesPhotoItem(
                            scientificName: $0.scientificName,
                            placeName: $0.location,
                            dateFound: $0.date
                        )
                    },
                    initialIndex: startIndex,
                    mapButtonTitle: "Pinpoint on Map",
                    onShowOnMap: { item in
                        if let point = points.first(where: {
                            $0.scientificName == item.scientificName
                        }) {
                            onPinpoint(point)
                        }
                    }
                )
            case .lone(let point):
                // A lone pin tapped while a card was open — nothing to swipe to.
                SpeciesPhotoFullScreen(
                    items: [SpeciesPhotoItem(
                        scientificName: point.scientificName,
                        placeName: point.location,
                        dateFound: point.date
                    )]
                )
            }
        }
    }

    private func clusterGrid(_ cluster: BirdCluster) -> some View {
        // Read the card's width so the grid can size its columns to fill the row
        // exactly (no centered slack), keeping the edge thumbnails flush at
        // `thumbInset`. The available content width is the card width minus the
        // equal horizontal inset on each side.
        GeometryReader { geo in
            let available = geo.size.width - 2 * Self.thumbInset
            ScrollView {
                LazyVGrid(
                    columns: Self.columns(forWidth: available),
                    alignment: .center,
                    spacing: Self.gridSpacing
                ) {
                    ForEach(cluster.uniqueByMostRecent) { point in
                        ClusterGridItem(
                            point: point,
                            cornerRadius: thumbCornerRadius
                        )
                        .onTapGesture {
                            // Open the viewer over every bird in the card so the
                            // photo can be swiped between them, starting here.
                            let points = cluster.uniqueByMostRecent
                            let idx = points.firstIndex(of: point) ?? 0
                            photo = .pinpoint(points: points, index: idx)
                        }
                    }
                }
                // Symmetric inset (shared with the thumbnail concentricity math);
                // a bit more at the bottom so the last row clears the home
                // indicator at the large detent.
                .padding(.horizontal, Self.thumbInset)
                .padding(.top, Self.thumbInset)
                .padding(.bottom, 24)
            }
        }
    }
}

/// Reports the presenting sheet's actual top corner radius back to SwiftUI.
///
/// iOS rounds a non-full sheet's *top* corners to a fixed, device-independent
/// system value (the bottom corners are left square, sitting inside the phone's
/// rounded display corner) and doesn't expose that value as API. We read it off
/// the live presentation by walking up from this probe to the nearest ancestor
/// layer that rounds its top corners — that's the sheet's container — and
/// reporting its `cornerRadius`. The card uses it to size thumbnails concentric
/// with the top corners on every device, rather than guessing a constant.
private struct SheetTopCornerRadiusReader: UIViewRepresentable {
    let onResolve: (CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView { ProbeView(onResolve: onResolve) }
    func updateUIView(_ uiView: ProbeView, context: Context) { uiView.onResolve = onResolve }

    final class ProbeView: UIView {
        var onResolve: (CGFloat) -> Void

        init(onResolve: @escaping (CGFloat) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Defer so the presentation container is fully attached and laid out
            // (its corner radius is set during the present transition).
            DispatchQueue.main.async { [weak self] in self?.resolve() }
        }

        private func resolve() {
            var view: UIView? = superview
            while let current = view {
                let corners = current.layer.maskedCorners
                let roundsTop = corners.contains(.layerMinXMinYCorner)
                    || corners.contains(.layerMaxXMinYCorner)
                if current.layer.cornerRadius > 1, roundsTop {
                    onResolve(current.layer.cornerRadius)
                    return
                }
                view = current.superview
            }
        }
    }
}

/// A full-screen photo presented from within an open map card's sheet.
private enum MapSheetPhoto: Identifiable, Equatable {
    /// Birds in a cluster grid — opens the viewer over all of them (swipeable),
    /// starting on `index`. Shows "Pinpoint on Map"; keeps the card.
    case pinpoint(points: [MapPoint], index: Int)
    /// A lone pin tapped on the map while a card was open — no button; closes
    /// the card when dismissed.
    case lone(MapPoint)

    var id: String {
        switch self {
        case .pinpoint(let points, _):
            return "pinpoint-" + (points.first?.id ?? "") + "-\(points.count)"
        case .lone(let p):
            return "lone-" + p.id
        }
    }
}

/// Top-aligned cell so a 2-line caption doesn't shove its neighbor's
/// image down a row.
private struct ClusterGridItem: View {
    let point: MapPoint
    let cornerRadius: CGFloat

    /// The thumbnail's width:height ratio (was a fixed 116×87). The image now
    /// *fills* the grid cell's full width rather than sitting at a fixed width;
    /// a fixed-width thumbnail centered inside a wider flexible cell is what left
    /// the edge thumbnails floating with extra side gap on larger screens (e.g.
    /// 17 Pro Max), breaking the equal top/side inset the concentric corners need.
    /// Filling the cell makes the edge thumbnails flush at the grid's inset.
    private static let aspectRatio: CGFloat = 116.0 / 87.0

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            // Aspect-ratio box that fills the cell width; the photo scales to fill
            // it and is clipped to the concentric corner radius.
            Color.clear
                .aspectRatio(Self.aspectRatio, contentMode: .fit)
                .overlay {
                    SpeciesPhoto(
                        scientificName: point.scientificName,
                        showsCredit: false,
                        tappable: false,
                        usesThumbnail: true
                    ) {
                        Color.gray
                            .overlay {
                                Image(systemName: "bird")
                                    .foregroundStyle(.white)
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
        SpeciesPhoto(scientificName: scientificName, showsCredit: false, tappable: false, usesThumbnail: true) {
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
/// Plain (non-`@Observable`) holder for the map's per-frame camera bookkeeping.
/// Stored as a single `@State` reference on `MapView`; mutating its properties
/// does not invalidate the view, so the `.continuous` camera callback can record
/// the latest values every frame without re-rendering the map. See the field's
/// doc comment on `MapView` for why this matters (pan-lag fix).
private final class CameraTracker {
    var lastSpan: MKCoordinateSpan?
    var lastCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    var lastZoomStep: Int?
    /// Zoom step recorded by the continuous camera callback, applied (compared
    /// against `lastZoomStep`) only when the cull/rebuild is committed at touch-up.
    var pendingZoomStep: Int?
    var lastFilterCenter: CLLocationCoordinate2D?
    var lastFilterSpan: MKCoordinateSpan?
}

private struct GlassMapButton: View {
    let systemImage: String
    let accessibility: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
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
        // Scrollable so the full set of options is reachable even at the medium
        // detent on smaller screens.
        ScrollView {
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
                    "Show Repeat Observations",
                    isOn: $settings.showRepeatObservationsOnMap
                )
                .font(.body.weight(.semibold))
                Text("Show every recorded observation of a species on the map, rather than only the earliest.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Update While Moving",
                    isOn: $settings.updateMapDuringGesture
                )
                .font(.body.weight(.semibold))
                Text("Refresh the bird thumbnails continuously while panning and zooming, rather than only when you lift your fingers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Fade Thumbnails",
                    isOn: $settings.fadeMapThumbnails
                )
                .font(.body.weight(.semibold))
                Text("Fade bird thumbnails in and out as they appear and disappear, rather than snapping them instantly.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Force Offline Species List",
                    isOn: $settings.forceOfflineSpeciesList
                )
                .font(.body.weight(.semibold))
                Text("Debug: identify using the bundled offline species list instead of the live model, logging how long each lookup takes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.bottom, 24)
        }
    }
}

#Preview {
    MapView()
        .environment(LifeListStore())
}
