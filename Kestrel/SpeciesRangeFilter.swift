import Foundation
import onnxruntime_objc

private nonisolated struct CachedFilter: Codable {
    /// Where and when the geo model was run to produce `allowedIndices`.
    ///
    /// `speciesCount` is written for diagnostics only — nothing reads it back,
    /// and it is kept because a cache file that can't say what it describes is
    /// no use when something looks wrong.
    ///
    /// The other four are load-bearing. `week` and `savedAt` decide whether the
    /// list itself is still worth using (`SpeciesRangeFilter.isCurrent`), and
    /// `latitude` / `longitude` are the app's only *persistent* record of where
    /// the user has been — see `SpeciesRangeFilter.cachedCoordinate`, which is
    /// what keeps a refused list from collapsing into no filter at all.
    let latitude: Double
    let longitude: Double
    let week: Int
    let speciesCount: Int
    let allowedIndices: [Int]
    /// The part of `allowedIndices` that is rare here — see `Tiers`. `nil` in
    /// files written before the filter had tiers.
    var rareIndices: [Int]? = nil
    let savedAt: Date
}

/// Which species are plausible at a place and week, from two bundled
/// location models.
///
/// **The BirdNET+ Geomodel v3** (github.com/birdnet-team/geomodel, v3.0.3,
/// weights CC BY-SA 4.0) answers for almost every label. It replaced the
/// BirdNET v2.4 meta-model, whose list was far too strict: checked against
/// eBird reports at five places in October, the v2.4 list at its 0.03
/// threshold caught 76% of the species reported on a quarter of days or more,
/// and 27% of the occasional ones; the geomodel's list at `rangeThreshold`
/// catches 99% and 96%.
///
/// **The v2.4 model** still answers for the 33 labels the geomodel has no
/// species for (some Hawaiian birds, Japanese Tit, a few insects and toads —
/// see `scripts/build_geomodel_index.py`). Its scores run on a different
/// scale, so they are mapped onto the geomodel's (`calibratedLegacy`) and
/// every reader sees one score per catalog index.
actor SpeciesRangeFilter {
    /// At or above this score a species is common here, and judged at
    /// BirdNET's normal bar. Also what makes a bird a Target.
    static let commonThreshold: Float = 0.3
    /// At or above this score (and below `commonThreshold`) a species is in
    /// range but rare, held to `BirdNETClassifier.rareThreshold`. Below it,
    /// it is out of range.
    static let rangeThreshold: Float = 0.05
    static let speciesCount = 6_522

    private struct Model {
        let session: ORTSession
        let inputName: String
        let outputName: String
    }

    private let env: ORTEnv
    private let geomodel: Model
    /// `nil` if it fails to load: the geomodel alone still covers all but 33
    /// labels.
    private let legacy: Model?
    /// For each geomodel output, the catalog indices it counts for — usually
    /// one, several for a lump, none for an animal BirdNET doesn't know. From
    /// `geomodel_birdnet_index.txt`.
    private let geomodelIndices: [[Int]]
    /// Catalog indices no geomodel output covers; the v2.4 model scores these.
    private let uncovered: [Int]

    init() throws {
        let env = try ORTEnv(loggingLevel: .warning)
        guard let indexURL = Bundle.main.url(forResource: "geomodel_birdnet_index", withExtension: "txt"),
              let indexText = try? String(contentsOf: indexURL, encoding: .utf8) else {
            throw NSError(domain: "SpeciesRangeFilter", code: 1, userInfo: [NSLocalizedDescriptionKey: "geomodel index missing"])
        }
        // Not split on newlines with `omittingEmptySubsequences`: an empty line
        // is an output that maps to nothing, and dropping it would shift every
        // output after it.
        let rows = indexText.components(separatedBy: "\n")
        let indices = rows.dropLast(rows.last == "" ? 1 : 0).map { row in
            row.split(separator: ",").compactMap { Int($0) }
        }
        self.env = env
        self.geomodel = try Self.load("geomodel_v3", env: env)
        self.legacy = try? Self.load("birdnet_data_model", env: env)
        self.geomodelIndices = indices
        let covered = Set(indices.joined())
        self.uncovered = (0..<Self.speciesCount).filter { !covered.contains($0) }
    }

    private static func load(_ name: String, env: ORTEnv) throws -> Model {
        guard let url = Bundle.main.url(forResource: name, withExtension: "onnx") else {
            throw NSError(domain: "SpeciesRangeFilter", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name) missing"])
        }
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        try options.setGraphOptimizationLevel(.all)
        if ORTIsCoreMLExecutionProviderAvailable() {
            // Same leaked-temp-model story as BirdNET — see `CoreMLModelCache`.
            var coreML = ["MLComputeUnits": "ALL"]
            if let cache = CoreMLModelCache.directory(forModel: name) {
                coreML["ModelCacheDirectory"] = cache
            }
            try? options.appendCoreMLExecutionProvider(withOptionsV2: coreML)
        }
        let session = try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
        return Model(
            session: session,
            inputName: try session.inputNames().first ?? "input",
            outputName: try session.outputNames().first ?? "output"
        )
    }

    // MARK: Tiers

    /// A place-and-week species list, in the classifier's terms.
    nonisolated struct Tiers: Sendable, Equatable {
        /// Every species in range: `rangeThreshold` or above.
        let allowed: Set<Int>
        /// The part of `allowed` below `commonThreshold`.
        let rare: Set<Int>
    }

    /// Birds only: the models also score frogs, insects and mammals, which
    /// no list in the app should hold (see `SpeciesCatalog.nonBirdIndices`).
    nonisolated static func tiers(
        scores: [Float],
        isBird: (Int) -> Bool = SpeciesCatalog.shared.isBird
    ) -> Tiers {
        var allowed = Set<Int>()
        var rare = Set<Int>()
        for (index, score) in scores.enumerated() where score >= rangeThreshold && isBird(index) {
            allowed.insert(index)
            if score < commonThreshold { rare.insert(index) }
        }
        return Tiers(allowed: allowed, rare: rare)
    }

    /// The tiers for a place and week, persisting nothing — for a place the
    /// user was, rather than is (see `computeAndCache`).
    func tiers(lat: Double, lon: Double, week: Int) throws -> Tiers {
        Self.tiers(scores: try likelihoods(lat: lat, lon: lon, weeks: [week])[0])
    }

    /// Runs the models for the given location and persists the result.
    func computeAndCache(lat: Double, lon: Double, week: Int) throws -> Tiers {
        let tiers = Self.tiers(scores: try likelihoods(lat: lat, lon: lon, weeks: [week])[0])
        let cached = CachedFilter(
            latitude: lat,
            longitude: lon,
            week: week,
            speciesCount: tiers.allowed.count,
            allowedIndices: tiers.allowed.sorted(),
            rareIndices: tiers.rare.sorted(),
            savedAt: Date()
        )
        try? Self.write(cached)
        return tiers
    }

    // MARK: Scores

    /// Occurrence scores for a place, one array per BirdNET week asked for,
    /// each with one score per catalog index in `SpeciesCatalog.all`'s order,
    /// on the geomodel's scale. All weeks run as one batch.
    ///
    /// Persists nothing, unlike `computeAndCache`. The Targets tab asks about
    /// places the user has merely picked on a map, and the cache file is the
    /// app's record of where the user actually *is* — writing a browsed place
    /// into it would point the next recording's fallback filter at the wrong
    /// continent.
    func likelihoods(lat: Double, lon: Double, weeks: [Int]) throws -> [[Float]] {
        guard !weeks.isEmpty else { return [] }
        let geo = try Self.run(geomodel, lat: lat, lon: lon, weeks: weeks)
        let old = try legacy.map { try Self.run($0, lat: lat, lon: lon, weeks: weeks) }
        return weeks.indices.map { w in
            var scores = [Float](repeating: 0, count: Self.speciesCount)
            for (output, indices) in geomodelIndices.enumerated() where !indices.isEmpty {
                let p = geo[w][output]
                // A lump: the label takes its likeliest daughter species.
                for index in indices where p > scores[index] { scores[index] = p }
            }
            if let old {
                for index in uncovered { scores[index] = Self.calibratedLegacy(old[w][index]) }
            }
            return scores
        }
    }

    /// Maps a v2.4 score onto the geomodel's scale, so the two can share
    /// thresholds: v2.4's 0.03 (its long-standing range threshold) lands on
    /// `commonThreshold`, and its 0.003 on `rangeThreshold` — at 0.003 the
    /// v2.4 list caught 96% of the species eBird reports regularly, close to
    /// the geomodel's 99% at `rangeThreshold`. Linear between those points,
    /// and from 0 and to 1 either side.
    nonisolated static func calibratedLegacy(_ p: Float) -> Float {
        let anchors: [(legacy: Float, geomodel: Float)] = [
            (0, 0), (0.003, rangeThreshold), (0.03, commonThreshold), (1, 1),
        ]
        let x = min(max(p, 0), 1)
        for (a, b) in zip(anchors, anchors.dropFirst()) where x <= b.legacy {
            return a.geomodel + (x - a.legacy) / (b.legacy - a.legacy) * (b.geomodel - a.geomodel)
        }
        return 1
    }

    /// One `[week][output]` batch through a model.
    private static func run(_ model: Model, lat: Double, lon: Double, weeks: [Int]) throws -> [[Float]] {
        let samples: [Float] = weeks.flatMap { [Float(lat), Float(lon), Float($0)] }
        let byteCount = samples.count * MemoryLayout<Float>.stride
        let data = NSMutableData(length: byteCount)!
        samples.withUnsafeBufferPointer { src in
            data.replaceBytes(in: NSRange(location: 0, length: byteCount), withBytes: src.baseAddress!)
        }
        let input = try ORTValue(
            tensorData: data, elementType: .float,
            shape: [NSNumber(value: weeks.count), 3]
        )
        let outputs = try model.session.run(
            withInputs: [model.inputName: input],
            outputNames: [model.outputName],
            runOptions: nil
        )
        guard let outValue = outputs[model.outputName] else {
            throw NSError(domain: "SpeciesRangeFilter", code: 2)
        }
        let outData = try outValue.tensorData()
        let count = outData.length / MemoryLayout<Float>.stride
        var flat = [Float](repeating: 0, count: count)
        flat.withUnsafeMutableBytes { dst in
            outData.getBytes(dst.baseAddress!, length: outData.length)
        }
        let perWeek = count / weeks.count
        return (0..<weeks.count).map { Array(flat[($0 * perWeek)..<(($0 + 1) * perWeek)]) }
    }

    // MARK: Cache validity

    /// Past this age a cached filter is dropped by every reader.
    ///
    /// The BirdNET week repeats annually, so the week check below can't bound
    /// age on its own: a list saved in week 18 of last year matches week 18 of
    /// this one exactly. Thirty days is comfortably longer than the ~7.5 days a
    /// single week spans, so this only ever catches a cache that has been sitting
    /// unused for a season or more.
    static let maxCacheAge: TimeInterval = 30 * 24 * 60 * 60

    /// Whether a cached filter still describes *this* week, and isn't stale.
    ///
    /// Required by `loadCached`, which is the list a recording session actually
    /// filters detections with. A species list for the wrong season isn't merely
    /// old, it is wrong in both directions — it suppresses birds that are here
    /// now and admits ones that aren't — and BirdNET's week is exactly the
    /// seasonal axis the geo model turns on.
    nonisolated static func isCurrent(
        cachedWeek: Int, savedAt: Date, week: Int, now: Date = Date()
    ) -> Bool {
        cachedWeek == week && isWithinMaxAge(savedAt: savedAt, now: now)
    }

    /// Whether a cached filter is young enough to be worth anything at all.
    nonisolated static func isWithinMaxAge(savedAt: Date, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        // A file stamped in the future is a clock change, not a fresh cache.
        // Treat it as usable rather than throwing it away over a DST shift.
        return age < maxCacheAge
    }

    /// Loads the most recently cached filter, if it still describes `week`. Does
    /// not run the model.
    ///
    /// This is the "Using last-known list" fallback a recording session falls
    /// back on when the live model can't run, so a cache from another season is
    /// refused outright: the caller then drops through to the offline grid
    /// filter, which is week-aware, and which `cachedCoordinate` guarantees has a
    /// place to work from whenever this file exists at all. A wrong-season list
    /// is wrong in both directions — it suppresses birds that are here now and
    /// admits ones that aren't — and it says nothing about being wrong.
    ///
    /// Refusing is only the safer answer because something underneath it
    /// answers. It briefly wasn't: with the grid's coordinate coming solely from
    /// this process, a cold launch whose fix hadn't landed fell all the way
    /// through to no filter at all. See `cachedCoordinate`.
    func loadCached(week: Int, now: Date = Date()) -> Tiers? {
        guard let cached = Self.loadCacheFile() else { return nil }
        guard Self.isCurrent(
            cachedWeek: cached.week, savedAt: cached.savedAt, week: week, now: now
        ) else {
            Log.info("SpeciesRangeFilter: cached filter is from week \(cached.week), not \(week) — ignoring")
            return nil
        }
        return Tiers(
            allowed: Self.birds(cached.allowedIndices),
            rare: Self.birds(cached.rareIndices ?? [])
        )
    }

    /// Reads the cached allowed-index set straight off disk without
    /// constructing an `ORTSession` — cheap enough to call from the main
    /// actor (e.g. the life list's "in this area" grouping). Returns `nil`
    /// when no location filter has been computed yet, or when the one on disk
    /// is older than `maxCacheAge`.
    ///
    /// Deliberately *not* week-gated, unlike `loadCached`. Its readers — the
    /// photo prefetch's protected set and the life list's "found in this area"
    /// grouping — want "roughly what lives around here", which a neighbouring
    /// week answers perfectly well, and none of them gates a detection. Dropping
    /// it on a week boundary would unprotect a whole region's cached photos and
    /// re-download them, possibly over cellular, to fix a grouping heading.
    nonisolated static func cachedAllowedIndices(now: Date = Date()) -> Set<Int>? {
        guard let cached = loadCacheFile(),
              isWithinMaxAge(savedAt: cached.savedAt, now: now) else { return nil }
        return birds(cached.allowedIndices)
    }

    /// A cached list less anything that isn't a bird. Lists saved before the
    /// filter went birds-only (see `tiers(scores:)`) can hold frogs and
    /// crickets until they age out.
    private nonisolated static func birds(_ indices: [Int]) -> Set<Int> {
        let catalog = SpeciesCatalog.shared
        return Set(indices.filter(catalog.isBird))
    }

    /// Where the last successful geo run was computed, read straight off the
    /// cache file — the app's only record of the user's whereabouts that
    /// survives a relaunch.
    ///
    /// **This is what makes `loadCached`'s week gate affordable.** Refusing a
    /// wrong-season list is right, but it only helps if something underneath it
    /// can still answer, and underneath it is `OfflineSpeciesFilter` — which is
    /// week-aware, and needs nothing but a coordinate to produce a *current*
    /// season's list for the same place. Its other two sources are this run's own
    /// fix and `LocationCache`, and both are empty on exactly the launch that
    /// reaches the fallback at all: a cold start whose fix hasn't landed
    /// (`LocationCache` is process-local and starts out with nothing).
    ///
    /// With no third source the whole chain terminated at `allowedIndices = nil`,
    /// which is not "no filter" in any harmless sense —
    /// `BirdNETClassifier.accepts` reads a nil filter as *everything in range*,
    /// so all 6,522 labels are judged at `detectionThreshold` rather than at the
    /// far higher `outOfRangeThreshold`. That is the misidentification the range
    /// filter exists to prevent, and it was reachable by a user who had simply
    /// not opened the app for a week.
    ///
    /// Age-gated like `cachedAllowedIndices`, and pointedly **not** week-gated: a
    /// place does not go out of season, and the week the grid is asked about is
    /// today's either way. `maxCacheAge` still applies because a coordinate old
    /// enough to be dropped is one the user may be a continent away from, and a
    /// list built there would suppress every bird actually in front of them — the
    /// opposite failure, and the quieter one.
    nonisolated static func cachedCoordinate(
        now: Date = Date()
    ) -> (latitude: Double, longitude: Double)? {
        guard let cached = loadCacheFile(),
              isWithinMaxAge(savedAt: cached.savedAt, now: now) else { return nil }
        return (cached.latitude, cached.longitude)
    }

    // MARK: Persistence

    /// The cache file, decoded, with no validity rule applied — each of the three
    /// readers above adds its own. One decode rather than three, so a reader
    /// can't be given a different answer by a change meant for another.
    private nonisolated static func loadCacheFile() -> CachedFilter? {
        guard let url = try? cacheURL(),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CachedFilter.self, from: data)
        } catch {
            Log.error("SpeciesRangeFilter: failed to load cache — \(error)")
            return nil
        }
    }

    private nonisolated static func cacheURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("species_filter.json")
    }

    private nonisolated static func write(_ cached: CachedFilter) throws {
        let url = try cacheURL()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cached)
        try data.write(to: url, options: .atomic)
    }
}

extension SpeciesRangeFilter {
    /// Maps `Date` to BirdNET's 1–48 week numbering.
    static func birdnetWeek(from date: Date = Date()) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let month = cal.component(.month, from: date)  // 1...12
        let day   = cal.component(.day,   from: date)  // 1...31
        let quarter = min(4, Int(ceil(Double(day) / 7.5)))  // 1...4
        return (month - 1) * 4 + quarter                    // 1...48
    }
}
