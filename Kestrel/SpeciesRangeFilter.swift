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
    let savedAt: Date
}

actor SpeciesRangeFilter {
    static let threshold: Float = 0.03
    static let speciesCount = 6_522

    private let env: ORTEnv
    private let session: ORTSession
    private let inputName: String
    private let outputName: String

    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "birdnet_data_model", withExtension: "onnx") else {
            throw NSError(domain: "SpeciesRangeFilter", code: 1, userInfo: [NSLocalizedDescriptionKey: "geo model missing"])
        }
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        try options.setGraphOptimizationLevel(.all)
        if ORTIsCoreMLExecutionProviderAvailable() {
            // Same leaked-temp-model story as BirdNET — see `CoreMLModelCache`.
            var coreML = ["MLComputeUnits": "ALL"]
            if let cache = CoreMLModelCache.directory(forModel: "birdnet_data_model") {
                coreML["ModelCacheDirectory"] = cache
            }
            try? options.appendCoreMLExecutionProvider(withOptionsV2: coreML)
        }
        self.env = env
        self.session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        let inputs = try session.inputNames()
        let outputs = try session.outputNames()
        self.inputName = inputs.first ?? "input"
        self.outputName = outputs.first ?? "output"
    }

    /// Runs the geo model for the given location and persists the result.
    func computeAndCache(lat: Double, lon: Double, week: Int) throws -> Set<Int> {
        let samples: [Float] = [Float(lat), Float(lon), Float(week)]
        let byteCount = samples.count * MemoryLayout<Float>.stride
        let data = NSMutableData(length: byteCount)!
        samples.withUnsafeBufferPointer { src in
            data.replaceBytes(in: NSRange(location: 0, length: byteCount), withBytes: src.baseAddress!)
        }
        let input = try ORTValue(tensorData: data, elementType: .float, shape: [1, 3])
        let outputs = try session.run(
            withInputs: [inputName: input],
            outputNames: [outputName],
            runOptions: nil
        )
        guard let outValue = outputs[outputName] else {
            throw NSError(domain: "SpeciesRangeFilter", code: 2)
        }
        let outData = try outValue.tensorData()
        let count = outData.length / MemoryLayout<Float>.stride
        var probs = [Float](repeating: 0, count: count)
        probs.withUnsafeMutableBytes { dst in
            outData.getBytes(dst.baseAddress!, length: outData.length)
        }

        var allowed: Set<Int> = []
        allowed.reserveCapacity(512)
        for (index, p) in probs.enumerated() where p >= Self.threshold {
            allowed.insert(index)
        }

        let cached = CachedFilter(
            latitude: lat,
            longitude: lon,
            week: week,
            speciesCount: allowed.count,
            allowedIndices: allowed.sorted(),
            savedAt: Date()
        )
        try? Self.write(cached)
        return allowed
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
    func loadCached(week: Int, now: Date = Date()) -> Set<Int>? {
        guard let cached = Self.loadCacheFile() else { return nil }
        guard Self.isCurrent(
            cachedWeek: cached.week, savedAt: cached.savedAt, week: week, now: now
        ) else {
            Log.info("SpeciesRangeFilter: cached filter is from week \(cached.week), not \(week) — ignoring")
            return nil
        }
        return Set(cached.allowedIndices)
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
        return Set(cached.allowedIndices)
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

    private static func cacheURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("species_filter.json")
    }

    private static func write(_ cached: CachedFilter) throws {
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
