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
    static let detectionThreshold: Float = 0.25
    /// Confidence a species must clear when it is *outside* the location/week
    /// range filter. Higher than `detectionThreshold` so an out-of-range species
    /// is only accepted on strong acoustic evidence — a "soft" filter rather than
    /// a hard exclude. This both rescues species the range model under-predicts
    /// near a boundary (a clear song still gets through) and suppresses weak,
    /// out-of-range false positives (they no longer clear the higher bar). Set
    /// equal to `detectionThreshold` to disable the soft filter; raise toward 1.0
    /// to make the range filter stricter.
    static let outOfRangeThreshold: Float = 1.0

    /// Non-species classes in the BirdNET 6K v2.4 label set (noise/anthropogenic
    /// sounds). These must *never* be reported as detections — they aren't birds.
    /// They're normally suppressed because they sit outside every range filter and
    /// `outOfRangeThreshold` is 1.0 (unreachable), but that's a coincidental
    /// safeguard: lowering the threshold, or a future filter that happens to allow
    /// one of these indices, would let them through. The `nonBirdIndices` guard in
    /// `classify` excludes them unconditionally, independent of any threshold.
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
    /// Label indices for `nonBirdLabels`, resolved once at load. Detections at
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
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)

        if ORTIsCoreMLExecutionProviderAvailable() {
            do {
                try options.appendCoreMLExecutionProvider(withOptionsV2: ["MLComputeUnits": "ALL"])
            } catch {
                Log.warning("BirdNET: CoreML EP unavailable (\(error)), falling back to CPU")
            }
        }

        self.env = env
        self.session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)

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
        self.nonBirdIndices = Set(
            self.labels.enumerated()
                .filter { Self.nonBirdLabels.contains($0.element.scientific) }
                .map(\.offset)
        )
    }

    func classify(
        _ samples: [Float],
        allowedIndices: Set<Int>? = nil,
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
            // Hard guard: never report non-species classes (human voice, dog,
            // noise, etc.), regardless of confidence or any threshold setting.
            if nonBirdIndices.contains(index) { continue }
            // Soft range filter: out-of-range species aren't dropped, they just
            // have to clear a higher confidence bar than in-range ones. With no
            // filter (`allowedIndices == nil`) everything uses the normal bar.
            let inRange = allowedIndices?.contains(index) ?? true
            let threshold = inRange ? Self.detectionThreshold : outOfRangeThreshold
            // Model emits raw logits; apply sigmoid for [0,1] confidences.
            let confidence = 1.0 / (1.0 + expf(-logit))
            if confidence >= threshold {
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
        }
        return results
    }
}
