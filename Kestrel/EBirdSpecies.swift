import Foundation

/// The eBird API v2, as far as Kestrel uses it.
///
/// https://documenter.getpostman.com/view/664302/S1ENwy59
nonisolated enum EBirdAPI {
    static let key = "22c2ec24-e0f6-4c58-9291-95c5e257437c"
    static let base = URL(string: "https://api.ebird.org/v2/")!

    static func get<T: Decodable>(
        _ path: String,
        _ query: [URLQueryItem] = [],
        as type: T.Type
    ) async throws -> T {
        var components = URLComponents(
            url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "X-eBirdApiToken")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// How often each species is actually reported around a place at a time of
/// year, from eBird — what the nearby-species filter and the Targets ranking
/// are built on, ahead of the BirdNET geo model they fall back to.
///
/// **Why not `product/spplist`.** It is every species ever reported in a
/// region, in taxonomic order: no season, no counts, and an escaped Emu ranks
/// level with an American Crow. Nothing in the API carries frequencies (the
/// website's bar charts do, behind a sign-in), so they are measured here.
///
/// **How.** `data/obs/{region}/historic/{y}/{m}/{d}` is every species reported
/// in a region on one day. Asked of a spread of days around the same date in
/// past years (`Sample`), the fraction of those days a species turns up on is
/// a seasonal, local measure of how common it is — a Mallard is every day, a
/// Short-eared Owl one in forty. The region is the county where eBird has
/// enough reports there to say, else the state, else the country (see
/// `isWellCovered`); with none of those, callers fall back to the geo model.
///
/// Answers are kept on disk (Application Support), keyed by region and sample:
/// past years' reports don't change, so a list made once is good until the
/// years it sampled move on at New Year — and it makes the filter work offline
/// at any place it has seen this season.
actor EBirdSpecies {
    static let shared = EBirdSpecies()

    /// Reported on at least this fraction of the sampled days, and in at least
    /// two of the sampled years, and a species is common enough to be judged
    /// at BirdNET's normal bar. Below it (or seen in one year only — a single
    /// long-staying rarity that drew a crowd can be reported every day for a
    /// month) it is *rare*: still in range, but held to `rareThreshold`.
    nonisolated static let commonFrequency: Float = 0.1

    /// A day only counts toward coverage if this many species were reported
    /// on it; fewer is a lone checklist, not a picture of the place.
    nonisolated static let coveredDaySpecies = 10
    /// The share of sampled days that must be covered before a region's
    /// frequencies are believed. Below it the next region up is asked.
    nonisolated static let requiredCoverage = 0.5

    /// How far back `recent/notable` is read. Reviewed notable sightings of a
    /// species are evidence it is here *now*, whatever past years said.
    nonisolated static let notableDays = 14
    private static let notableLifetime: TimeInterval = 6 * 60 * 60

    /// Concurrent requests per fetch. Polite to eBird and plenty fast: a
    /// 45-day sample lands in around ten seconds.
    private static let concurrency = 6

    // MARK: Samples

    /// Which past days a frequency table is measured over.
    nonisolated struct Sample: Sendable, Equatable {
        /// Names the sample in the cache, and changes whenever `dates` would.
        let key: String
        let dates: [DateComponents]
        let years: Int
    }

    /// The fifteen days centered on a BirdNET week, in each of the last three
    /// full years — what the recording filter is built from.
    nonisolated static func weekSample(week: Int, now: Date = Date()) -> Sample {
        let thisYear = calendar.component(.year, from: now)
        let years = Array((thisYear - 3)...(thisYear - 1))
        let month = (week - 1) / 4 + 1
        // Mid-points of BirdNET's quarter-month weeks (see `birdnetWeek`):
        // 1–7, 8–15, 16–22, 23–end.
        let centerDay = [4, 11, 19, 26][(week - 1) % 4]
        var dates: [DateComponents] = []
        for year in years {
            guard let center = calendar.date(from: DateComponents(year: year, month: month, day: centerDay))
            else { continue }
            for offset in -7...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: center) else { continue }
                dates.append(calendar.dateComponents([.year, .month, .day], from: day))
            }
        }
        return Sample(key: "w\(week)-\(years[0])-\(years.last!)", dates: dates, years: years.count)
    }

    /// Every other day of a month in each of the last three full years, or for
    /// `nil` (any time of year) two days a month over the last two — for the
    /// Targets tab.
    nonisolated static func monthSample(month: Int?, now: Date = Date()) -> Sample {
        let thisYear = calendar.component(.year, from: now)
        guard let month else {
            let years = Array((thisYear - 2)...(thisYear - 1))
            var dates: [DateComponents] = []
            for year in years {
                for m in 1...12 {
                    for day in [8, 22] { dates.append(DateComponents(year: year, month: m, day: day)) }
                }
            }
            return Sample(key: "year-\(years[0])-\(years.last!)", dates: dates, years: years.count)
        }
        let years = Array((thisYear - 3)...(thisYear - 1))
        let dates: [DateComponents] = years.flatMap { year in
            stride(from: 1, through: 28, by: 2).map { DateComponents(year: year, month: month, day: $0) }
        }
        return Sample(key: "m\(month)-\(years[0])-\(years.last!)", dates: dates, years: years.count)
    }

    private nonisolated static let calendar = Calendar(identifier: .gregorian)

    // MARK: Frequencies

    /// One region's species over one sample.
    nonisolated struct Frequencies: Codable, Sendable {
        nonisolated struct Entry: Codable, Sendable, Equatable {
            /// `SpeciesCatalog.all` index.
            let index: Int
            /// Fraction of the sampled days it was reported on.
            let frequency: Float
            /// How many of the sampled years it was reported in at all.
            let years: Int
        }

        let region: String
        let sampleKey: String
        let sampledYears: Int
        let entries: [Entry]
        let savedAt: Date
    }

    /// Tallies a sample's daily reports into per-species frequencies, after
    /// mapping eBird's codes onto catalog indices. `days` holds one array of
    /// species codes per sampled day, paired with that day's year.
    nonisolated static func tally(
        days: [(year: Int, codes: [String])],
        indices: (String) -> [Int]
    ) -> [Frequencies.Entry] {
        guard !days.isEmpty else { return [] }
        var dayCounts: [Int: Int] = [:]
        var years: [Int: Set<Int>] = [:]
        for day in days {
            var seen = Set<Int>()
            for code in day.codes { seen.formUnion(indices(code)) }
            for index in seen {
                dayCounts[index, default: 0] += 1
                years[index, default: []].insert(day.year)
            }
        }
        return dayCounts
            .map { index, count in
                Frequencies.Entry(
                    index: index,
                    frequency: Float(count) / Float(days.count),
                    years: years[index]?.count ?? 0
                )
            }
            .sorted { $0.index < $1.index }
    }

    /// Whether enough of a sample's days had real reporting behind them.
    nonisolated static func isWellCovered(speciesPerDay: [Int]) -> Bool {
        guard !speciesPerDay.isEmpty else { return false }
        let covered = speciesPerDay.filter { $0 >= coveredDaySpecies }.count
        return Double(covered) / Double(speciesPerDay.count) >= requiredCoverage
    }

    /// Splits a frequency table into the recording filter's two tiers: every
    /// species reported at all is in range, and the ones that aren't common
    /// (see `commonFrequency`) are also *rare*. Recent reviewed notable
    /// sightings join the rare tier if they aren't already in range.
    nonisolated static func tiers(
        _ entries: [Frequencies.Entry],
        sampledYears: Int,
        notable: Set<Int> = []
    ) -> (allowed: Set<Int>, rare: Set<Int>) {
        let yearsForCommon = min(2, sampledYears)
        var allowed = Set<Int>()
        var rare = Set<Int>()
        for entry in entries {
            allowed.insert(entry.index)
            if entry.frequency < commonFrequency || entry.years < yearsForCommon {
                rare.insert(entry.index)
            }
        }
        for index in notable where !allowed.contains(index) {
            allowed.insert(index)
            rare.insert(index)
        }
        return (allowed, rare)
    }

    // MARK: Public answers

    /// The recording filter for a place this BirdNET week: everything reported
    /// there around now in past years (plus reviewed notable sightings of the
    /// last two weeks), and which of those are rare.
    ///
    /// With `network: false` this only reads what earlier calls left on disk
    /// — instant, for a session that shouldn't wait — and skips the notable
    /// sightings. `nil` when eBird can't answer for the place.
    func detectionFilter(
        latitude: Double, longitude: Double, week: Int, network: Bool
    ) async -> (allowed: Set<Int>, rare: Set<Int>)? {
        let sample = Self.weekSample(week: week)
        guard let frequencies = await frequencies(
            latitude: latitude, longitude: longitude, sample: sample, network: network
        ) else { return nil }
        let notable = network ? await notableIndices(region: frequencies.region) : []
        return Self.tiers(frequencies.entries, sampledYears: frequencies.sampledYears, notable: notable)
    }

    /// Every species reported at a place in a month (`nil`: any time of
    /// year), commonest first. `nil` when eBird can't answer for the place.
    func ranking(latitude: Double, longitude: Double, month: Int?) async -> [Frequencies.Entry]? {
        guard let frequencies = await frequencies(
            latitude: latitude, longitude: longitude,
            sample: Self.monthSample(month: month), network: true
        ) else { return nil }
        return frequencies.entries.sorted { $0.frequency > $1.frequency }
    }

    // MARK: Fetching

    private func frequencies(
        latitude: Double, longitude: Double, sample: Sample, network: Bool
    ) async -> Frequencies? {
        guard let regions = await regions(latitude: latitude, longitude: longitude, network: network)
        else { return nil }
        for region in regions {
            var found = Self.loadFrequencies(region: region, sample: sample)
            if found == nil {
                guard network else { continue }
                // A network failure ends the search: a bigger region won't
                // fare better, and settling for one would be a worse list.
                guard let fresh = await fetchFrequencies(region: region, sample: sample) else { return nil }
                try? Self.save(fresh)
                found = fresh
            }
            // Empty is the marker for "too sparse", saved so the region isn't
            // asked again — try the next one up.
            if let found, !found.entries.isEmpty { return found }
        }
        return nil
    }

    /// `nil` when the requests failed. A region too thinly covered to believe
    /// comes back with no entries.
    private func fetchFrequencies(region: String, sample: Sample) async -> Frequencies? {
        let started = Date()
        var days: [(year: Int, codes: [String])] = []
        var failures = 0
        await withTaskGroup(of: (Int, [String]?).self) { group in
            var pending = sample.dates.makeIterator()
            func addNext() {
                guard let date = pending.next(),
                      let y = date.year, let m = date.month, let d = date.day else { return }
                group.addTask {
                    let codes = try? await EBirdAPI.get(
                        "data/obs/\(region)/historic/\(y)/\(m)/\(d)",
                        as: [Observation].self
                    ).map(\.speciesCode)
                    return (y, codes)
                }
            }
            for _ in 0..<Self.concurrency { addNext() }
            for await (year, codes) in group {
                if let codes { days.append((year, codes)) } else { failures += 1 }
                addNext()
            }
        }
        // A few dropped days don't bias the rest; many mean the network is
        // the problem.
        guard failures * 10 <= sample.dates.count else {
            Log.warning("EBirdSpecies: \(failures)/\(sample.dates.count) requests failed for \(region)")
            return nil
        }
        let entries: [Frequencies.Entry]
        if Self.isWellCovered(speciesPerDay: days.map(\.codes.count)) {
            let catalog = SpeciesCatalog.shared
            entries = Self.tally(days: days, indices: { catalog.indices(forEBirdCode: $0) })
        } else {
            entries = []
        }
        Log.info("EBirdSpecies: \(region) \(sample.key) — \(entries.count) species in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        return Frequencies(
            region: region, sampleKey: sample.key, sampledYears: sample.years,
            entries: entries, savedAt: Date()
        )
    }

    private nonisolated struct Observation: Decodable {
        let speciesCode: String
    }

    private nonisolated struct NotableObservation: Decodable {
        let speciesCode: String
        let obsValid: Bool?
        let obsReviewed: Bool?
    }

    private var notableCache: [String: (indices: Set<Int>, at: Date)] = [:]

    private func notableIndices(region: String) async -> Set<Int> {
        if let cached = notableCache[region], Date().timeIntervalSince(cached.at) < Self.notableLifetime {
            return cached.indices
        }
        guard let observations = try? await EBirdAPI.get(
            "data/obs/\(region)/recent/notable",
            [URLQueryItem(name: "back", value: "\(Self.notableDays)"),
             URLQueryItem(name: "detail", value: "simple")],
            as: [NotableObservation].self
        ) else { return [] }
        let catalog = SpeciesCatalog.shared
        // Only sightings a reviewer has accepted: unreviewed notables include
        // every misidentification eBird's filters caught.
        let indices = Set(observations
            .filter { $0.obsValid == true && $0.obsReviewed == true }
            .flatMap { catalog.indices(forEBirdCode: $0.speciesCode) })
        notableCache[region] = (indices, Date())
        return indices
    }

    // MARK: Regions

    private nonisolated struct Hotspot: Decodable {
        let countryCode: String?
        let subnational1Code: String?
        let subnational2Code: String?
        let lat: Double
        let lng: Double
    }

    /// The eBird regions containing a place, smallest first — county, state,
    /// country — worked out from the nearest eBird hotspot, which carries all
    /// three codes. Remembered per ~10 km cell so the filter can run offline.
    private func regions(latitude: Double, longitude: Double, network: Bool) async -> [String]? {
        let cell = Self.regionCell(latitude: latitude, longitude: longitude)
        var cache = Self.loadRegionCache()
        if let known = cache[cell] { return known }
        guard network else { return nil }
        for distance in [25, 150] {
            guard let hotspots = try? await EBirdAPI.get(
                "ref/hotspot/geo",
                [URLQueryItem(name: "lat", value: String(format: "%.4f", latitude)),
                 URLQueryItem(name: "lng", value: String(format: "%.4f", longitude)),
                 URLQueryItem(name: "dist", value: "\(distance)"),
                 URLQueryItem(name: "fmt", value: "json")],
                as: [Hotspot].self
            ) else { return nil }
            let nearest = hotspots.min {
                Self.squaredDistance($0, latitude, longitude) < Self.squaredDistance($1, latitude, longitude)
            }
            guard let nearest else { continue }
            var regions: [String] = []
            for code in [nearest.subnational2Code, nearest.subnational1Code, nearest.countryCode] {
                if let code, !code.isEmpty, !regions.contains(code) { regions.append(code) }
            }
            guard !regions.isEmpty else { continue }
            cache[cell] = regions
            Self.saveRegionCache(cache)
            return regions
        }
        return nil
    }

    nonisolated static func regionCell(latitude: Double, longitude: Double) -> String {
        String(format: "%.1f,%.1f", latitude, longitude)
    }

    private nonisolated static func squaredDistance(_ h: Hotspot, _ lat: Double, _ lon: Double) -> Double {
        let dLat = h.lat - lat
        let dLon = (h.lng - lon) * cos(lat * .pi / 180)
        return dLat * dLat + dLon * dLon
    }

    // MARK: Persistence

    private nonisolated static func directory() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("ebird", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static func frequenciesURL(region: String, sampleKey: String) throws -> URL {
        try directory().appendingPathComponent("\(region)_\(sampleKey).json")
    }

    private nonisolated static func loadFrequencies(region: String, sample: Sample) -> Frequencies? {
        guard let url = try? frequenciesURL(region: region, sampleKey: sample.key),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Frequencies.self, from: data)
    }

    private nonisolated static func save(_ frequencies: Frequencies) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(frequencies).write(
            to: frequenciesURL(region: frequencies.region, sampleKey: frequencies.sampleKey),
            options: .atomic
        )
    }

    private nonisolated static func loadRegionCache() -> [String: [String]] {
        guard let url = try? directory().appendingPathComponent("regions.json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    private nonisolated static func saveRegionCache(_ cache: [String: [String]]) {
        guard let url = try? directory().appendingPathComponent("regions.json"),
              let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
