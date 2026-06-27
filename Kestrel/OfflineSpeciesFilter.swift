import Compression
import Foundation

/// Offline fallback for the location/week species filter. Reads the precomputed
/// table baked by `scripts/build_offline_species_filter.py` — the bundled
/// BirdNET location model sampled over a global lat/lon grid for all 48 weeks —
/// and answers "which species are plausible here, this week?" by snapping to the
/// nearest grid sample. Used when the live geo model can't run (no fix at
/// listen-start, inference failure, etc.).
///
/// Entirely inert unless `offline_species_filter.bin` is present in the bundle:
/// with no file, `isAvailable` is false and `allowedIndices` returns `nil`, so
/// callers fall through to their existing behavior. Species indices match
/// `SpeciesCatalog.all` / `SpeciesRangeFilter` (same labels order).
///
/// `nonisolated` + `@unchecked Sendable`: built once, immutable after init, so
/// it can be read off any actor like `SpeciesCatalog`.
final class OfflineSpeciesFilter: @unchecked Sendable {
    nonisolated static let shared = OfflineSpeciesFilter()

    private struct Grid {
        let speciesCount: Int
        let latMin: Double
        let lonMin: Double
        let step: Double
        let latCells: Int
        let lonCells: Int
        let weeks: Int
    }

    private let grid: Grid?
    /// Inflated body (count + delta-varint indices per cell/week row).
    private let body: [UInt8]
    /// Start index in `body` for each row, indexed `(i*lonCells + j)*weeks + w`.
    private let rowOffsets: [Int]

    var isAvailable: Bool { grid != nil }

    private init() {
        guard let url = Bundle.main.url(forResource: "offline_species_filter", withExtension: "bin"),
              let data = try? Data(contentsOf: url),
              let parsed = Self.parse(data) else {
            grid = nil
            body = []
            rowOffsets = []
            return
        }
        grid = parsed.grid
        body = parsed.body
        rowOffsets = parsed.rowOffsets
    }

    /// Allowed species indices at `(lat, lon)` for BirdNET `week` (1–48), or
    /// `nil` when no table is bundled.
    ///
    /// Unions the nearest grid sample with its 8 neighbors (a 3×3 block). Snapping
    /// to a single coarse cell drops species whose range edge falls between the
    /// query and the nearest sample; including the ring of neighbors covers up to
    /// one cell (`step°`) in every direction, so a location near a range boundary
    /// picks up both sides instead of silently missing one.
    func allowedIndices(lat: Double, lon: Double, week: Int) -> Set<Int>? {
        guard let grid else { return nil }
        let ci = Int(((lat - grid.latMin) / grid.step).rounded())
        let cj = Int(((lon - grid.lonMin) / grid.step).rounded())
        let w = min(max(week - 1, 0), grid.weeks - 1)

        var result = Set<Int>()
        for di in -1...1 {
            for dj in -1...1 {
                let i = min(max(ci + di, 0), grid.latCells - 1)
                let j = min(max(cj + dj, 0), grid.lonCells - 1)
                let rowIndex = (i * grid.lonCells + j) * grid.weeks + w
                guard rowOffsets.indices.contains(rowIndex) else { continue }
                result.formUnion(decodeRow(at: rowOffsets[rowIndex]))
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Decoding

    private func decodeRow(at start: Int) -> Set<Int> {
        var p = start
        guard p + 2 <= body.count else { return [] }
        let count = Int(body[p]) | (Int(body[p + 1]) << 8)
        p += 2
        var result = Set<Int>()
        result.reserveCapacity(count)
        var prev = 0
        for _ in 0..<count {
            let (delta, next) = Self.readVarint(body, p)
            prev += delta
            result.insert(prev)
            p = next
        }
        return result
    }

    private static func readVarint(_ buf: [UInt8], _ start: Int) -> (value: Int, next: Int) {
        var value = 0
        var shift = 0
        var p = start
        while p < buf.count {
            let byte = buf[p]
            value |= Int(byte & 0x7F) << shift
            p += 1
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return (value, p)
    }

    // MARK: - Parsing

    private static func parse(_ data: Data) -> (grid: Grid, body: [UInt8], rowOffsets: [Int])? {
        let headerLen = 42
        guard data.count > headerLen,
              data[data.startIndex ..< data.startIndex + 4] == Data("KOSF".utf8) else {
            return nil
        }
        let bytes = [UInt8](data)
        var p = 4
        func u8() -> Int { defer { p += 1 }; return Int(bytes[p]) }
        func u16() -> Int { defer { p += 2 }; return Int(bytes[p]) | (Int(bytes[p + 1]) << 8) }
        func u32() -> Int {
            defer { p += 4 }
            return Int(bytes[p]) | (Int(bytes[p + 1]) << 8) | (Int(bytes[p + 2]) << 16) | (Int(bytes[p + 3]) << 24)
        }
        func f32() -> Double {
            defer { p += 4 }
            let bits = UInt32(bytes[p]) | (UInt32(bytes[p + 1]) << 8)
                | (UInt32(bytes[p + 2]) << 16) | (UInt32(bytes[p + 3]) << 24)
            return Double(Float(bitPattern: bits))
        }

        let version = u8()
        guard version == 2 else { return nil }
        _ = f32()                 // threshold (informational)
        let speciesCount = u32()
        let latMin = f32()
        _ = f32()                 // latMax (unused at lookup)
        let lonMin = f32()
        _ = f32()                 // lonMax (unused at lookup)
        let step = f32()
        let latCells = u16()
        let lonCells = u16()
        let weeks = u8()
        let bodyRawLen = u32()

        guard step > 0, latCells > 0, lonCells > 0, weeks > 0, bodyRawLen > 0 else { return nil }

        // Inflate the raw-DEFLATE body to its known length.
        let compressed = Array(bytes[p...])
        guard let inflated = inflate(compressed, expected: bodyRawLen) else { return nil }

        // Pre-scan row offsets so individual lookups are O(row), not O(file).
        let totalRows = latCells * lonCells * weeks
        var offsets = [Int]()
        offsets.reserveCapacity(totalRows)
        var q = 0
        for _ in 0..<totalRows {
            offsets.append(q)
            guard q + 2 <= inflated.count else { return nil }
            let count = Int(inflated[q]) | (Int(inflated[q + 1]) << 8)
            q += 2
            var read = 0
            while read < count {
                guard q < inflated.count else { return nil }
                if inflated[q] & 0x80 == 0 { read += 1 }
                q += 1
            }
        }

        let grid = Grid(
            speciesCount: speciesCount,
            latMin: latMin,
            lonMin: lonMin,
            step: step,
            latCells: latCells,
            lonCells: lonCells,
            weeks: weeks
        )
        return (grid, inflated, offsets)
    }

    private static func inflate(_ compressed: [UInt8], expected: Int) -> [UInt8]? {
        guard !compressed.isEmpty else { return nil }
        var dst = [UInt8](repeating: 0, count: expected)
        let written = dst.withUnsafeMutableBufferPointer { dstPtr -> Int in
            compressed.withUnsafeBufferPointer { srcPtr in
                compression_decode_buffer(
                    dstPtr.baseAddress!, expected,
                    srcPtr.baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expected else { return nil }
        return dst
    }
}
