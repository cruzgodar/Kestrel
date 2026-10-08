import CoreLocation
import SwiftUI

/// What the Targets tab is showing: every bird the geo model expects at one
/// place this week, ranked from most to least likely, and what that place is
/// called.
///
/// **Ranking.** The geo model (`SpeciesRangeFilter`) scores every catalog
/// species with an occurrence likelihood for a place and week — the same
/// numbers the recording filter thresholds into a yes/no list. Here they are
/// kept and sorted on, so the commonest birds come first and the rarities
/// last. The bundled offline grid only knows yes/no, so when the live model
/// can't run the list falls back to alphabetical.
///
/// **Which place.** The current location by default, or a spot picked on the
/// map, which persists across launches until Current Location is chosen
/// again.
@Observable
final class TargetsModel {
    /// One species expected at the place.
    struct AreaSpecies: Hashable, Sendable {
        let scientificName: String
        let commonName: String
    }

    enum Status {
        case loading
        case ready
        /// Following the current location, and there is no location to follow.
        case noLocation
    }

    /// The place picked on the map, or `nil` while following the current
    /// location.
    private(set) var chosenCoordinate: CLLocationCoordinate2D?
    var usesCurrentLocation: Bool { chosenCoordinate == nil }

    /// The town the list describes, once the reverse lookup lands. `nil` while
    /// it's in flight, and for good when it fails (offline).
    private(set) var placeName: String?
    /// Ranked most likely first. `nil` until the first list lands.
    private(set) var species: [AreaSpecies]?
    private(set) var status: Status = .loading

    /// Where and for which week `species` was worked out, so a refresh that
    /// finds neither has moved can leave the list alone.
    private var loaded: (coordinate: CLLocationCoordinate2D, week: Int)?
    /// Bumped by every refresh, so a slow one finishing after a newer one has
    /// started can't publish over it.
    private var generation = 0

    /// How far the current location has to move before the list is worked out
    /// again. The geo model's resolution is far coarser than this, so anything
    /// closer is the same list.
    private static let sameAreaRadius: CLLocationDistance = 2_000

    private static let latitudeKey = "Targets.chosenLatitude"
    private static let longitudeKey = "Targets.chosenLongitude"

