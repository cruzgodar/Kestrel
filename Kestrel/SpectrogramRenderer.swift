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
    static let displayBins: Int = 240                 // matches 80pt @ 3× retina exactly
    static let columnCount: Int = 720                 // ~3.85 s of history
    static let columnsPerSecond: Double = Double(sampleRate) / Double(hop)
    static let sampleRate: Float = 48_000
    static let freqMin: Float = 100                   // full audible range now that HPF is gone
    static let freqMax: Float = 16_000

    /// How many columns the most-recent BirdNET window covers (3 s / hop), clipped.
    static let highlightSpan: Int = min((48_000 * 3) / hop, columnCount)

    // MARK: Storage (ring-buffer order)

    private let lock = NSLock()
    private var pending: [Float] = []
    private var pumpAnchorTime: CFTimeInterval = 0
    private var pumpAnchorColumn: Int = 0
    private var totalColumnsGenerated: Int = 0
    /// RGBA8 columns laid out side-by-side in *ring* order. `writeColumn` is the
    /// position of the next column to write; the column at `writeColumn` is the
    /// oldest in display order.
    private var ringPixels: [UInt8]
    private let rowBytes: Int
    private var writeColumn: Int = 0
    /// Per-column tint code set by `markDetection(needsAdd:)`. Applied at
    /// snapshot time *after* any color inversion so the tint looks identical
    /// in light and dark mode (instead of getting flipped by the XOR pass).
    ///   0 = no tint
    ///   1 = "lifer" (species already in life list)   → goldenrod ramp
    ///   2 = "needs add" (not yet in life list)       → purple ramp
    private var columnTintKind: [UInt8]
    /// Bumped whenever the tint state changes, so the snapshot cache knows to
    /// rebuild even when `writeColumn` hasn't changed.
    private var tintGeneration: UInt64 = 0

    /// Double-buffered output: snapshot alternates between these two so we never
    /// allocate per frame and the previously-displayed CGImage's backing memory
    /// stays valid until the buffer is reused on the next-next snapshot.
    private let snapshotByteCount: Int
    private let snapshotBufferA: UnsafeMutableRawPointer
    private let snapshotBufferB: UnsafeMutableRawPointer
    private var useBufferA: Bool = true

    /// Cache so we can skip ~700 KB of memcpy and a CGImage build when no new
    /// columns have been generated since the last snapshot. Cleared on reset
    /// and whenever the inversion flag or tint state changes.
    private var cachedImageWriteCol: Int = -1
    private var cachedImageInverted: Bool = false
    private var cachedImageTintGen: UInt64 = 0
    private var cachedImage: CGImage?

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
        self.rowBytes = Self.columnCount * 4
        for i in stride(from: 3, to: ringPixels.count, by: 4) { ringPixels[i] = 255 }
        self.columnTintKind = [UInt8](repeating: 0, count: Self.columnCount)

        self.snapshotByteCount = pixelCount
        self.snapshotBufferA = UnsafeMutableRawPointer.allocate(byteCount: pixelCount, alignment: 16)
        self.snapshotBufferB = UnsafeMutableRawPointer.allocate(byteCount: pixelCount, alignment: 16)
    }

    deinit {
        snapshotBufferA.deallocate()
        snapshotBufferB.deallocate()
    }

    // MARK: API

    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll(keepingCapacity: true)
        // Clear ~700 KB of pixels with a 4-byte RGBA pattern (0,0,0,255).
        // On little-endian the in-memory layout is R,G,B,A → packed as
        // UInt32 0xFF000000. memset_pattern4 is vectorized and ~100× faster
        // than the Swift loop, especially in debug builds.
        var pattern: UInt32 = 0xFF00_0000
        ringPixels.withUnsafeMutableBufferPointer { bp in
            if let base = bp.baseAddress {
                memset_pattern4(base, &pattern, bp.count)
            }
        }
        writeColumn = 0
        pumpAnchorTime = 0
        pumpAnchorColumn = 0
        totalColumnsGenerated = 0
        for i in 0..<columnTintKind.count { columnTintKind[i] = 0 }
        tintGeneration &+= 1
        cachedImage = nil
        cachedImageWriteCol = -1
    }

    /// Audio thread: just buffers samples. FFT/column generation happens in
    /// `pumpColumns(at:)` on the display thread for uniform pacing.
    func ingest(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        pending.append(contentsOf: samples)
        // Bound runaway growth (~1 s cap) in pathological cases.
        let maxPending = Int(Self.sampleRate)
        if pending.count > maxPending {
            pending.removeFirst(pending.count - maxPending)
        }
    }

    /// Display thread: generates exactly the number of columns that should exist
    /// at `displayTime`, paced to wall-clock time. Smooths bursty audio delivery
    /// into uniform per-frame motion.
    func pumpColumns(at displayTime: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        // Anchor on the first pump that has audio.
        if pumpAnchorTime == 0 {
            guard pending.count >= Self.fftSize else { return }
            pumpAnchorTime = displayTime
            pumpAnchorColumn = totalColumnsGenerated
        }

        let elapsed = displayTime - pumpAnchorTime
        let targetTotal = pumpAnchorColumn + Int(elapsed * Self.columnsPerSecond)
        let needed = targetTotal - totalColumnsGenerated
        guard needed > 0 else { return }

        var generated = 0
        while pending.count >= Self.fftSize && generated < needed {
            renderColumnLocked()
            pending.removeFirst(Self.hop)
            totalColumnsGenerated += 1
            generated += 1
        }

        // If audio has fallen wildly behind (e.g. system hiccup) and our anchor
        // is drifting, rebase so we don't try to burst-render hundreds of cols.
        if needed - generated > 30 {
            pumpAnchorTime = displayTime
            pumpAnchorColumn = totalColumnsGenerated
        }
    }

    /// Retroactively tints the most-recent `highlightSpan` columns. The tint
    /// kind is stored per column — the actual color is applied at snapshot.
    /// `needsAdd: true` signals the detected species is not yet in the life
    /// list, painting that band purple instead of goldenrod.
    func markDetection(needsAdd: Bool) {
        lock.lock(); defer { lock.unlock() }
        let kind: UInt8 = needsAdd ? 2 : 1
        let n = min(Self.highlightSpan, Self.columnCount)
        for offset in 1...n {
            let storageCol = ((writeColumn - offset) % Self.columnCount + Self.columnCount) % Self.columnCount
            columnTintKind[storageCol] = kind
        }
        tintGeneration &+= 1
    }

    /// Returns a CGImage representing the current spectrogram in display order
    /// (oldest on left, newest on right). When `inverted` is true, RGB channels
    /// are flipped (alpha kept) for light-mode display.
    ///
    /// Caches the resulting CGImage and returns it unchanged when no new
    /// columns have been generated since the last call — important because
    /// CADisplayLink calls this on main at 120 Hz, and rebuilding ~700 KB +
    /// a CGImage every frame competes with SwiftUI's render work during
    /// transitions and animations.
    ///
    /// Uses a ping-pong pair of pre-allocated buffers when rebuilding, so the
    /// snapshot is allocation-free.
    func snapshot(inverted: Bool = false) -> CGImage? {
        lock.lock()
        let writeCol = writeColumn
        let tintGen = tintGeneration
        if writeCol == cachedImageWriteCol
            && inverted == cachedImageInverted
            && tintGen == cachedImageTintGen,
           let cached = cachedImage {
            lock.unlock()
            return cached
        }

        let buffer = useBufferA ? snapshotBufferA : snapshotBufferB
        useBufferA.toggle()
        let byteCount = snapshotByteCount

        let rightStartBytes = writeCol * 4
        let rightSizeBytes = (Self.columnCount - writeCol) * 4
        let leftSizeBytes = writeCol * 4
        // Snapshot which columns are currently tinted, in display order
        // (left = oldest). Captured under the lock so it stays consistent with
        // the pixel copy below.
        var displayTintKind = [UInt8](repeating: 0, count: Self.columnCount)
        for x in 0..<Self.columnCount {
            let ringCol = (writeCol + x) % Self.columnCount
            displayTintKind[x] = columnTintKind[ringCol]
        }
        ringPixels.withUnsafeBufferPointer { srcBP in
            guard let src = srcBP.baseAddress else { return }
            let dst = buffer.assumingMemoryBound(to: UInt8.self)
            for y in 0..<Self.displayBins {
                let rowOffset = y * rowBytes
                memcpy(dst + rowOffset, src + rowOffset + rightStartBytes, rightSizeBytes)
                memcpy(dst + rowOffset + rightSizeBytes, src + rowOffset, leftSizeBytes)
            }
        }
        lock.unlock()

        if inverted {
            buffer.withMemoryRebound(to: UInt32.self, capacity: byteCount / 4) { wp in
                for i in 0..<(byteCount / 4) {
                    wp[i] ^= 0x00FF_FFFF
                }
            }
        }

        // Replace pixels in detection columns with a black/white → loudColor
        // gradient. Silence (no audio) blends into the background so only the
        // loud frequencies are highlighted. Two distinct endpoint colors:
        //   1 = lifer (already in life list) → goldenrod (218, 165, 32)
        //   2 = needs-add (not yet in list)  → purple    (122,  89, 255)
        // The endpoint maps the same way regardless of mode; light-mode
        // inversion has already been applied to the underlying gray, so we
        // un-invert here to recover the original loudness before painting.
        let bp = buffer.assumingMemoryBound(to: UInt8.self)
        for x in 0..<Self.columnCount {
            let kind = displayTintKind[x]
            guard kind != 0 else { continue }
            let loudR: UInt16 = (kind == 1) ? 218 : 122
            let loudG: UInt16 = (kind == 1) ? 165 :  89
            let loudB: UInt16 = (kind == 1) ?  32 : 255
            let xOffset = x * 4
            for y in 0..<Self.displayBins {
                let idx = y * rowBytes + xOffset
                let pixelR = UInt16(bp[idx + 0])
                let loudness: UInt16 = inverted ? (255 - pixelR) : pixelR
                if inverted {
                    bp[idx + 0] = UInt8(255 - ((255 - loudR) * loudness) / 255)
                    bp[idx + 1] = UInt8(255 - ((255 - loudG) * loudness) / 255)
                    bp[idx + 2] = UInt8(255 - ((255 - loudB) * loudness) / 255)
                } else {
                    bp[idx + 0] = UInt8((loudR * loudness) / 255)
                    bp[idx + 1] = UInt8((loudG * loudness) / 255)
                    bp[idx + 2] = UInt8((loudB * loudness) / 255)
                }
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let release: CGDataProviderReleaseDataCallback = { _, _, _ in }
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: buffer,
            size: byteCount,
            releaseData: release
        ) else {
            return nil
        }
        let image = CGImage(
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
        cachedImage = image
        cachedImageWriteCol = writeCol
        cachedImageInverted = inverted
        cachedImageTintGen = tintGen
        return image
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
        let floorDB: Float = -35
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

        // Any tint on the slot we just overwrote no longer applies — that
        // detection scrolled off the end of the ring.
        if columnTintKind[writeColumn] != 0 {
            columnTintKind[writeColumn] = 0
            tintGeneration &+= 1
        }
        writeColumn = (writeColumn + 1) % Self.columnCount
    }
}
