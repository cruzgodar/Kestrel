import Foundation
import onnxruntime_objc

enum BirdNETError: Error {
    case modelMissing
    case labelsMissing
    case wrongSampleCount(Int)
    case labelCountMismatch(labels: Int, outputs: Int)
    case missingOutput
}

actor BirdNETClassifier {
    static let sampleCount = 144_000  // 3 s @ 48 kHz mono
    static let detectionThreshold: Float = 0.3
    /// Confidence a species must clear when it is *outside* the location/week
    /// range filter. Higher than `detectionThreshold` so an out-of-range species
    /// is only accepted on strong acoustic evidence — a "soft" filter rather than
    /// a hard exclude. This both rescues species the range model under-predicts
    /// near a boundary (a clear song still gets through) and suppresses weak,
    /// out-of-range false positives (they no longer clear the higher bar). Set
    /// equal to `detectionThreshold` to disable the soft filter; raise toward 1.0
    /// to make the range filter stricter.
    ///
    /// At 1.0 it is *nearly* a hard exclude, not an absolute one, and the
    /// difference matters to anything reasoning about it: the bar is compared with
    /// `>=`, and `1/(1+expf(-logit))` saturates to exactly `1.0` in `Float` once
    /// the logit passes ~17. So an out-of-range species the model is completely
    /// certain about still gets through, which is the soft filter behaving as
    /// described rather than a hole in it. What must *never* rely on this bar is
    /// the non-species classes below — see `nonBirdLabels`.
    static let outOfRangeThreshold: Float = 1.0

    /// Confidence a species must clear when it is in range but *rare* there —
    /// plausible at this place and season, but not expected (see
    /// `SpeciesRangeFilter.Tiers`). Between the two bars above: a rarity
    /// that really is singing gets through, but a half-heard one doesn't get
    /// the benefit of the doubt a Song Sparrow does.
    static let rareThreshold: Float = 0.6

    /// Non-species classes in the BirdNET 6K v2.4 label set (noise/anthropogenic
    /// sounds). These must *never* be reported as detections — they aren't birds.
    ///
    /// The `nonBirdIndices` guard in `classify` is what excludes them, and it is
    /// the *only* thing that does: it runs before any threshold is consulted, so
    /// it holds whatever `outOfRangeThreshold` is set to and whatever a range
    /// filter happens to allow.
    ///
    /// It used to be argued that they were suppressed anyway, sitting outside
    /// every range filter with `outOfRangeThreshold` at an unreachable 1.0. That
    /// bar is not unreachable — the sigmoid saturates to exactly 1.0 in `Float`
    /// (see `outOfRangeThreshold`) — so a loud enough engine or human voice would
    /// have cleared it. A guard that doesn't depend on a threshold at all is the
    /// only version of this that can be reasoned about.
    static let nonBirdLabels: Set<String> = [
        "Dog", "Engine", "Environmental", "Fireworks", "Gun",
        "Human non-vocal", "Human vocal", "Human whistle",
        "Noise", "Power tools", "Siren",
    ]

    private let env: ORTEnv
    private let session: ORTSession
    private let inputName: String
    private let outputName: String
    private let labels: [(scientific: String, common: String)]
    /// Label indices for `nonBirdLabels` and every other non-bird label (see
    /// `SpeciesCatalog.nonBirdIndices`), resolved once at load. Detections at
    /// these indices are dropped unconditionally in `classify`.
    private let nonBirdIndices: Set<Int>

    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "birdnet", withExtension: "onnx") else {
            throw BirdNETError.modelMissing
        }
        guard let labelsURL = Bundle.main.url(
            forResource: "BirdNET_GLOBAL_6K_V2.4_Labels",
            withExtension: "txt"
        ) else { throw BirdNETError.labelsMissing }

        let env = try ORTEnv(loggingLevel: .warning)
        self.env = env
        // Compiles into a cache we own — without it the EP leaks a temp model
        // per session — and recovers from a corrupt one. See `CoreMLModelCache`.
        self.session = try CoreMLModelCache.session(
            env: env, modelPath: modelURL.path, model: "birdnet"
        ) {
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(2)
            try options.setGraphOptimizationLevel(.all)
            return options
        }

        let inputs = try session.inputNames()
        let outputs = try session.outputNames()
        guard let inName = inputs.first, let outName = outputs.first else {
            throw BirdNETError.missingOutput
        }
        self.inputName = inName
        self.outputName = outName

        let raw = try String(contentsOf: labelsURL, encoding: .utf8)
        self.labels = raw.split(whereSeparator: { $0.isNewline }).map { line in
            let parts = line.split(separator: "_", maxSplits: 1).map(String.init)
            if parts.count == 2 { return (parts[0], parts[1]) }
            return (String(line), String(line))
        }
        // The catalog reads the same labels file in the same order, and also
        // knows the frogs, insects and mammals — see `SpeciesCatalog.nonBirdIndices`.
        self.nonBirdIndices = SpeciesCatalog.shared.nonBirdIndices.union(
            self.labels.enumerated()
                .filter { Self.nonBirdLabels.contains($0.element.scientific) }
                .map(\.offset)
        )
    }

    func classify(
        _ samples: [Float],
        allowedIndices: Set<Int>? = nil,
        rareIndices: Set<Int> = [],
        outOfRangeThreshold: Float = BirdNETClassifier.outOfRangeThreshold
    ) throws -> [Detection] {
        guard samples.count == Self.sampleCount else {
            throw BirdNETError.wrongSampleCount(samples.count)
        }

        let byteCount = samples.count * MemoryLayout<Float>.stride
        let data = NSMutableData(length: byteCount)!
        samples.withUnsafeBufferPointer { src in
            data.replaceBytes(in: NSRange(location: 0, length: byteCount), withBytes: src.baseAddress!)
        }

        let shape: [NSNumber] = [1, NSNumber(value: Self.sampleCount)]
        let input = try ORTValue(tensorData: data, elementType: .float, shape: shape)

        let outputs = try session.run(
            withInputs: [inputName: input],
            outputNames: [outputName],
            runOptions: nil
        )
        guard let outValue = outputs[outputName] else { throw BirdNETError.missingOutput }
        let outData = try outValue.tensorData()

        let count = outData.length / MemoryLayout<Float>.stride
        var logits = [Float](repeating: 0, count: count)
        logits.withUnsafeMutableBytes { dst in
            outData.getBytes(dst.baseAddress!, length: outData.length)
        }

        if logits.count != labels.count {
            throw BirdNETError.labelCountMismatch(labels: labels.count, outputs: logits.count)
        }

        let now = Date()
        var results: [Detection] = []
        results.reserveCapacity(32)
        for (index, logit) in logits.enumerated() {
            let isNonBird = nonBirdIndices.contains(index)
            // With no filter (`allowedIndices == nil`) everything counts as in
            // range and uses the normal bar.
            let inRange = allowedIndices?.contains(index) ?? true
            let confidence = Self.confidence(logit: logit)
            guard Self.accepts(
                confidence: confidence,
                isNonBird: isNonBird,
                inRange: inRange,
                isRare: rareIndices.contains(index),
                outOfRangeThreshold: outOfRangeThreshold
            ) else { continue }
            let (sci, common) = labels[index]
            #if DEBUG
            if !inRange {
                print("BirdNET: out-of-range accept \(sci) conf=\(String(format: "%.2f", confidence)) (bar \(outOfRangeThreshold))")
            }
            #endif
            results.append(Detection(
                scientificName: sci,
                commonName: common,
                confidence: confidence,
                lastSeen: now
            ))
        }
        return results
    }

    /// The model emits raw logits; this is the sigmoid that turns one into a
    /// `[0, 1]` confidence.
    ///
    /// **It saturates.** Past a logit of about 17, `expf(-logit)` underflows far
    /// enough that the quotient rounds to exactly `1.0` in `Float` — which is why
    /// `outOfRangeThreshold`'s 1.0 is a very high bar rather than an unreachable
    /// one, and why `accepts` refuses non-species classes structurally instead of
    /// leaning on that bar. Named and `nonisolated` so a test can pin the
    /// saturation rather than a comment asserting it.
    nonisolated static func confidence(logit: Float) -> Float {
        1.0 / (1.0 + expf(-logit))
    }

    /// Whether one label's score is reported as a detection.
    ///
    /// Two independent rules, and the order between them is the point:
    ///
    ///   • **Non-species classes are excluded outright**, before any threshold is
    ///     consulted. Human voice, a dog, an engine and the rest are not birds at
    ///     any confidence, under any range filter, at any setting of the bar
    ///     below. This used to be argued as a consequence of those labels sitting
    ///     outside every range filter with the bar at an unreachable 1.0 — but the
    ///     bar is reachable (see `confidence`), so that argument never held.
    ///   • **The soft range filter** then asks an out-of-range species for more
    ///     acoustic evidence than an in-range one, rather than dropping it. See
    ///     `outOfRangeThreshold`. An in-range species that is rare there sits
    ///     between the two — see `rareThreshold`.
    ///
    /// Extracted as a pure function, in the shape `LifeListStore.recordsHandover`
    /// and `RemoteSpeciesImageStore.staleOutcome` take, because the alternative is
    /// a rule that can only be exercised by running a 6,522-class model over three
    /// seconds of audio and hoping it produces the case under test.
    nonisolated static func accepts(
        confidence: Float,
        isNonBird: Bool,
        inRange: Bool,
        isRare: Bool = false,
        outOfRangeThreshold: Float = BirdNETClassifier.outOfRangeThreshold
    ) -> Bool {
        guard !isNonBird else { return false }
        guard inRange else { return confidence >= outOfRangeThreshold }
        return confidence >= (isRare ? rareThreshold : detectionThreshold)
    }
}