    init() {
        let defaults = UserDefaults.standard
        if let latitude = defaults.object(forKey: Self.latitudeKey) as? Double,
           let longitude = defaults.object(forKey: Self.longitudeKey) as? Double {
            chosenCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// Follows the current location from now on.
    func useCurrentLocation(manager: RecordingManager) async {
        // Leaving a picked place: the fix can take seconds, and the old list
        // shouldn't stand under the solid arrow while it does.
        if chosenCoordinate != nil { clear() }
        chosenCoordinate = nil
        UserDefaults.standard.removeObject(forKey: Self.latitudeKey)
        UserDefaults.standard.removeObject(forKey: Self.longitudeKey)
        await refresh(manager: manager)
    }

    /// Shows a place picked on the map, until Current Location is chosen again.
    func choose(_ coordinate: CLLocationCoordinate2D, manager: RecordingManager) async {
        clear()
        chosenCoordinate = coordinate
        UserDefaults.standard.set(coordinate.latitude, forKey: Self.latitudeKey)
        UserDefaults.standard.set(coordinate.longitude, forKey: Self.longitudeKey)
        await refresh(manager: manager)
    }

    /// Works the list out again if the place or the week has changed since it
    /// last was. Cheap to call on every appearance.
    func refresh(manager: RecordingManager) async {
        generation += 1
        let run = generation

        let target: CLLocationCoordinate2D
        if let chosenCoordinate {
            target = chosenCoordinate
        } else if let here = await Self.currentCoordinate() {
            target = here
        } else {
            guard run == generation else { return }
            clear()
            status = .noLocation
            return
        }
        guard run == generation else { return }

        let week = SpeciesRangeFilter.birdnetWeek()
        if let loaded, species != nil, loaded.week == week,
           Self.distance(loaded.coordinate, target) < Self.sameAreaRadius {
            // Same list. A name that failed to look up last time (offline) is
            // worth another try, though.
            if placeName == nil { await lookUpPlaceName(at: loaded.coordinate, run: run) }
            return
        }

        // A different place: clear the old list rather than leave it standing
        // under a subtitle that no longer describes it.
        clear()
        let ranked = await Self.rankedSpecies(at: target, week: week, manager: manager)
        guard run == generation else { return }
        species = ranked
        loaded = (target, week)
        status = .ready
        await lookUpPlaceName(at: target, run: run)
    }

    /// Drops the list on a deliberate change of place, so the spinner shows
    /// until the new one lands.
    private func clear() {
        loaded = nil
        species = nil
        placeName = nil
        status = .loading
    }

    private func lookUpPlaceName(at coordinate: CLLocationCoordinate2D, run: Int) async {
        let name = await ObservationNameSheet.townName(at: coordinate)
        guard run == generation else { return }
        placeName = name
    }

    /// Where the user is, without ever prompting for access. A fresh fix when
    /// one can be had; failing that the last place this process knew of, then
    /// the last place the range filter was worked out for.
    private static func currentCoordinate() async -> CLLocationCoordinate2D? {
        let status = CLLocationManager().authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways,
           let fix = await LocationCache.shared.current() {
            return CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
        }
        if let last = LocationCache.shared.lastCoordinate ?? SpeciesRangeFilter.cachedCoordinate() {
            return CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
        }
        return nil
    }

    private static func rankedSpecies(
        at coordinate: CLLocationCoordinate2D,
        week: Int,
        manager: RecordingManager
    ) async -> [AreaSpecies] {
        if let likelihoods = await manager.areaLikelihoods(
            latitude: coordinate.latitude, longitude: coordinate.longitude
        ) {
            return await Task.detached(priority: .userInitiated) {
                rank(likelihoods: likelihoods)
            }.value
        }
        // No live model: the offline grid's yes/no list, which has nothing to
        // rank on.
        let allowed = OfflineSpeciesFilter.shared.allowedIndices(
            lat: coordinate.latitude, lon: coordinate.longitude, week: week
        ) ?? []
        return await Task.detached(priority: .userInitiated) {
            alphabetical(allowed)
        }.value
    }

    /// The species the geo model puts at or above the range filter's own
    /// threshold, most likely first. Ties go alphabetically by common name so
    /// two runs over the same numbers always give the same order.
    nonisolated static func rank(
        likelihoods: [Float],
        threshold: Float = SpeciesRangeFilter.threshold
    ) -> [AreaSpecies] {
        let catalog = SpeciesCatalog.shared.all
        var scored: [(likelihood: Float, species: SpeciesCatalog.Species)] = []
        for (index, likelihood) in likelihoods.enumerated()
        where likelihood >= threshold && catalog.indices.contains(index) {
            let species = catalog[index]
            guard isBird(species) else { continue }
            scored.append((likelihood, species))
        }
        return scored
            .sorted { a, b in
                if a.likelihood != b.likelihood { return a.likelihood > b.likelihood }
                return a.species.commonName < b.species.commonName
            }
            .map { AreaSpecies(scientificName: $0.species.scientificName, commonName: $0.species.commonName) }
    }

    nonisolated static func alphabetical(_ indices: Set<Int>) -> [AreaSpecies] {
        let catalog = SpeciesCatalog.shared.all
        return indices
            .filter { catalog.indices.contains($0) && isBird(catalog[$0]) }
            .map { catalog[$0] }
            .sorted { $0.commonName < $1.commonName }
            .map { AreaSpecies(scientificName: $0.scientificName, commonName: $0.commonName) }
    }

    /// The labels file's noise and human classes are not targets.
    private nonisolated static func isBird(_ species: SpeciesCatalog.Species) -> Bool {
        !BirdNETClassifier.nonBirdLabels.contains(species.scientificName)
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

/// The Targets tab: the Life List's own screen, run over the birds expected at
/// one place (see `LifeListView`'s `targets`), plus the button that picks the
/// place.
struct TargetsView: View {
    @Environment(RecordingManager.self) private var manager
    @Environment(LifeListStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var model = TargetsModel()
    @State private var showPicker = false

    var body: some View {
        LifeListView(targets: model)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await model.useCurrentLocation(manager: manager) }
                        } label: {
                            Label("Current Location", systemImage: "location")
                        }
                        Button {
                            showPicker = true
                        } label: {
                            Label("Choose Location", systemImage: "map")
                        }
                    } label: {
                        // Solid while following the current location, hollow
                        // while showing a place picked on the map.
                        Label(
                            "Location",
                            systemImage: model.usesCurrentLocation ? "location.fill" : "location"
                        )
                        .contentTransition(.symbolEffect(.replace))
                    }
                }
                // The same trailing inset the Life List's buttons carry.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            // Every appearance, and every return to the foreground: the user
            // may have walked somewhere new, or the week may have turned over.
            // Both are no-ops when nothing has changed.
            .task { await model.refresh(manager: manager) }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await model.refresh(manager: manager) }
            }
            .fullScreenCover(isPresented: $showPicker) {
                MapView(picker: MapView.LocationPicker(
                    // A place already picked opens with its pin down; otherwise
                    // the pin starts on the current location, as in the add flow.
                    initialCoordinate: model.chosenCoordinate,
                    onBack: { showPicker = false },
                    onConfirm: { coordinate in
                        showPicker = false
                        guard let coordinate else { return }
                        Task { await model.choose(coordinate, manager: manager) }
                    },
                    confirmTitle: "Show Targets",
                    backAccessibilityLabel: "Back to Targets"
                ))
                // `@Observable` environment objects don't cross a cover.
                .environment(store)
            }
    }
}
