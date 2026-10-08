import CoreLocation
import SwiftUI

/// What the Targets tab is showing: every bird the geo model expects at one
/// place in one month, ranked from most to least likely, and what that place
/// is called.
///
/// **Ranking.** The geo model (`SpeciesRangeFilter`) scores every catalog
/// species with an occurrence likelihood for a place and BirdNET week — the
/// same numbers the recording filter thresholds into a yes/no list. A month
/// is the four BirdNET weeks inside it (see `weeks(in:)`): a bird is a target
/// if it clears the threshold in any of them, and is ranked by its average
/// over all four, so a bird around all month outranks one passing through for
/// a week. The order runs commonest first or rarest first — see `Sort`. The
/// bundled offline grid only knows yes/no, so when the live model can't run,
/// rarity order falls back to alphabetical.
///
/// **Which place and month.** The current location and month by default, or a
/// spot picked on the map (one where the user is goes back to following them)
/// and a month picked from the calendar menu — which
/// also offers Any Month, the whole year at once. Neither is saved: every
/// launch starts back on here and now, with only the birds not yet found —
/// Include Life List Species isn't saved either.
@Observable
final class TargetsModel {
    /// One species expected at the place.
    struct AreaSpecies: Hashable, Sendable {
        let scientificName: String
        let commonName: String
    }

    /// How the list is ordered. Picked from the sort menu, which offers the
    /// two `Kind`s and flips the direction of whichever is already chosen.
    enum Sort: String {
        case mostCommonFirst, rarestFirst, aToZ, zToA

        enum Kind: CaseIterable, Identifiable {
            case rarity, alphabetical

            var id: Self { self }

            var title: String {
                switch self {
                case .rarity: "Rarity"
                case .alphabetical: "Alphabetical"
                }
            }

            /// The direction a kind starts in when it is picked.
            var defaultSort: Sort {
                switch self {
                case .rarity: .mostCommonFirst
                case .alphabetical: .aToZ
                }
            }
        }

        var kind: Kind {
            switch self {
            case .mostCommonFirst, .rarestFirst: .rarity
            case .aToZ, .zToA: .alphabetical
            }
        }

        /// The direction, shown under the checked kind in the menu.
        var subtitle: String {
            switch self {
            case .mostCommonFirst: "Most Common First"
            case .rarestFirst: "Rarest First"
            case .aToZ: "A–Z"
            case .zToA: "Z–A"
            }
        }

        var reversed: Sort {
            switch self {
            case .mostCommonFirst: .rarestFirst
            case .rarestFirst: .mostCommonFirst
            case .aToZ: .zToA
            case .zToA: .aToZ
            }
        }
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

    // The list on screen, and what it describes. A change of place or month
    // leaves all of these standing until the new list is ready, then replaces
    // them together — so the screen never blanks while it works, and the
    // heading never names a place or month the birds under it aren't for.

    /// Ranked most likely first. `nil` until the first list lands.
    private(set) var species: [AreaSpecies]?
    /// The town the list describes. `nil` when the lookup failed (offline).
    private(set) var placeName: String?
    /// The month the list is for; `nil` for Any Month. Can trail `month`,
    /// which changes the moment one is picked.
    private(set) var listMonth: Int?
    /// Whether the list is for wherever the user is, rather than a place
    /// picked on the map.
    private(set) var listFollowsUser = true
    /// Bumped each time a new list replaces the one on screen.
    private(set) var listRevision = 0

