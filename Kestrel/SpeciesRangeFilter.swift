import Foundation
import onnxruntime_objc

private nonisolated struct CachedFilter: Codable {
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
            try? options.appendCoreMLExecutionProvider(withOptionsV2: ["MLComputeUnits": "ALL"])
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
        print("SpeciesRangeFilter: \(allowed.count) species allowed at (\(lat), \(lon)) week \(week)")
        return allowed
    }

    /// Loads the most recently cached filter, if any. Does not run the model.
    func loadCached() -> Set<Int>? {
        guard let url = try? Self.cacheURL(), FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cached = try decoder.decode(CachedFilter.self, from: data)
            return Set(cached.allowedIndices)
        } catch {
            print("SpeciesRangeFilter: failed to load cache — \(error)")
            return nil
        }
    }

    /// Reads the cached allowed-index set straight off disk without
    /// constructing an `ORTSession` — cheap enough to call from the main
    /// actor (e.g. the life list's "in this area" grouping). Returns `nil`
    /// when no location filter has been computed yet.
    nonisolated static func cachedAllowedIndices() -> Set<Int>? {
        guard let url = try? cacheURL(),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode(CachedFilter.self, from: data) else { return nil }
        return Set(cached.allowedIndices)
    }

    // MARK: Persistence

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
