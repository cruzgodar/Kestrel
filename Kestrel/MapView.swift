import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// A single plotted point on the map. An entry contributes one point per
/// stored observation — its earliest plus every repeat that carries
/// coordinates — so the same species can appear at several locations. `id` is
/// unique per point; `scientificName` stays the species key used for photo
/// lookups.
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

    /// The recorded sighting this point plots. A map point carries a date, a
    /// place, and coordinates — exactly what identifies an observation — so the
    /// menus and the full-screen viewer can act on it directly.
    var observation: LifeListEntry.Observation {
        LifeListEntry.Observation(
            date: date,
            location: location,
            latitude: latitude,
            longitude: longitude
        )
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
    /// Non-nil when the map is running as the life-list add flow's location
    /// picker rather than as the Map tab. The map itself is identical (same
    /// species thumbnails, same clustering); the picker adds a long-press to
    /// drop a pin, a back button and a Save Observation button, and makes the
    /// existing annotations display-only — a thumbnail's own coordinate is
    /// whatever cluster it happens to represent at the current zoom, which is
    /// far too coarse to stand in for "where I saw this bird."
    let picker: LocationPicker?

    /// Callbacks the location-picker mode reports through. `onConfirm` fires
    /// when Save Observation is tapped, carrying whatever location is pinned —
    /// the current location the picker opens on, or wherever the user
    /// long-pressed instead.
    struct LocationPicker {
        /// Where the picker opens with its pin already dropped, and the camera
        /// already there. Non-nil when the flow is editing a sighting, so the
        /// map opens on the place it was recorded rather than on wherever the
        /// user happens to be standing now. `nil` falls back to the current
        /// location — see `seedPickerPin`.
        var initialCoordinate: CLLocationCoordinate2D? = nil
        let onBack: () -> Void
        let onConfirm: (CLLocationCoordinate2D) -> Void
    }

    /// Spelled out because the view's other stored properties are private, which
    /// makes the synthesized memberwise initializer private too — and so
    /// invisible to the add flow that presents the picker.
    init(picker: LocationPicker? = nil) {
        self.picker = picker
    }

    @Environment(LifeListStore.self) private var store
    @Environment(MapNavigator.self) private var navigator: MapNavigator?

    /// The pins the picker currently has on the map. Normally one — the chosen
    /// location — but a fresh long press while a pin is already down appends the
    /// new one and leaves the old in place for the length of a crossfade, so the
    /// pin dissolves from the old spot to the new instead of sliding across the
    /// map. `dropPin` schedules the stale entries' removal.
    @State private var pickedPins: [PickedPin] = []
    /// Set when the picker's default pin could not be taken from a location
    /// fix, so the next camera settle supplies it instead — see `seedPickerPin`.
    @State private var pickerWantsCameraSeed = false
    /// Live touch point, recorded by a zero-distance drag that runs alongside
    /// the map's own gestures. `LongPressGesture` reports no location of its
    /// own, so this is what the long press converts into a coordinate.
    @State private var touchPoint: CGPoint = .zero

    /// One dropped pin. Identity is per-drop rather than per-coordinate so a
    /// re-pick mounts a *new* annotation (which fades in) alongside the old one
    /// (which fades out) rather than moving the existing annotation's host.
    private struct PickedPin: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
    }

    /// The coordinate Save Observation would commit — the newest pin, if any.
    private var pickedCoordinate: CLLocationCoordinate2D? {
        pickedPins.last?.coordinate
    }

    /// What Save Observation commits. Normally the dropped pin; the camera's
    /// own center covers the sliver of time before the default pin is seeded
    /// (see `seedPickerPin`), so the always-visible button is never a dead tap
    /// once the map has drawn a frame. `lastSpan` is the "camera has reported
    /// at least once" flag — without it `lastCenter` is still its (0, 0)
    /// placeholder.
    private var committableCoordinate: CLLocationCoordinate2D? {
        if let pickedCoordinate { return pickedCoordinate }
        guard camera.lastSpan != nil else { return nil }
        return camera.lastCenter
    }

    /// How long the pin takes to dissolve from its old spot to the new one.
    private static let pinCrossfade: Double = 0.22

    /// Drops the picker's default pin — the current location — so the flow
    /// always opens with a location already chosen and Save Observation always
    /// means something. Run once from the view's `.task`.
    ///
    /// When there is no fix to be had (access never granted, or the request
    /// times out) the camera's own center stands in: whatever the map settled
    /// on is the best "here" available. That center may not exist yet — the
    /// `.task` runs before the map has reported a camera — so this hands the
    /// job to `seedPickerPinFromCamera`, which the next camera settle calls.
    private func seedPickerPin() async {
        guard picker != nil, pickedPins.isEmpty else { return }
        let status = CLLocationManager().authorizationStatus
        let authorized = status == .authorizedWhenInUse || status == .authorizedAlways
        // Never prompts: `current()` only resolves a fix, and only when access
        // has already been granted elsewhere (the first Start Recording).
        let fix = authorized ? await LocationCache.shared.current() : nil
        // The await can take seconds to time out, and a long press in the
        // meantime is the user's own choice of location — never overwrite it.
        guard picker != nil, pickedPins.isEmpty else { return }
        guard let fix else {
            // No fix. Fall back to the camera, either the one it has already
            // settled on or the next one it reports.
            pickerWantsCameraSeed = true
            seedPickerPinFromCamera(camera.lastSpan == nil ? nil : camera.lastCenter)
            return
        }
        dropPin(at: CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude))
    }

    /// Drops the pin an *edit* opens with. Split out of `seedPickerPin` and run
    /// before it, because it needs no location fix and so must not sit behind
    /// one: the warm-up `seedPickerPin` waits on can take seconds to give up,
    /// and the pin for a place we already know belongs on screen immediately.
    ///
    /// The camera move goes through the same held-and-re-asserted focus request
    /// the Map tab uses, because it faces the same race: the map is still
    /// resolving its initial `.userLocation` position, and the fix that lands a
    /// moment later would otherwise throw the camera back onto the user.
    private func seedPickerPinFromEdit() {
        guard let initial = picker?.initialCoordinate, pickedPins.isEmpty else { return }
        dropPin(at: initial)
        let focus = MapFocus(
            latitude: initial.latitude,
            longitude: initial.longitude,
            token: UUID()
        )
        focusRequest = focus
        focusDeadline = Date.now + Self.focusReassertWindow
        moveCamera(to: focus, animated: false)
    }

    /// The camera-center half of `seedPickerPin`, called on every camera settle.
    /// Does nothing until the location fix has been given up on, and nothing
    /// once any pin is down.
    private func seedPickerPinFromCamera(_ center: CLLocationCoordinate2D?) {
        guard picker != nil, pickerWantsCameraSeed, pickedPins.isEmpty, let center else { return }
        pickerWantsCameraSeed = false
        dropPin(at: center)
    }

    /// Records a long-pressed location. A pin already on the map isn't moved —
    /// the new one is added on top and the old is left to fade out under it, then
    /// dropped once the crossfade has played.
    private func dropPin(at coordinate: CLLocationCoordinate2D) {
        let pin = PickedPin(coordinate: coordinate)
        pickedPins.append(pin)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pinCrossfade + 0.05) {
            // Everything *before* this pin, so a third press mid-fade doesn't
            // take the pin that superseded this one with it.
            guard let idx = pickedPins.firstIndex(where: { $0.id == pin.id }), idx > 0 else {
                return
            }
            pickedPins.removeSubrange(0..<idx)
        }
    }

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
    /// A focus request that hasn't visibly landed yet, held so it can be
    /// re-asserted rather than applied once and forgotten.
    ///
    /// This is what fixes "Show on Map opens the Map tab but leaves the camera
    /// where I am." The first time the tab is opened after a launch, the map is
    /// built with `position == .userLocation(fallback: .automatic)` and is still
    /// resolving that when our `onAppear` write lands — the map is mid-layout
    /// (zero-sized inside its `GeometryReader`) and MapKit is in follow mode, so
    /// the first location fix arrives *after* the write and throws the camera
    /// back onto the user. Every subsequent open finds the camera already
    /// settled, which is why the bug only shows up once per launch. Holding the
    /// request and re-asserting it on each camera settle makes the outcome
    /// independent of who moved the camera last.
    @State private var focusRequest: MapFocus?
    /// When to stop re-asserting `focusRequest`. Kept short: long enough for the
    /// initial location fix (the thing that overrides us) to land, short enough
    /// that a pan of the user's own is never yanked back.
    @State private var focusDeadline: Date = .distantPast
    /// How long a focus request keeps re-asserting itself.
    private static let focusReassertWindow: TimeInterval = 2
    /// How close the camera center must land to count as "arrived", in degrees
    /// — a tenth of the focus span, so an equivalent camera counts even when
    /// MapKit rounds the region it actually applied.
    private static let focusArrivalTolerance: Double = 0.002
    /// The span a focus request zooms to.
    private static let focusSpan = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
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
    /// Accumulates the annotation ids that need a hit-test remount across a
    /// continuous pinch (each zoom-step rebuild adds the reps that just gained
    /// content). Drained by the debounced rehydration so only the hosts that
    /// actually changed are remounted — the stable ones stay mounted and don't
    /// flicker.
    @State private var pendingRehydrateIDs: Set<String> = []
    /// Buffer expressed in spans — render entries within 1.5× the visible
    /// region in each direction. Big enough that gentle panning never
    /// touches the ForEach set; small enough that we're not mounting the
    /// whole life list.
    private static let visibleBufferFactor: Double = 1.5

    /// Currently-visible cluster reps, keyed by the representative point's
    /// `MapPoint.id` (a species can hold several). Every plotted observation
    /// gets its own persistent Annotation; this dict says which of those should be
    /// opaque (and tappable) right now. State-driven opacity changes
    /// animate cleanly inside MapKit's hosted SwiftUI view, even though
    /// insert/remove transitions do not — that's the workaround for the
    /// "annotations never fade" problem.
    @State private var visibleReps: [String: RepInfo] = [:]

    /// The bottom card currently presented — a multi-bird cluster. Bound through
    /// one `.sheet(isPresented:)` so that switching from one cluster to another
    /// swaps the sheet's content live, rather than dismissing the old card and
    /// waiting for it to close before presenting the new one. The native sheet is what keeps
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
    /// Add / edit / delete started from a pinned thumbnail's haptic-touch menu.
    /// Presented from its own layer in the ZStack rather than from the map
    /// itself, which already presents the bottom card — one view can only host
    /// one sheet.
    @State private var actions = ObservationActions()

    /// The bottom card the map can show — a multi-bird cluster. Routed through a
    /// single sheet (see `mapCard`) so re-targeting it never tears the sheet down.
    enum MapCard: Identifiable {
        case cluster(BirdCluster)

        var id: String {
            switch self {
            case .cluster(let cluster): return "cluster-" + cluster.id
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

    /// Height of a pinned thumbnail on the map. The total annotation occupies
    /// more space than the thumbnail — see `Self.annotationFootprint`.
    private static let thumbHeight: CGFloat = 72
    /// Pinned thumbnail dimensions on the map, at a 13:10 box (map pins run
    /// slightly narrower than the 4:3 row thumbnails).
    private static var thumbSize: CGSize {
        CGSize(width: (thumbHeight * 13 / 10).rounded(), height: thumbHeight)
    }
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

    /// All map points to plot: every recorded sighting that carries coordinates.
    /// That's each species' earliest one (its displayed `first*` fields) plus a
    /// point for each stored repeat, so a bird seen in five places pins all five.
    private var mapPoints: [MapPoint] {
        var points: [MapPoint] = []
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
                // `MapReader` is what turns the long press's touch point into a
                // coordinate in picker mode. It's unconditional so the map's view
                // identity doesn't depend on the mode.
                MapReader { mapProxy in
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
                            // Fades in/out as it enters and leaves the visible
                            // cluster set, and collapses to zero size when not a
                            // current cluster rep so dead annotations never eat taps.
                            FadingAnnotationContent(
                                point: point,
                                info: visibleReps[point.id],
                                thumbSize: Self.thumbSize,
                                onTap: handleAnnotationTap,
                                // Display-only in picker mode, menu included.
                                menuEnabled: picker == nil,
                                menu: annotationMenu
                            )
                        }
                        .annotationTitles(.hidden)
                    }
                    // Usually one pin; briefly two while a re-pick crossfades.
                    // `anchor: .bottom` puts the pin's needle tip on the
                    // coordinate rather than centering the whole glyph on it.
                    ForEach(pickedPins) { pin in
                        Annotation("Chosen location", coordinate: pin.coordinate, anchor: .bottom) {
                            PickedLocationMarker(
                                isCurrent: pin.id == pickedPins.last?.id,
                                fadeDuration: Self.pinCrossfade
                            )
                        }
                        .annotationTitles(.hidden)
                    }
                }
                // Picker mode only: record the live touch point, then convert it
                // when the press passes the long-press threshold. Two *simultaneous*
                // gestures rather than a `.sequenced` pair — the map's own pan/zoom
                // recognizers keep working alongside them, and a zero-distance drag
                // reports its location on touch-down (a `LongPressGesture` reports
                // none at all, and a sequenced drag only reports on lift).
                // `LongPressGesture`'s default 10pt slop means a pan cancels it, so
                // dragging the map never drops a pin.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { touchPoint = $0.location },
                    isEnabled: picker != nil
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.4)
                        .onEnded { _ in
                            guard picker != nil,
                                  let coord = mapProxy.convert(touchPoint, from: .local)
                            else { return }
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            dropPin(at: coord)
                        },
                    isEnabled: picker != nil
                )
                .mapControls {
                    // The recenter control is provided as a custom glass button
                    // (see the top-trailing overlay) so it matches the picker's
                    // back button; only the compass stays a map control.
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
                // natively while we do no SwiftUI work mid-gesture; the cull/rebuild
                // is deferred entirely to the complete-stop callback below.
                .onMapCameraChange(frequency: .continuous) { context in
                    cacheCamera(context)
                }
                // Rebuild/cull the thumbnails ONLY when the map comes to a complete
                // stop — `.onEnd` fires once the camera stops changing (after any
                // fling has fully decelerated), not at finger-up. Driving the update
                // solely from here means a pure pinch-to-zoom (which doesn't emit a
                // SwiftUI drag/magnify end) still updates on its settle, and a pan's
                // momentum plays out before the thumbnails change. Programmatic moves
                // (recenter / focus) land here too.
                .onMapCameraChange(frequency: .onEnd) { context in
                    cacheCamera(context)
                    commitVisibleEntries()
                    // Last resort for the picker's default pin: with no location
                    // fix available, wherever the camera settled is the best
                    // "here" we have. A no-op once a pin is down.
                    seedPickerPinFromCamera(context.region.center)
                    // Whatever just moved the camera — us, a fling, or MapKit
                    // resolving its initial user-location follow — check that an
                    // outstanding focus request actually arrived, and re-assert it
                    // if it didn't.
                    reassertFocusIfNeeded(center: context.region.center)
                }
                .onAppear { viewSize = geo.size }
                // Clusters before culling in every path (see handleCameraChange)
                // so annotation hosts always mount with their content present.
                .onChange(of: geo.size) { _, new in
                    viewSize = new
                    rebuildClusters(animated: false, rehydrate: false)
                    updateVisibleEntries(force: true)
                }
                .onChange(of: store.entries) { _, _ in
                    rebuildClusters(animated: true, rehydrate: false)
                    updateVisibleEntries(force: true)
                }
                }
            }
            .ignoresSafeArea(edges: .bottom)

            // Liquid-glass recenter control pinned to the top-right, replacing
            // the stock MapUserLocationButton.
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
            .padding(.top, 8)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // Zero-size host for the presentations a thumbnail's menu raises.
            // They can't hang off the map itself, which already presents the
            // bottom card.
            Color.clear
                .frame(width: 0, height: 0)
                .observationActions(actions, store: store)

            if let picker {
                // Back to the date step.
                GlassMapButton(
                    systemImage: "chevron.left",
                    accessibility: "Back to the observation date"
                ) {
                    picker.onBack()
                }
                .padding(.top, 8)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Standing instruction across the top, in the row the back and
                // recenter buttons occupy: same 8pt top inset and the same 44pt
                // height as a `GlassMapButton`, so the three read as one row of
                // controls. Inset past both buttons' widths (12pt margin + 44pt
                // button) so a long line can never run under them.
                Text("Long press to choose a location")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 18)
                    .frame(height: GlassMapButton.diameter)
                    .glassEffect(.regular, in: .capsule)
                    .allowsHitTesting(false)
                    .padding(.top, 8)
                    .padding(.horizontal, 68)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // The commit button stands the whole time the picker is up —
                // there is no "nothing chosen yet" state to wait out, since the
                // picker opens with the current location already pinned (see
                // `seedPickerPin`) and a long press only moves that pin.
                //
                // The Identify tab's record-button treatment (same style, same
                // metrics, no icon) so the primary action of a screen reads the
                // same everywhere in the app.
                Button {
                    guard let coordinate = committableCoordinate else { return }
                    // No haptic here — the map is the middle step of the add
                    // flow, and the confirmation pulse belongs on the step
                    // that actually writes the observation (the naming
                    // sheet), not on one that just moves the flow along.
                    picker.onConfirm(coordinate)
                } label: {
                    Text("Save Observation")
                        .font(.title3.weight(.semibold))
                        .frame(height: 58)
                        .padding(.horizontal, 28)
                }
                .buttonStyle(RecordButtonStyle(tint: .kestrelPurple))
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .task {
            // An edit already knows where its pin goes, so it is dropped before
            // the location warm-up below rather than behind it.
            seedPickerPinFromEdit()
            // Never prompt for location here — permission is only ever requested
            // at the first Start Recording. If access is already granted, warm a
            // fix so the recenter button and user dot work immediately; otherwise
            // do nothing and leave the camera on its automatic fallback.
            let status = CLLocationManager().authorizationStatus
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                _ = await LocationCache.shared.current()
            }
            // Picker mode opens with the current location already chosen — the
            // same warmed fix, so this costs nothing extra.
            await seedPickerPin()
        }
        // Focus requests can arrive while the Map tab is already on screen
        // (pinpoint from a cluster card) or just before it appears (Show on Map
        // from another tab) — handle both.
        .onChange(of: navigator?.pendingFocus) { _, _ in applyPendingFocus(animated: true) }
        .onAppear { applyPendingFocus(animated: false) }
        // Second line of defense behind `reassertFocusIfNeeded`, which needs a
        // camera-settle callback to fire before it can notice the camera went
        // somewhere else. If the initial write is swallowed outright — the map
        // still mid-mount, so nothing moves and nothing settles — no callback
        // arrives at all, and the request would sit there unnoticed. Re-asserting
        // once shortly after covers that; it's a no-op when the camera is already
        // where it was asked to be.
        .task(id: focusRequest?.token) {
            guard focusRequest != nil else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, focusRequest != nil else { return }
            reassertFocusIfNeeded(center: camera.lastCenter)
        }
        // One sheet for both cards. Bound to `isPresented` (not `item`) so
        // re-pointing `mapCard` swaps the content live; `MapCardSheet` crossfades
        // between cards, keeps the map interactive behind it, and never dims it.
        .sheet(isPresented: Binding(
            get: { mapCard != nil },
            set: { if !$0 { mapCard = nil } }
        )) {
            MapCardSheet(
                card: mapCard,
                store: store,
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
                    dateFound: point.date,
                    // A pin *is* one sighting, so the viewer's menu can edit or
                    // delete it without asking which.
                    observation: point.observation
                )]
            )
            // Re-inject the store so the viewer's star toggle resolves it — see the
            // note at the presenter cover in KestrelApp.
            .environment(store)
        }
    }

    /// Consumes a pending focus request from `MapNavigator` and moves the camera
    /// to a tight region around the coordinate. The request is held in
    /// `focusRequest` until the camera is actually there — see that property for
    /// why applying it once isn't enough.
    ///
    /// `animated` is false when the request arrives with the tab (the tab switch
    /// is the transition; sliding the camera underneath it just wastes the move)
    /// and true when it arrives while the map is already on screen.
    private func applyPendingFocus(animated: Bool) {
        guard let focus = navigator?.pendingFocus else { return }
        navigator?.pendingFocus = nil
        focusRequest = focus
        focusDeadline = Date.now + Self.focusReassertWindow
        moveCamera(to: focus, animated: animated)
    }

    /// Points the camera at a focus request's coordinate.
    private func moveCamera(to focus: MapFocus, animated: Bool) {
        let region = MKCoordinateRegion(center: focus.coordinate, span: Self.focusSpan)
        if animated {
            withAnimation(.easeInOut(duration: 0.45)) { position = .region(region) }
        } else {
            position = .region(region)
        }
    }

    /// Called on every camera settle. Puts the camera back where it was asked to
    /// be if something else moved it, and drops the request once the window has
    /// passed.
    ///
    /// Deliberately *not* cleared the moment the camera arrives. On a cold open
    /// of the Map tab the camera reaches the requested coordinate and is then
    /// thrown to the user's own location a few frames later, when the location
    /// fix that the map's initial `.userLocation` position was waiting on finally
    /// lands. Treating that first arrival as success is exactly what let the
    /// override stand — so the request outlives it and only expires on the clock.
    private func reassertFocusIfNeeded(center: CLLocationCoordinate2D) {
        guard let focus = focusRequest else { return }
        guard Date.now <= focusDeadline else {
            focusRequest = nil
            return
        }
        let arrived = abs(center.latitude - focus.latitude) < Self.focusArrivalTolerance
            && abs(center.longitude - focus.longitude) < Self.focusArrivalTolerance
        guard !arrived else { return }
        moveCamera(to: focus, animated: true)
    }

    // MARK: - Camera + clustering

    /// Record the live camera every frame (continuous callback). Mutates only the
    /// non-observable `CameraTracker`, so it never re-renders the map mid-gesture;
    /// the actual cull/rebuild is deferred to `commitVisibleEntries` at touch-up.
    /// Handles a tap on a map annotation: opens a multi-bird card, swaps the photo
    /// inside an already-open card, or presents a lone bird full-screen from the
    /// root. Shared by both the snapping and fading annotation content views.
    private func handleAnnotationTap(_ tappedInfo: RepInfo, fromTap: Bool = true) {
        // Display-only in picker mode: the thumbnails are there for orientation,
        // and opening a card or a photo over the picker would be a dead end.
        guard picker == nil else { return }
        // Mark this as an annotation tap so the map's simultaneous dismiss gesture
        // consumes it instead of dismissing the card. Only for a real tap: a long
        // press fires no tap gesture, so a flag set here would sit there and
        // swallow the user's *next* tap on the empty map.
        if fromTap { annotationTapConsumed = true }
        // Multi-bird stacks open (or swap to) a card.
        if tappedInfo.count > 1 {
            mapCard = .cluster(BirdCluster(
                representative: tappedInfo.representative,
                coordinate: tappedInfo.coordinate,
                others: tappedInfo.others
            ))
        } else {
            // A stack of repeat observations of one bird counts as a single
            // species and opens straight to its photo. It still holds every
            // repeat, so pick the earliest sighting the same way the card grid
            // does — the representative is the *newest* point of the stack.
            let point = BirdCluster(
                representative: tappedInfo.representative,
                coordinate: tappedInfo.coordinate,
                others: tappedInfo.others
            ).uniqueByEarliest.first ?? tappedInfo.representative
            if mapCard != nil {
                // A card is already open. Present the photo from the *sheet's own*
                // context so it appears instantly — a root cover would have to wait for
                // the sheet to finish dismissing first. The card is closed when this
                // photo is dismissed (see MapCardSheet).
                sheetPhoto = .lone(point)
            } else {
                // No card open: present full-screen from the root (nothing to wait on).
                presentedSinglePoint = point
            }
        }
    }

    /// The haptic-touch menu a *lone* thumbnail raises — the same actions a
    /// species row offers anywhere else in the app. Multi-*bird* stacks don't
    /// get one: the menu would have no single bird to act on, and their tap
    /// already opens a card where each bird has its own.
    @ViewBuilder
    private func annotationMenu(for info: RepInfo) -> some View {
        // The same sighting a tap would open — for a stack of repeat
        // observations of one bird, its earliest.
        let cluster = BirdCluster(
            representative: info.representative,
            coordinate: info.coordinate,
            others: info.others
        )
        let point = cluster.uniqueByEarliest.first ?? info.representative
        MapPointMenu(
            point: point,
            store: store,
            sightings: cluster.sightings(of: point.scientificName),
            actions: actions,
            onViewImage: {
                if mapCard != nil {
                    sheetPhoto = .lone(point)
                } else {
                    presentedSinglePoint = point
                }
            }
        )
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

    /// Rebuild clusters + viewport-cull from the last cached camera. Run once the
    /// map has come to a complete stop (the camera's `.onEnd`), which also covers
    /// programmatic moves (recenter / focus) and the post-fling settle.
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

    /// `rehydrate` controls whether a cluster-set change triggers the post-change
    /// annotation remount (`scheduleHitTestRehydration`). That remount briefly
    /// clears every annotation and restores it, which reads as all the groups
    /// flickering off and back on. It's only actually needed for the pinch-zoom
    /// path, where a host stays mounted (same id) but its content's footprint
    /// changes and MapKit keeps the stale hit area. The life-list / view-size
    /// paths instead force a fresh `updateVisibleEntries`, which mounts any changed
    /// host with its content already present (correct hit area) — so they pass
    /// `rehydrate: false` and don't flicker.
    private func rebuildClusters(animated: Bool, rehydrate: Bool = true) {
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
        let oldReps = visibleReps
        var next: [String: RepInfo] = [:]
        next.reserveCapacity(computed.count)
        for cluster in computed {
            next[cluster.representative.id] = RepInfo(
                // Count distinct species, matching the deduped card grid — so a
                // stack of repeat observations of one bird reads as "1" (and is
                // tapped straight through to its photo) rather than "N Birds".
                count: cluster.uniqueByEarliest.count,
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
        // Both the warm-up and the rehydration exist purely to repair MapKit's
        // cached annotation *hit areas*, and both work by unmounting the
        // annotations and putting them straight back — which reads as every
        // thumbnail fading out and in. The picker's annotations are display-only
        // (see `handleAnnotationTap`), so there's no hit area worth repairing and
        // the flicker is pure cost. The Map tab keeps both, where it only pays
        // the warm-up once per launch; the picker mounts a fresh `MapView` every
        // time it opens, so it would pay it on every open.
        if picker != nil {
            // Nothing more to do: the cluster set is already committed above.
        } else if !next.isEmpty, !didWarmUpAnnotations, !warmUpScheduled {
            warmUpScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                warmUpAnnotations()
            }
        } else if didWarmUpAnnotations, rehydrate {
            // After the initial load, every *subsequent* cluster change (most
            // commonly a pinch that merges/splits stacks) re-mounts the *hosts that
            // gained content* once the camera settles, so MapKit re-measures them.
            // Without this, a freshly-formed stack renders but keeps the stale
            // (often zero-size) hit area MapKit cached for the host's previous
            // *empty* content — taps fall straight through to the map until the
            // next interaction.
            //
            // Only the reps that went empty → content need it (the stale-zero-size
            // case). Remounting *all* annotations — the previous approach — made
            // every visible thumbnail re-fade on each pinch step (the flicker), even
            // though only a couple of stacks actually changed. So we remount just
            // those, leaving the stable hosts untouched.
            //
            // Skipped (`rehydrate == false`) for non-zoom rebuilds (life-list,
            // view size): those are paired with a forced `updateVisibleEntries`
            // that already mounts changed hosts with content present.
            let changedIDs = Set(next.keys).subtracting(oldReps.keys)
            if !changedIDs.isEmpty {
                scheduleHitTestRehydration(changedIDs: changedIDs)
            }
        }
    }

    /// Debounced remount of *only the changed* annotation hosts to refresh
    /// MapKit's cached hit areas after a cluster change. `changedIDs` accumulate
    /// across a continuous pinch and are coalesced into a single remount fired
    /// ~0.25 s after the last change, so it doesn't churn mid-gesture. Only the
    /// changed hosts are dropped + restored (so MapKit recreates them with content
    /// present); every other host stays mounted, so the stable annotations don't
    /// flicker — the became-content hosts were fading in anyway, so their remount
    /// is masked.
    private func scheduleHitTestRehydration(changedIDs: Set<String>) {
        pendingRehydrateIDs.formUnion(changedIDs)
        rehydrateToken &+= 1
        let token = rehydrateToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard token == rehydrateToken else { return }
            let ids = pendingRehydrateIDs
            pendingRehydrateIDs = []
            let saved = visiblePoints
            let remaining = saved.filter { !ids.contains($0.id) }
            // Nothing to remount (the changed hosts aren't currently visible) — or
            // they're the whole set, in which case there's nothing to keep mounted.
            guard remaining.count != saved.count else { return }
            visiblePoints = remaining
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

/// The haptic-touch menu behind a single bird on the map — a pinned thumbnail
/// or one cell of a cluster card. Wraps `SpeciesRowMenu` so the map can't drift
/// from the lists' wording, symbols, or order.
///
/// A map thumbnail usually *is* one sighting, in which case Edit and Delete act
/// on it outright — no "which one did you mean?" for a pin that can only mean
/// one thing. But repeat sightings of one bird at one spot collapse into a
/// single thumbnail (see `BirdCluster.uniqueByEarliest`), and there the pin
/// stands for several: acting on the representative alone would silently touch
/// only the earliest and leave the thumbnail sitting there looking untouched.
/// Those ask — over a list holding just the sightings pinned *here*, since a
/// sighting from the other side of the country is not something this pin could
/// have meant. Delete is always one sighting either way; the species leaves the
/// life list only when it was the last on record.
private struct MapPointMenu: View {
    let point: MapPoint
    let store: LifeListStore
    /// Every sighting the thumbnail this menu belongs to stands for — one for a
    /// lone pin, several for a stack of repeat visits to the same spot.
    let sightings: [LifeListEntry.Observation]
    /// Where Edit, Add, and Delete are routed — the host attaches the matching
    /// `observationActions` so the flow, the chooser, and the delete
    /// confirmation all present from the right place.
    let actions: ObservationActions
    let onViewImage: () -> Void

    var body: some View {
        let starred = store.starredNames.contains(point.scientificName)
        SpeciesRowMenu(
            // `among:` handles both shapes: a lone sighting is acted on
            // directly, and a stack raises the chooser over exactly these.
            onEdit: {
                actions.edit(
                    scientificName: point.scientificName,
                    commonName: point.commonName,
                    among: sightings
                )
            },
            onAddObservation: {
                actions.add(
                    scientificName: point.scientificName,
                    commonName: point.commonName
                )
            },
            star: (starred, {
                // The same single short tap every other star in the app gives.
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.setStarred(scientificName: point.scientificName, isStarred: !starred)
            }),
            onViewImage: onViewImage,
            onDelete: {
                actions.delete(
                    scientificName: point.scientificName,
                    commonName: point.commonName,
                    among: sightings
                )
            }
        )
    }
}

// MARK: - Per-annotation fading wrapper
//
// MapKit's annotation host (a UIKit `MKAnnotationView` wrapping a
// `UIHostingController`) does *not* honor SwiftUI's `.allowsHitTesting` on its
// inner content. Any rendered subview — even one with opacity 0 — still absorbs
// taps at the UIKit hit-test layer. So when an entry isn't a current cluster rep
// we render *no* content (an empty `if let`), collapsing MapKit's hosting view to
// zero size so dead annotations can't eat taps. When the entry *is* a rep the
// content renders, fading in/out via a local opacity state. The `rendered` mirror
// keeps the content mounted through the fade-out so the tween is actually visible
// before the view collapses.
/// Duration of the thumbnail fade-in / fade-out. Change this one value to make
/// the fade faster or slower. Kept brisk so thumbnails appear/disappear snappily
/// rather than lingering. A file-level constant rather than a static on
/// `FadingAnnotationContent`, which is generic over its menu content and so can't
/// carry stored statics.
private enum AnnotationFade {
    static let duration: Double = 0.12
}

private struct FadingAnnotationContent<Menu: View>: View {
    let point: MapPoint
    let info: MapView.RepInfo?
    let thumbSize: CGSize
    /// Opens the annotation. The flag says whether the interaction was a tap —
    /// false for the long press, which the map's tap-to-dismiss never sees.
    let onTap: (MapView.RepInfo, Bool) -> Void
    /// False in picker mode, where the thumbnails are there for orientation
    /// only and every action on the menu would be a dead end.
    let menuEnabled: Bool
    /// The haptic-touch menu, built only for a thumbnail standing for one bird.
    @ViewBuilder let menu: (MapView.RepInfo) -> Menu

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
                let content = MapAnnotationContent(
                    point: point,
                    clusterCount: rendered.count,
                    thumbSize: thumbSize
                )
                .contentShape(Rectangle())
                .opacity(opacity)
                // Only a lone bird gets a menu — see `MapView.annotationMenu`.
                if menuEnabled && rendered.count == 1 {
                    content
                        .onTapGesture { onTap(rendered, true) }
                        .contextMenu { menu(rendered) }
                } else {
                    // A stack of several has no single bird a menu could act on,
                    // so a press there does what a tap does and opens the card
                    // rather than reading as a dead gesture. Both gestures are
                    // recognized in UIKit: SwiftUI's own `LongPressGesture`
                    // never fires inside a MapKit annotation (MapKit's
                    // recognizers win the press outright), which is also why the
                    // lone thumbnail's menu has to be a `.contextMenu`.
                    content.overlay {
                        AnnotationPressCatcher(
                            onTap: { onTap(rendered, true) },
                            // Not a tap, so the map's own tap-to-dismiss gesture
                            // has nothing to consume — see `handleAnnotationTap`.
                            onPress: { onTap(rendered, false) }
                        )
                    }
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
                withAnimation(.easeInOut(duration: AnnotationFade.duration)) {
                    opacity = 1
                }
            }
            // Already visible: just refresh the count, no fade needed.
        } else if rendered != nil {
            withAnimation(.easeInOut(duration: AnnotationFade.duration)) {
                opacity = 0
            } completion: {
                rendered = nil
            }
        }
    }
}

/// Transparent hit-testing layer that reports a tap and a long press through
/// UIKit recognizers of its own. Used by multi-bird annotations, where a SwiftUI
/// `LongPressGesture` never fires — see the call site.
private struct AnnotationPressCatcher: UIViewRepresentable {
    let onTap: () -> Void
    let onPress: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addGestureRecognizer(
            UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        )
        let press = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.pressed(_:))
        )
        press.minimumPressDuration = 0.4
        // MapKit's own recognizers are watching the same touch; let ours run
        // alongside them rather than being arbitrated away.
        press.delegate = context.coordinator
        press.cancelsTouchesInView = false
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onPress = onPress
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, onPress: onPress) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: () -> Void
        var onPress: () -> Void

        init(onTap: @escaping () -> Void, onPress: @escaping () -> Void) {
            self.onTap = onTap
            self.onPress = onPress
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc func tapped() {
            onTap()
        }

        @objc func pressed(_ gesture: UILongPressGestureRecognizer) {
            // `.began` — the press has passed its threshold and the finger is
            // still down, which is when a context menu would have appeared.
            guard gesture.state == .began else { return }
            // The same pulse the system plays when a context menu opens, so the
            // press feels acknowledged rather than silently different.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onPress()
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

    /// One point per species — the *earliest* observation — newest first.
    /// With repeat observations enabled a cluster can hold several sightings of
    /// the same bird; the card shows a single thumbnail for each instead of
    /// duplicates, carrying the date and place of the first time that bird was
    /// seen here rather than the latest, to match how the rest of the app treats
    /// a species' first sighting as the one worth showing.
    ///
    /// The sort carries a stable tiebreaker (scientific name, then point id)
    /// after the date, so birds sharing an exact timestamp — several species
    /// logged in one checklist at the same location — always land in the same
    /// order. Without it, `Dictionary.values` is unordered and `sorted(by:)`
    /// isn't guaranteed stable on equal keys, so the card could shuffle its
    /// birds between recomputations (e.g. when opening the full-screen viewer).
    var uniqueByEarliest: [MapPoint] {
        var earliest: [String: MapPoint] = [:]
        for point in all {
            guard let existing = earliest[point.scientificName] else {
                earliest[point.scientificName] = point
                continue
            }
            // Ties go to the lower id, which is the life-list entry's own first
            // sighting (`scientificName`) rather than one of its repeats
            // (`scientificName#i`) — so an exact timestamp match keeps the
            // canonical point.
            if point.date < existing.date
                || (point.date == existing.date && point.id < existing.id) {
                earliest[point.scientificName] = point
            }
        }
        return earliest.values.sorted(by: Self.ordersBefore)
    }

    /// Every sighting of `scientificName` pinned in this cluster — i.e. all the
    /// ones the single thumbnail `uniqueByEarliest` produces for that species
    /// actually stands for. More than one means the thumbnail is a stack, and
    /// acting on its representative alone would quietly touch only the earliest
    /// of them; this is the list its menu asks over instead (see
    /// `MapPointMenu`).
    func sightings(of scientificName: String) -> [LifeListEntry.Observation] {
        all.lazy.filter { $0.scientificName == scientificName }.map(\.observation)
    }

    /// Deterministic "newest first" ordering with stable tiebreakers, so equal
    /// dates never reorder. Also used to pick the kept point per species above.
    nonisolated static func ordersBefore(_ a: MapPoint, _ b: MapPoint) -> Bool {
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

/// Hosts the map's bottom card inside one native sheet. The sheet itself stays
/// mounted while `card` changes, so the body just crossfades between clusters
/// (keyed by `card.id`) instead of tearing the sheet down and re-presenting it —
/// that's the in-place swap the user sees when tapping a second cluster while a
/// card is already open.
///
/// Presentation modifiers are applied here, once, so the card is frosted,
/// non-dimming and background-interactive: the map stays live behind it, you can
/// tap another bird to swap, and a tap on the empty map dismisses (handled by
/// the map's own tap gesture in `MapView`).
private struct MapCardSheet: View {
    let card: MapView.MapCard?
    /// Passed explicitly (not read from the environment) so it can be re-injected
    /// into the photo cover below — Observation `.environment` objects don't
    /// reliably cross a presentation boundary, and the viewer's star toggle needs it.
    let store: LifeListStore
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
    /// Add / edit / delete started from a grid cell's haptic-touch menu. Hosted
    /// here rather than on the map so its presentations layer over the card
    /// instead of making it leave first.
    @State private var actions = ObservationActions()
    /// Current detent. A multi-bird cluster can be pulled up to `.large` to see
    /// every bird.
    @State private var detent: PresentationDetent = .medium

    /// The detents allowed for the current card: clusters get medium + large;
    /// no card (nil) falls back to medium.
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
        // Crossfade whenever the card identity changes (cluster→cluster). The
        // sheet host is unaffected; only the contents
        // animate, so the swap reads as a smooth dissolve rather than a snap.
        .animation(.easeInOut(duration: 0.14), value: card?.id)
        // Layered over the card rather than replacing it, the same way the
        // full-screen photo is.
        .observationActions(actions, store: store)
        .presentationDetents(detents, selection: $detent)
        .presentationDragIndicator(.hidden)
        // Keep the map interactive (and undimmed) behind the card — this is what
        // lets you open other things from the card and tap the map to dismiss.
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
                            dateFound: $0.date,
                            observation: $0.observation
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
                // Re-inject the store so the viewer's star toggle resolves it.
                .environment(store)
            case .lone(let point):
                // A lone pin tapped while a card was open — nothing to swipe to.
                SpeciesPhotoFullScreen(
                    items: [SpeciesPhotoItem(
                        scientificName: point.scientificName,
                        placeName: point.location,
                        dateFound: point.date,
                        observation: point.observation
                    )]
                )
                .environment(store)
            }
        }
    }

    /// Opens the full-screen viewer over every bird in the card so the photo can
    /// be swiped between them, starting on `point`.
    private func openPhoto(for point: MapPoint, in cluster: BirdCluster) {
        let points = cluster.uniqueByEarliest
        let idx = points.firstIndex(of: point) ?? 0
        photo = .pinpoint(points: points, index: idx)
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
                    ForEach(cluster.uniqueByEarliest) { point in
                        ClusterGridItem(
                            point: point,
                            cornerRadius: thumbCornerRadius
                        )
                        .onTapGesture {
                            openPhoto(for: point, in: cluster)
                        }
                        // The same actions a pinned thumbnail offers.
                        .contextMenu {
                            MapPointMenu(
                                point: point,
                                store: store,
                                sightings: cluster.sightings(of: point.scientificName),
                                actions: actions,
                                onViewImage: { openPhoto(for: point, in: cluster) }
                            )
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
        // No drop shadow: a shadow forces an offscreen render pass for every pin on
        // every frame MapKit re-composites them during a pan/zoom, which was a major
        // contributor to the panning stutter. The white hairline border alone keeps
        // the thumbnail legible against the map without the per-frame offscreen cost.
        .contentShape(Rectangle())
    }
}

/// Material Symbols' `add_location`, transcribed from its 24×24 path: a map-pin
/// balloon with a plus in the head. SF Symbols has no equivalent (there's no
/// `mappin.badge.plus`), so it's drawn directly.
///
/// The two halves are separate `part`s rather than one even-odd path, so the plus
/// can be painted a solid color instead of being a hole — over a map, a knocked-out
/// plus takes on whatever happens to be underneath it and stops reading as part of
/// the pin.
///
/// The path is authored in Material's 24×24 box but drawn to the *glyph's* tight
/// bounds — x 5…19, y 2…22 — so the shape fills whatever frame it's given with
/// no dead margin, and the balloon's tip lands exactly on the frame's bottom
/// edge (which is what lets the annotation anchor it `.bottom`). Both parts share
/// that mapping, so stacking them lines them up.
struct AddLocationShape: Shape {
    enum Part {
        /// The pin outline: circular head tapering to a point.
        case balloon
        /// The plus inside the head.
        case plus
    }

    var part: Part = .balloon

    /// Width ÷ height of the tight glyph bounds. Callers size by height and take
    /// the width from this so the pin never stretches.
    static let aspectRatio: CGFloat = 14.0 / 20.0

    /// Bounds of the glyph inside the 24×24 authoring box.
    private static let originX: CGFloat = 5
    private static let originY: CGFloat = 2
    private static let glyphWidth: CGFloat = 14
    private static let glyphHeight: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        var path = Path()

        switch part {
        case .balloon:
            // `M12 2C8.14 2 5 5.14 5 9c0 5.25 7 13 7 13s7-7.75 7-13
            // c0-3.86-3.14-7-7-7z`
            path.move(to: CGPoint(x: 12, y: 2))
            path.addCurve(
                to: CGPoint(x: 5, y: 9),
                control1: CGPoint(x: 8.14, y: 2),
                control2: CGPoint(x: 5, y: 5.14)
            )
            path.addCurve(
                to: CGPoint(x: 12, y: 22),
                control1: CGPoint(x: 5, y: 14.25),
                control2: CGPoint(x: 12, y: 22)
            )
            path.addCurve(
                to: CGPoint(x: 19, y: 9),
                control1: CGPoint(x: 12, y: 22),
                control2: CGPoint(x: 19, y: 14.25)
            )
            path.addCurve(
                to: CGPoint(x: 12, y: 2),
                control1: CGPoint(x: 19, y: 5.14),
                control2: CGPoint(x: 15.86, y: 2)
            )
            path.closeSubpath()

        case .plus:
            // `m4 8h-3v3h-2v-3H8V8h3V5h2v3h3v2z`
            path.addLines([
                CGPoint(x: 16, y: 10), CGPoint(x: 13, y: 10), CGPoint(x: 13, y: 13),
                CGPoint(x: 11, y: 13), CGPoint(x: 11, y: 10), CGPoint(x: 8, y: 10),
                CGPoint(x: 8, y: 8), CGPoint(x: 11, y: 8), CGPoint(x: 11, y: 5),
                CGPoint(x: 13, y: 5), CGPoint(x: 13, y: 8), CGPoint(x: 16, y: 8),
            ])
            path.closeSubpath()
        }

        let transform = CGAffineTransform(
            translationX: -Self.originX, y: -Self.originY
        )
        .concatenating(CGAffineTransform(
            scaleX: rect.width / Self.glyphWidth,
            y: rect.height / Self.glyphHeight
        ))
        .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return path.applying(transform)
    }
}

/// The pin dropped by a long press in the map's location-picker mode: the
/// `add_location` glyph in solid purple, its tip sitting on the chosen
/// coordinate (the annotation anchors it `.bottom`).
///
/// It owns its own fade because MapKit doesn't run SwiftUI insert/remove
/// transitions on annotations (the same reason `FadingAnnotationContent` exists).
/// A re-pick mounts a second marker at the new coordinate while this one is told
/// it's no longer current, so the two crossfade in place instead of one pin
/// sliding across the map.
private struct PickedLocationMarker: View {
    let isCurrent: Bool
    let fadeDuration: Double

    @State private var opacity: Double = 0

    /// Height of the pin on the map. Width follows from the glyph's aspect.
    private static let height: CGFloat = 36

    var body: some View {
        ZStack {
            AddLocationShape(part: .balloon).fill(Color.kestrelPurple)
            AddLocationShape(part: .plus).fill(.white)
        }
            .frame(
                width: Self.height * AddLocationShape.aspectRatio,
                height: Self.height
            )
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            // MapKit measures the hosting view once from the content's intrinsic
            // size; without this the glyph can be clipped (see MapAnnotationContent).
            .fixedSize()
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: fadeDuration)) {
                    opacity = isCurrent ? 1 : 0
                }
            }
            .onChange(of: isCurrent) { _, current in
                withAnimation(.easeInOut(duration: fadeDuration)) {
                    opacity = current ? 1 : 0
                }
            }
    }
}

// MARK: - Top-right glass controls

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

/// A circular liquid-glass map control, matching the search field's glass
/// buttons. Used for the recenter button and the picker's back button.
private struct GlassMapButton: View {
    let systemImage: String
    let accessibility: String
    let action: () -> Void

    private static let glyphBox: CGFloat = 22
    private static let glyphInset: CGFloat = 11
    /// Outer size of the glass circle. Public to the file so the picker's
    /// instruction capsule can match the buttons it shares the top row with.
    static let diameter: CGFloat = glyphBox + glyphInset * 2

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.glyphBox, height: Self.glyphBox)
                .padding(Self.glyphInset)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(NoDimButtonStyle())
        .accessibilityLabel(accessibility)
    }
}

#Preview {
    MapView()
        .environment(LifeListStore())
}
