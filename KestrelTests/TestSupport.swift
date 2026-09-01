import Foundation
import Testing
@testable import Kestrel

// MARK: - Scratch storage

/// A throwaway directory, deleted when the test that made it finishes.
///
/// **Every** test that touches a `LifeListStore` or a `PhotoManifestStore` must
/// go through one of these. Tests run inside the Kestrel app's own process on
/// the simulator (that's what `TEST_HOST` means), so a store built with the
/// default initializer reads and *overwrites* the running install's real life
/// list. A test that wipes the developer's simulator data to assert something
/// about wiping data would be a poor trade.
final class ScratchDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KestrelTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // Let the life list's IO queue finish first. Its persistence is
        // deliberately asynchronous — a mutation snapshots on the main actor and
        // encodes + writes on a shared serial queue — so a test that ends without
        // flushing leaves writes queued against the directory this is about to
        // delete. Every one of them then fails with "the folder doesn't exist",
        // which is what filled the test log with `LifeListStore: save failed`
        // errors from tests that had passed.
        //
        // Tests that *read a file back* still flush explicitly, and must: this
        // barrier runs at the end of a test, not in the middle of one. What it
        // buys is that no test can leave work in flight for the next one to trip
        // over, without every test having to remember a cleanup call.
        LifeListStore.drainPendingWrites()
        try? FileManager.default.removeItem(at: url)
    }

    /// Contents of one of the store's files, or nil if it hasn't been written.
    func data(_ name: String) -> Data? {
        try? Data(contentsOf: url.appendingPathComponent(name))
    }

    /// Writes a life list to disk in exactly the shape `LifeListStore.load()`
    /// expects, so a store built on this directory finds it there.
    func writeLifeList(_ entries: [LifeListEntry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url.appendingPathComponent("life_list.json"))
    }

    /// Writes raw JSON as the life list — for decoding tests that need to omit
    /// fields a `LifeListEntry` would always encode.
    func writeRawLifeList(_ json: String) throws {
        try Data(json.utf8).write(to: url.appendingPathComponent("life_list.json"))
    }

    func writeStars(_ names: [String]) throws {
        try JSONEncoder().encode(names.sorted())
            .write(to: url.appendingPathComponent("starred_species.json"))
    }

    func writeExportedKeys(_ keys: [String]) throws {
        try JSONEncoder().encode(keys.sorted())
            .write(to: url.appendingPathComponent("exported_observations.json"))
    }

    func readLifeList() throws -> [LifeListEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            [LifeListEntry].self,
            from: Data(contentsOf: url.appendingPathComponent("life_list.json"))
        )
    }

    func readStars() throws -> Set<String> {
        try JSONDecoder().decode(
            Set<String>.self,
            from: Data(contentsOf: url.appendingPathComponent("starred_species.json"))
        )
    }

    func readExportedKeys() throws -> Set<String> {
        try JSONDecoder().decode(
            Set<String>.self,
            from: Data(contentsOf: url.appendingPathComponent("exported_observations.json"))
        )
    }
}

/// A `UserDefaults` suite nobody else uses, removed on deinit. Same reasoning as
/// `ScratchDirectory`: the date migration and the review counters are
/// once-per-install state, and a test that spent the real install's would
/// silently change what the app does next launch.
final class ScratchDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init() {
        suiteName = "KestrelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// A store on scratch storage, with the date migration already marked done so it
/// doesn't rewrite the dates a test just handed it. Tests *of* the migration set
/// this up themselves instead.
@MainActor
func makeStore(_ scratch: ScratchDirectory, _ defaults: ScratchDefaults) -> LifeListStore {
    defaults.defaults.set(true, forKey: "lifeList.datesNormalizedToUTC")
    return LifeListStore(directory: scratch.url, defaults: defaults.defaults)
}

// MARK: - Dates

/// Midnight UTC on a given day — the canonical form every stored sighting takes.
/// Built directly rather than through `ObservationDate.canonical` so the tests of
/// that function aren't checking it against itself.
func utcDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: components)!
}

