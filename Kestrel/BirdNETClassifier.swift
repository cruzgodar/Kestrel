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

    private let env: ORTEnv
    private let session: ORTSession
    private let inputName: String
    private let outputName: String
    private let labels: [(scientific: String, common: String)]

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
                print("BirdNET: CoreML EP enabled")
            } catch {
                print("BirdNET: CoreML EP unavailable (\(error)), falling back to CPU")
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
        print("BirdNET: loaded — input=\(inName), output=\(outName), labels=\(labels.count)")
    }

    func classify(_ samples: [Float], allowedIndices: Set<Int>? = nil) throws -> [Detection] {
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
            if let allowedIndices, !allowedIndices.contains(index) { continue }
            // Model emits raw logits; apply sigmoid for [0,1] confidences.
            let confidence = 1.0 / (1.0 + expf(-logit))
            if confidence >= Self.detectionThreshold {
                let (sci, common) = labels[index]
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
