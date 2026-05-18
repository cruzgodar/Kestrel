import Accelerate
import CoreGraphics
import Foundation

/// Builds a scrolling magnitude spectrogram from incoming PCM samples and
/// exposes it as a `CGImage` snapshot. Internally locked so the audio tap can
/// `ingest(_:)` while the UI calls `snapshot()`.
///
/// Storage is a ring buffer of columns to keep the audio thread cheap (one
/// column written per FFT, no shifting). The snapshot copies the ring into a
/// linear buffer in display order — that's the only place we touch the full
/// pixel buffer.
final class SpectrogramRenderer: @unchecked Sendable {
    // MARK: Tuning

    static let fftSize: Int = 1024
    static let log2n: vDSP_Length = 10
    static let hop: Int = 256                         // 187 cols/sec
    static let displayBins: Int = 320
    static let columnCount: Int = 480                 // ~2.6 s of history
    static let sampleRate: Float = 48_000
    static let freqMin: Float = 100                   // Hz — bottom of display
    static let freqMax: Float = 14_000                // Hz — top of display

    /// How many columns the most-recent BirdNET window covers (3 s / hop), clipped.
    static let highlightSpan: Int = min((48_000 * 3) / hop, columnCount)

    // MARK: Storage (ring-buffer order)

    private let lock = NSLock()
    private var pending: [Float] = []
    /// RGBA8 columns laid out side-by-side in *ring* order. `writeColumn` is the
    /// position of the next column to write; the column at `writeColumn` is the
    /// oldest in display order.
    private var ringPixels: [UInt8]
    /// Reused scratch for snapshot, in display order (left = oldest, right = newest).
    private var linearPixels: [UInt8]
    private let rowBytes: Int
    private var writeColumn: Int = 0

    // FFT scratch
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let hann: [Float]
    /// Precomputed FFT bin index for each y in [0, displayBins). y=0 = top = freqMax.
    private let binForY: [Int]
    private var windowed: [Float]
    private var realIn: [Float]
    private var imagIn: [Float]
    private var realOut: [Float]
    private var imagOut: [Float]
    private var magnitude: [Float]

    init() {
        guard let fft = vDSP.FFT(log2n: Self.log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            fatalError("Failed to create FFT setup")
        }
        self.fft = fft
        self.hann = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: Self.fftSize,
            isHalfWindow: false
        )
        self.windowed = [Float](repeating: 0, count: Self.fftSize)
        self.realIn = [Float](repeating: 0, count: Self.fftSize / 2)
        self.imagIn = [Float](repeating: 0, count: Self.fftSize / 2)
        self.realOut = [Float](repeating: 0, count: Self.fftSize / 2)
        self.imagOut = [Float](repeating: 0, count: Self.fftSize / 2)
        self.magnitude = [Float](repeating: 0, count: Self.fftSize / 2)

        let binWidth = Self.sampleRate / Float(Self.fftSize)
        let maxBin = Self.fftSize / 2 - 1
        let logMax = logf(Self.freqMax)
        let logMin = logf(Self.freqMin)
        var binMap = [Int](repeating: 0, count: Self.displayBins)
        for y in 0..<Self.displayBins {
            let t = Float(y) / Float(max(Self.displayBins - 1, 1))
            let logFreq = logMax + (logMin - logMax) * t
            let freq = expf(logFreq)
            let bin = Int(freq / binWidth + 0.5)
            binMap[y] = max(0, min(maxBin, bin))
        }
        self.binForY = binMap

