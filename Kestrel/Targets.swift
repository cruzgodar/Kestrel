import CoreLocation
import SwiftUI

/// What the Targets tab is showing: every bird the location models expect at one
/// place at one time of year, ranked from most to least likely, and what that place
/// is called.
///
/// **Ranking.** The location models (`SpeciesRangeFilter`) score every
/// catalog species for a place and BirdNET week — the same scores the
/// recording filter splits into tiers. A season is a span of BirdNET weeks
/// (see `weeks(for:)`): a bird is a target if it reaches the filter's
/// `commonThreshold` in any of them, so the rare tier's birds aren't
/// targets, and is ranked by its average over all of them, so a bird around
/// all season outranks one passing through for a week. The order runs
/// commonest first or rarest first — see `Sort`. The bundled offline grid only
/// knows yes/no, so when the models can't run, rarity order falls back to
/// alphabetical.
///
/// **Which place and season.** The current location and season by default, or
/// a spot picked on the map (one where the user is goes back to following
/// them), and Any Time of Year from the calendar menu. Neither is saved: every
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

    /// The time of year the list is for.
    enum Season: Hashable {
        /// This BirdNET week and one either side.
        case current
        case anyTime
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

    // The list on screen, and what it describes. A change of place or season
    // leaves all of these standing until the new list is ready, then replaces
    // them together — so the screen never blanks while it works, and the
    // heading never names a place or season the birds under it aren't for.

    /// Ranked most likely first. `nil` until the first list lands.
    private(set) var species: [AreaSpecies]?
    /// The town the list describes. `nil` when the lookup failed (offline).
    private(set) var placeName: String?
    /// The season the list is for. Can trail `season`, which changes the
    /// moment one is picked.
    private(set) var listSeason: Season = .current
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

    /// The season the list is for. Current until another is picked.
    private(set) var season: Season = .current

    /// The month Current is named for in the heading — the month it is now;
    /// `nil` for Any Time of Year, which names none.
    var listMonthName: String? {
        switch listSeason {
        case .current: Self.monthName(Calendar.current.component(.month, from: Date()))
        case .anyTime: nil
        }
    }

    static func monthName(_ month: Int) -> String {
        Calendar.current.standaloneMonthSymbols[month - 1]
    }

    /// Shows another season's birds.
    func setSeason(_ season: Season, manager: RecordingManager) async {
        guard season != self.season else { return }
        // The same place as the list on screen: a season change shouldn't wait
        // seconds on a fresh location fix to land back where it already was.
        let place = loaded?.coordinate
        self.season = season
        await refresh(manager: manager, at: place)
    }

    /// The BirdNET weeks a season spans, for the geo-model fallback: this week
    /// and one either side (wrapping at the year's end) for Current, all 48
    /// for Any Time of Year.
    nonisolated static func weeks(for season: Season, now: Date = Date()) -> [Int] {
        switch season {
        case .current:
            let week = SpeciesRangeFilter.birdnetWeek(from: now)
            return [week - 1, week, week + 1].map { ($0 + 47) % 48 + 1 }
        case .anyTime:
            return Array(1...48)
        }
    }

    /// Where and for which season `species` was worked out, so a refresh that
    /// finds neither has moved can leave the list alone.
    private var loaded: (coordinate: CLLocationCoordinate2D, season: Season)?
    /// Bumped by every refresh, so a slow one finishing after a newer one has
    /// started can't publish over it.
    private var generation = 0

    /// How far the current location has to move before the list is worked out
    /// again. The location models' resolution is far coarser than this, so
    /// anything closer is the same list.
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

    /// Works the list out again if the place or the season has changed since it
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

        let season = season
        let followsUser = chosenCoordinate == nil
        if let loaded, species != nil, loaded.season == season,
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
        let ranked = await Self.rankedSpecies(at: target, season: season, manager: manager)
        let town = await name
        guard run == generation else { return }
        species = ranked
        placeName = town
        listSeason = season
        listFollowsUser = followsUser
        listRevision += 1
        loaded = (target, season)
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
        season: Season,
        manager: RecordingManager
    ) async -> [AreaSpecies] {
        let weeks = weeks(for: season)
        if let likelihoods = await manager.areaLikelihoods(
            latitude: coordinate.latitude, longitude: coordinate.longitude, weeks: weeks
        ) {
            return await Task.detached(priority: .userInitiated) {
                rank(weeklyLikelihoods: likelihoods)
            }.value
        }
        // No live models: the offline grid's tiers, which have no scores to
        // rank on. Its common birds are the targets, as `rank` takes the live
        // models' `commonThreshold`.
        var common = Set<Int>()
        for week in weeks {
            if let tiers = OfflineSpeciesFilter.shared.tiers(
                lat: coordinate.latitude, lon: coordinate.longitude, week: week
            ) {
                common.formUnion(tiers.allowed.subtracting(tiers.rare))
            }
        }
        return await Task.detached(priority: .userInitiated) { [common] in
            alphabetical(common)
        }.value
    }

    /// The species the location models put at or above the range filter's
    /// `commonThreshold` in any of the given weeks, ranked by their average over all of
    /// them, most likely first. Ties go alphabetically by common name so two
    /// runs over the same numbers always give the same order.
    nonisolated static func rank(
        weeklyLikelihoods: [[Float]],
        threshold: Float = SpeciesRangeFilter.commonThreshold
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

    /// Only birds are targets — see `SpeciesCatalog.nonBirdIndices`.
    private nonisolated static func isBird(_ species: SpeciesCatalog.Species) -> Bool {
        SpeciesCatalog.shared.isBird(scientificName: species.scientificName)
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
                        Picker("Time of Year", selection: Binding(
                            get: { model.season },
                            set: { season in Task { await model.setSeason(season, manager: manager) } }
                        )) {
                            Text("Current Month").tag(TargetsModel.Season.current)
                            Text("Any Time of Year").tag(TargetsModel.Season.anyTime)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Time of Year", systemImage: "calendar")
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