    private(set) var sort: Sort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey) }
    }

    /// `species` in the order the sort menu asks for.
    var sortedSpecies: [AreaSpecies]? {
        guard let species else { return nil }
        switch sort {
        case .mostCommonFirst: return species
        case .rarestFirst: return species.reversed()
        case .aToZ: return species.sorted { $0.commonName < $1.commonName }
        case .zToA: return species.sorted { $0.commonName > $1.commonName }
        }
    }

    /// A sort menu pick: the kind already chosen flips direction, and a new
    /// one starts in its default direction — the Music app's sort menu.
    func select(_ kind: Sort.Kind) {
        sort = sort.kind == kind ? sort.reversed : kind.defaultSort
    }
    private(set) var status: Status = .loading

    /// Whether the birds already on the life list are shown too, among the
    /// rest in the sort's order. Off at every launch.
    var includesLifeList = false

    /// The month the list is for, 1–12, or `nil` for any time of year. The
    /// current month until one is picked.
    private(set) var month: Int? = Calendar.current.component(.month, from: Date())

    /// `listMonth`'s name, in the user's language; `nil` for Any Month.
    var listMonthName: String? { listMonth.map(Self.monthName) }

    static func monthName(_ month: Int) -> String {
        Calendar.current.standaloneMonthSymbols[month - 1]
    }

    /// Shows another month's birds, or (`nil`) the whole year's.
    func setMonth(_ month: Int?, manager: RecordingManager) async {
        guard month != self.month else { return }
        // The same place as the list on screen: a month change shouldn't wait
        // seconds on a fresh location fix to land back where it already was.
        let place = loaded?.coordinate
        self.month = month
        await refresh(manager: manager, at: place)
    }

    /// The BirdNET weeks a month spans. BirdNET splits every month into four
    /// "weeks" (see `SpeciesRangeFilter.birdnetWeek`), so these are exactly
    /// the weeks that overlap it. Any Month is all 48.
    nonisolated static func weeks(in month: Int?) -> ClosedRange<Int> {
        guard let month else { return 1...48 }
        return ((month - 1) * 4 + 1)...(month * 4)
    }

    /// Where and for which month `species` was worked out, so a refresh that
    /// finds neither has moved can leave the list alone.
    private var loaded: (coordinate: CLLocationCoordinate2D, month: Int?)?
    /// Bumped by every refresh, so a slow one finishing after a newer one has
    /// started can't publish over it.
    private var generation = 0

    /// How far the current location has to move before the list is worked out
    /// again. The geo model's resolution is far coarser than this, so anything
    /// closer is the same list.
    private static let sameAreaRadius: CLLocationDistance = 2_000

    private static let sortKey = "Targets.sort"

    init() {
        sort = UserDefaults.standard.string(forKey: Self.sortKey)
            .flatMap(Sort.init(rawValue:)) ?? .mostCommonFirst
    }

    /// Follows the current location from now on.
    private func useCurrentLocation(manager: RecordingManager) async {
        chosenCoordinate = nil
        await refresh(manager: manager)
    }

    /// Shows a place picked on the map — or, for a spot where the user is,
    /// goes back to following them. The picker is the only way to choose, so
    /// this is how "here" is chosen again: the picker opens on the current
    /// location, or recenters on it, and confirming that follows it.
    func choose(_ coordinate: CLLocationCoordinate2D, manager: RecordingManager) async {
        if let here = LocationCache.shared.lastCoordinate,
           Self.distance(CLLocationCoordinate2D(latitude: here.latitude, longitude: here.longitude), coordinate)
            < Self.sameAreaRadius {
            await useCurrentLocation(manager: manager)
            return
        }
        chosenCoordinate = coordinate
        await refresh(manager: manager)
    }

    /// Works the list out again if the place or the month has changed since it
    /// last was. Cheap to call on every appearance. `place` skips looking up
    /// where the user is, for a caller that already knows.
    func refresh(manager: RecordingManager, at place: CLLocationCoordinate2D? = nil) async {
        generation += 1
        let run = generation

        let target: CLLocationCoordinate2D
        if let place {
            target = place
        } else if let chosenCoordinate {
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

        let month = month
        let followsUser = chosenCoordinate == nil
        if let loaded, species != nil, loaded.month == month,
           Self.distance(loaded.coordinate, target) < Self.sameAreaRadius {
            // Same list. A name that failed to look up last time (offline) is
            // worth another try, though.
            listFollowsUser = followsUser
            if placeName == nil {
                let name = await ObservationNameSheet.townName(at: loaded.coordinate)
                guard run == generation else { return }
                placeName = name
            }
            return
        }

        // A different list. The old one stays up while this one is worked
        // out, and the town name is looked up alongside it so the two land on
        // screen together.
        async let name = ObservationNameSheet.townName(at: target)
        let ranked = await Self.rankedSpecies(at: target, month: month, manager: manager)
        let town = await name
        guard run == generation else { return }
        species = ranked
        placeName = town
        listMonth = month
        listFollowsUser = followsUser
        listRevision += 1
        loaded = (target, month)
        status = .ready
    }

    /// Drops the list when there is nothing to show in its place.
    private func clear() {
        loaded = nil
        species = nil
        placeName = nil
        status = .loading
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
        month: Int?,
        manager: RecordingManager
    ) async -> [AreaSpecies] {
        let weeks = Array(weeks(in: month))
        if let likelihoods = await manager.areaLikelihoods(
            latitude: coordinate.latitude, longitude: coordinate.longitude, weeks: weeks
        ) {
            return await Task.detached(priority: .userInitiated) {
                rank(weeklyLikelihoods: likelihoods)
            }.value
        }
        // No live model: the offline grid's yes/no lists, which have nothing to
        // rank on.
        var allowed = Set<Int>()
        for week in weeks {
            allowed.formUnion(OfflineSpeciesFilter.shared.allowedIndices(
                lat: coordinate.latitude, lon: coordinate.longitude, week: week
            ) ?? [])
        }
        return await Task.detached(priority: .userInitiated) { [allowed] in
            alphabetical(allowed)
        }.value
    }

    /// The species the geo model puts at or above the range filter's own
    /// threshold in any of the given weeks, ranked by their average over all of
    /// them, most likely first. Ties go alphabetically by common name so two
    /// runs over the same numbers always give the same order.
    nonisolated static func rank(
        weeklyLikelihoods: [[Float]],
        threshold: Float = SpeciesRangeFilter.threshold
    ) -> [AreaSpecies] {
        let catalog = SpeciesCatalog.shared.all
        guard let count = weeklyLikelihoods.map(\.count).min(), count > 0 else { return [] }
        var scored: [(likelihood: Float, species: SpeciesCatalog.Species)] = []
        for index in 0..<min(count, catalog.count) {
            let values = weeklyLikelihoods.map { $0[index] }
            guard values.contains(where: { $0 >= threshold }) else { continue }
            let species = catalog[index]
            guard isBird(species) else { continue }
            scored.append((values.reduce(0, +) / Float(values.count), species))
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
                // No spacers between the three: that is what joins them into
                // one glass capsule, as the Life List's import and export are.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Choose Location", systemImage: "mappin.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Month", selection: Binding(
                            get: { model.month },
                            set: { month in Task { await model.setMonth(month, manager: manager) } }
                        )) {
                            Text("Any Month").tag(Int?.none)
                            ForEach(1...12, id: \.self) { month in
                                Text(TargetsModel.monthName(month)).tag(Int?.some(month))
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Month", systemImage: "calendar")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Sort By") {
                            ForEach(TargetsModel.Sort.Kind.allCases) { kind in
                                // A toggle rather than a button for the system
                                // checkmark. Tapping the checked one "turns it
                                // off", which `select` reads as flipping its
                                // direction.
                                Toggle(isOn: Binding(
                                    get: { model.sort.kind == kind },
                                    set: { _ in model.select(kind) }
                                )) {
                                    Text(kind.title)
                                    if model.sort.kind == kind {
                                        Text(model.sort.subtitle)
                                    }
                                }
                            }
                        }
                        Section {
                            Toggle("Include Life List Species", isOn: $model.includesLifeList)
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
                // The same trailing inset the Life List's buttons carry.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            // Every appearance, and every return to the foreground: the user
            // may have walked somewhere new. A no-op when they haven't.
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
                    backAccessibilityLabel: "Back to Targets",
                    // A place to look at, not a sighting being added.
                    pinShowsPlus: false
                ))
                // `@Observable` environment objects don't cross a cover.
                .environment(store)
            }
    }
}
