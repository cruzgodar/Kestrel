import Compression
import Foundation
import os

/// Offline fallback for the location/week species filter. Reads the precomputed
/// table baked by `scripts/build_offline_species_filter.py` — the same two
/// location models `SpeciesRangeFilter` runs, sampled over a global lat/lon grid
/// for all 48 weeks — and answers "which birds are plausible here, this week,
/// and which of them are rare?" from the grid samples around the query. Used
/// when the live models can't load or run.
///
/// Entirely inert unless `offline_species_filter.bin` is present in the bundle:
/// with no file, `tiers` returns `nil` and callers fall through to their
/// existing behavior. Species indices match `SpeciesCatalog.all` /
/// `SpeciesRangeFilter` (same labels order).
///
/// **Format 3.** Each latitude band of the grid is compressed on its own, and a
/// lookup inflates only the (up to three) bands it reads, keeping a few around.
/// The table used to be one compressed stream, inflated whole at first use —
/// 63 MB of memory for the old model's lists, and the geomodel's are about
/// two and a half times longer.
///
/// `nonisolated` + `@unchecked Sendable`: immutable after init apart from the
/// band cache, which a lock guards, so it can be read off any actor like
/// `SpeciesCatalog`.
nonisolated final class OfflineSpeciesFilter: @unchecked Sendable {
    static let shared = OfflineSpeciesFilter()

    struct Grid {
        let latMin: Double
        let lonMin: Double
        let step: Double
        let latCells: Int
        let lonCells: Int
        let weeks: Int
    }

    /// Where one latitude band sits in `data`, and how big it inflates to.
    struct Band {
        let offset: Int
        let compressedLength: Int
        let rawLength: Int
    }

    /// One inflated band, with where each cell-week row starts in it.
    private struct InflatedBand {
        let bytes: [UInt8]
        /// Indexed `j * weeks + w`.
        let rowOffsets: [Int]
    }

    private let grid: Grid?
    private let bands: [Band]
    private let data: Data

    /// Recently inflated bands by latitude index, newest last. Three covers
    /// one lookup's 3×3 block; a fourth spares the re-inflation when a walk
    /// crosses into the next band.
    private let cache = OSAllocatedUnfairLock(initialState: [(Int, InflatedBand)]())
    private static let cachedBands = 4

    private init() {
        guard let url = Bundle.main.url(forResource: "offline_species_filter", withExtension: "bin"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let parsed = Self.parseHeader([UInt8](data.prefix(Self.headerLength(maxLatCells: 1024)))) else {
            grid = nil
            bands = []
            self.data = Data()
            return
        }
        grid = parsed.grid
        bands = parsed.bands
        self.data = data
    }

    /// The tiers at `(lat, lon)` for BirdNET `week` (1–48), or `nil` when no
    /// table is bundled.
    ///
    /// Unions the nearest grid sample with its 8 neighbors (a 3×3 block).
    /// Snapping to a single coarse cell drops species whose range edge falls
    /// between the query and the nearest sample; including the ring of
    /// neighbors covers up to one cell (`step°`) in every direction, so a
    /// location near a range boundary picks up both sides instead of silently
    /// missing one. A species common in any of the nine is common.
    func tiers(lat: Double, lon: Double, week: Int) -> SpeciesRangeFilter.Tiers? {
        guard let grid else { return nil }
        let ci = Int(((lat - grid.latMin) / grid.step).rounded())
        let cj = Int(((lon - grid.lonMin) / grid.step).rounded())
        let w = min(max(week - 1, 0), grid.weeks - 1)

        var allowed = Set<Int>()
        var common = Set<Int>()
        for di in -1...1 {
            let i = min(max(ci + di, 0), grid.latCells - 1)
            guard let band = inflatedBand(i) else { continue }
            for dj in -1...1 {
                let j = min(max(cj + dj, 0), grid.lonCells - 1)
                let row = j * grid.weeks + w
                guard band.rowOffsets.indices.contains(row) else { continue }
                Self.decodeRow(band.bytes, at: band.rowOffsets[row], allowed: &allowed, common: &common)
            }
        }
        guard !allowed.isEmpty else { return nil }
        return SpeciesRangeFilter.Tiers(allowed: allowed, rare: allowed.subtracting(common))
    }

    // MARK: - Bands

    private func inflatedBand(_ i: Int) -> InflatedBand? {
        if let hit = cache.withLock({ $0.first { $0.0 == i }?.1 }) { return hit }
        guard let grid, bands.indices.contains(i) else { return nil }
        let band = bands[i]
        guard band.offset >= 0, band.offset + band.compressedLength <= data.count,
              let bytes = Self.inflate(data, band: band),
              let offsets = Self.rowOffsets(bytes, rows: grid.lonCells * grid.weeks) else { return nil }
        let inflated = InflatedBand(bytes: bytes, rowOffsets: offsets)
        cache.withLock { cache in
            cache.removeAll { $0.0 == i }
            cache.append((i, inflated))
            if cache.count > Self.cachedBands { cache.removeFirst() }
        }
        return inflated
    }

    // MARK: - Decoding

    /// One row: a `UInt16` count, then that many varints of
    /// `(index delta << 1) | isRare`, indices ascending.
    private static func decodeRow(
        _ body: [UInt8], at start: Int, allowed: inout Set<Int>, common: inout Set<Int>
    ) {
        var p = start
        guard p + 2 <= body.count else { return }
        let count = Int(body[p]) | (Int(body[p + 1]) << 8)
        p += 2
        var prev = 0
        for _ in 0..<count {
            let (value, next) = readVarint(body, p)
            prev += value >> 1
            allowed.insert(prev)
            if value & 1 == 0 { common.insert(prev) }
            p = next
        }
    }

    private static func rowOffsets(_ body: [UInt8], rows: Int) -> [Int]? {
        var offsets = [Int]()
        offsets.reserveCapacity(rows)
        var q = 0
        for _ in 0..<rows {
            offsets.append(q)
            guard q + 2 <= body.count else { return nil }
            let count = Int(body[q]) | (Int(body[q + 1]) << 8)
            q += 2
            var read = 0
            while read < count {
                guard q < body.count else { return nil }
                if body[q] & 0x80 == 0 { read += 1 }
                q += 1
            }
        }
        return offsets
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

    /// The fixed header, before the band table.
    private static let fixedHeaderLength = 42

    private static func headerLength(maxLatCells: Int) -> Int {
        fixedHeaderLength + 12 * maxLatCells
    }

    /// Parses the header and band table:
    ///
    ///     magic "KOSF", version u8 = 3, range threshold f32, common threshold
    ///     f32, species count u32, lat min/max f32, lon min/max f32, step f32,
    ///     lat cells u16, lon cells u16, weeks u8,
    ///     then per latitude band: offset u32 (from the file's start),
    ///     compressed length u32, raw length u32.
    ///
    /// Little-endian throughout. Bands are raw DEFLATE.
    static func parseHeader(_ bytes: [UInt8]) -> (grid: Grid, bands: [Band])? {
        guard bytes.count > fixedHeaderLength, bytes[0..<4] == [0x4B, 0x4F, 0x53, 0x46] else { return nil }
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

        guard u8() == 3 else { return nil }
        _ = f32()                 // range threshold (informational)
        _ = f32()                 // common threshold (informational)
        _ = u32()                 // species count (unused at lookup)
        let latMin = f32()
        _ = f32()                 // lat max (unused at lookup)
        let lonMin = f32()
        _ = f32()                 // lon max (unused at lookup)
        let step = f32()
        let latCells = u16()
        let lonCells = u16()
        let weeks = u8()
        guard step > 0, latCells > 0, lonCells > 0, weeks > 0,
              bytes.count >= fixedHeaderLength + 12 * latCells else { return nil }

        let bands = (0..<latCells).map { _ in
            Band(offset: u32(), compressedLength: u32(), rawLength: u32())
        }
        let grid = Grid(
            latMin: latMin, lonMin: lonMin, step: step,
            latCells: latCells, lonCells: lonCells, weeks: weeks
        )
        return (grid, bands)
    }

    private static func inflate(_ data: Data, band: Band) -> [UInt8]? {
        guard band.compressedLength > 0, band.rawLength > 0 else { return nil }
        var dst = [UInt8](repeating: 0, count: band.rawLength)
        let written = dst.withUnsafeMutableBufferPointer { dstPtr -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                compression_decode_buffer(
                    dstPtr.baseAddress!, band.rawLength,
                    src.baseAddress!.advanced(by: band.offset).assumingMemoryBound(to: UInt8.self),
                    band.compressedLength,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == band.rawLength else { return nil }
        return dst
    }
}