        let pixelCount = Self.columnCount * Self.displayBins * 4
        self.ringPixels = [UInt8](repeating: 0, count: pixelCount)
        self.linearPixels = [UInt8](repeating: 0, count: pixelCount)
        self.rowBytes = Self.columnCount * 4
        for i in stride(from: 3, to: ringPixels.count, by: 4) { ringPixels[i] = 255 }
        for i in stride(from: 3, to: linearPixels.count, by: 4) { linearPixels[i] = 255 }
    }

    // MARK: API

    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll(keepingCapacity: true)
        for i in 0..<ringPixels.count {
            ringPixels[i] = (i % 4 == 3) ? 255 : 0
        }
        writeColumn = 0
    }

    /// Safe to call from any thread.
    func ingest(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        pending.append(contentsOf: samples)
        while pending.count >= Self.fftSize {
            // Use the first fftSize samples as the FFT frame; advance by hop.
            renderColumnLocked()
            pending.removeFirst(Self.hop)
        }
    }

    /// Retroactively tints the most-recent `highlightSpan` columns.
    func markDetection() {
        lock.lock(); defer { lock.unlock() }
        let n = min(Self.highlightSpan, Self.columnCount)
        for offset in 1...n {
            let storageCol = ((writeColumn - offset) % Self.columnCount + Self.columnCount) % Self.columnCount
            tintRingColumnLocked(storageCol)
        }
    }

    /// Returns a CGImage representing the current spectrogram in display order
    /// (oldest on left, newest on right).
    func snapshot() -> CGImage? {
        lock.lock()
        copyRingToLinearLocked()
        let snapshotCopy = linearPixels   // copy-on-write; ARC'd into the CFData below
        let writeColSnapshot = writeColumn
        _ = writeColSnapshot
        lock.unlock()

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(snapshotCopy) as CFData) else { return nil }
        return CGImage(
            width: Self.columnCount,
            height: Self.displayBins,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: Ring → linear

    /// Rearranges the ring buffer into `linearPixels` such that column 0 = oldest,
    /// columnCount-1 = newest. Two memcpys per row.
    private func copyRingToLinearLocked() {
        let writeCol = writeColumn
        let rightStartBytes = writeCol * 4
        let rightSizeBytes = (Self.columnCount - writeCol) * 4
        let leftSizeBytes = writeCol * 4
        ringPixels.withUnsafeBufferPointer { srcBP in
            linearPixels.withUnsafeMutableBufferPointer { dstBP in
                guard let src = srcBP.baseAddress, let dst = dstBP.baseAddress else { return }
                for y in 0..<Self.displayBins {
                    let rowOffset = y * rowBytes
                    // Right half of source (from writeCol to end) goes to left of dest.
                    memcpy(dst + rowOffset, src + rowOffset + rightStartBytes, rightSizeBytes)
                    // Left half of source (0..writeCol) goes to right of dest.
                    memcpy(dst + rowOffset + rightSizeBytes, src + rowOffset, leftSizeBytes)
                }
            }
        }
    }

    // MARK: Column generation

    private func renderColumnLocked() {
        // 1) Window the first fftSize samples of `pending` into `windowed`.
        pending.withUnsafeBufferPointer { pBP in
            guard let p = pBP.baseAddress else { return }
            let buf = UnsafeBufferPointer(start: p, count: Self.fftSize)
            vDSP.multiply(Array(buf), hann, result: &windowed)
        }

        // 2) Pack windowed real signal into split complex.
        windowed.withUnsafeBytes { rawBP in
            let cplx = rawBP.bindMemory(to: DSPComplex.self)
            realIn.withUnsafeMutableBufferPointer { rBP in
                imagIn.withUnsafeMutableBufferPointer { iBP in
                    var split = DSPSplitComplex(realp: rBP.baseAddress!, imagp: iBP.baseAddress!)
                    vDSP_ctoz(cplx.baseAddress!, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                }
            }
        }

        // 3) FFT
        realIn.withUnsafeMutableBufferPointer { ri in
            imagIn.withUnsafeMutableBufferPointer { ii in
                realOut.withUnsafeMutableBufferPointer { ro in
                    imagOut.withUnsafeMutableBufferPointer { io in
                        let inSplit = DSPSplitComplex(realp: ri.baseAddress!, imagp: ii.baseAddress!)
                        var outSplit = DSPSplitComplex(realp: ro.baseAddress!, imagp: io.baseAddress!)
                        fft.forward(input: inSplit, output: &outSplit)
                    }
                }
            }
        }

        // 4) Magnitude
        realOut.withUnsafeMutableBufferPointer { ro in
            imagOut.withUnsafeMutableBufferPointer { io in
                magnitude.withUnsafeMutableBufferPointer { m in
                    var split = DSPSplitComplex(realp: ro.baseAddress!, imagp: io.baseAddress!)
                    vDSP_zvabs(&split, 1, m.baseAddress!, 1, vDSP_Length(Self.fftSize / 2))
                }
            }
        }

        // 5) Write into the ring at writeColumn.
        // Calibration: raw vDSP_zvabs output of a 1024-point FFT on float audio
        // typically lands in:  silence ≈ -10…+0 dB,  birdsong ≈ +15…+30 dB,
        // very loud peaks ≈ +35 dB+. Picking a wide range with a lifted floor
        // means quiet rooms vanish into background while songs sit in mid-gray.
        let floorDB: Float = -5
        let ceilDB: Float  = 30
        let range = ceilDB - floorDB
        let xOffset = writeColumn * 4
        for y in 0..<Self.displayBins {
            let bin = binForY[y]
            let m = magnitude[bin]
            let db = 20.0 * log10f(max(m, 1e-7))

            var norm = (db - floorDB) / range
            if norm < 0 { norm = 0 }
            if norm > 1 { norm = 1 }
            // Gentle gamma (1.5) keeps quiet noise dark without crushing songs.
            norm = norm * sqrtf(norm)

            let gray = UInt8(norm * 255)
            let idx = y * rowBytes + xOffset
            ringPixels[idx + 0] = gray
            ringPixels[idx + 1] = gray
            ringPixels[idx + 2] = gray
            ringPixels[idx + 3] = 255
        }

        writeColumn = (writeColumn + 1) % Self.columnCount
    }

    private func tintRingColumnLocked(_ x: Int) {
        let xOffset = x * 4
        for y in 0..<Self.displayBins {
            let idx = y * rowBytes + xOffset
            let g = ringPixels[idx + 0]
            ringPixels[idx + 0] = g
            ringPixels[idx + 1] = UInt8(Float(g) * 0.55)
            ringPixels[idx + 2] = 0
        }
    }
}