/// Whether an instant is exactly midnight UTC — the literal form of the stored
/// invariant.
///
/// Spelled out longhand rather than deferring to `ObservationDate.isCanonical`,
/// which computes the same predicate: the tests *of* that function need something
/// independent to check it against.
///
/// Note which `ObservationDate` call it corresponds to. It is
/// `canonical(date, in: .utc) == date`, **not** `canonical(date) == date` —
/// the latter reads the day in the *device's* zone, so it answers false for a
/// perfectly canonical date anywhere west of UTC. That distinction is the whole
/// subject of `isCanonical`, and a helper that got it wrong would pass in London
/// and fail in Los Angeles.
func isMidnightUTC(_ date: Date) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
    return parts.hour == 0 && parts.minute == 0 && parts.second == 0 && parts.nanosecond == 0
}

/// An instant at a specific wall-clock time in a specific zone, for testing what
/// happens to a sighting written by a phone that isn't on UTC.
func instant(
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int, _ minute: Int = 0,
    zone: TimeZone
) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: components)!
}

/// Time zones chosen to bracket the failure modes: well behind UTC, well ahead,
/// past the date line in both directions, and one on a non-hour offset.
enum TestZones {
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let newYork = TimeZone(identifier: "America/New_York")!       // UTC-5/-4
    static let losAngeles = TimeZone(identifier: "America/Los_Angeles")! // UTC-8/-7
    static let auckland = TimeZone(identifier: "Pacific/Auckland")!      // UTC+12/+13
    static let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!       // UTC+5:45
    static let chatham = TimeZone(identifier: "Pacific/Chatham")!        // UTC+12:45/+13:45
    static let apia = TimeZone(identifier: "Pacific/Apia")!              // UTC+13
    static let midway = TimeZone(identifier: "Pacific/Midway")!          // UTC-11

    static let all: [TimeZone] = [utc, newYork, losAngeles, auckland, kathmandu, chatham, apia, midway]
}

// MARK: - Model builders

extension LifeListEntry.Observation {
    /// A sighting, terse enough to write a dozen of them in a test without the
    /// noise drowning what's actually under test.
    static func at(
        _ date: Date,
        _ place: String? = nil,
        lat: Double? = nil,
        lon: Double? = nil,
        imported: Bool = false
    ) -> Self {
        .init(date: date, location: place, latitude: lat, longitude: lon, isImported: imported)
    }
}

extension LifeListEntry {
    static func make(
        _ scientificName: String,
        _ commonName: String,
        _ observations: [Observation],
        starred: Bool = false
    ) -> LifeListEntry {
        .make(
            scientificName: scientificName,
            commonName: commonName,
            isStarred: starred,
            observations: observations,
            dedupe: false
        )
    }
}

// MARK: - CSV builders

/// Builds an eBird "My eBird Data" export with the columns the parser reads.
/// Header names and order copied from a real export.
func eBirdCSV(_ rows: [(sci: String, common: String, date: String, location: String?, lat: Double?, lon: Double?)]) -> Data {
    var out = "Submission ID,Common Name,Scientific Name,Taxonomic Order,Count,State/Province,County,Location ID,Location,Latitude,Longitude,Date,Time,Protocol,Duration (Min),All Obs Reported,Distance Traveled (km),Area Covered (ha),Number of Observers,Breeding Code,Observation Details,Checklist Comments,ML Catalog Numbers\n"
    for (i, r) in rows.enumerated() {
        let fields: [String] = [
            "S\(1000 + i)",
            r.common,
            r.sci,
            "\(i)",
            "1",
            "New York",
            "Tompkins",
            "L\(i)",
            r.location ?? "",
            r.lat.map { String($0) } ?? "",
            r.lon.map { String($0) } ?? "",
            r.date,
            "08:00 AM",
            "eBird - Traveling Count",
            "60", "1", "1.0", "", "1", "", "", "", "",
        ]
        out += fields.map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: ",") + "\n"
    }
    return Data(out.utf8)
}

/// Splits a rendered eBird export back into rows of fields. The format forbids
/// quoting, so a plain comma split is exactly right — and if a field ever *did*
/// leak a comma, this would mis-split and the assertion would catch it.
func parseExportedCSV(_ payload: EBirdCSVExporter.Payload) -> [[String]] {
    String(decoding: payload.csv, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.components(separatedBy: ",") }
}
