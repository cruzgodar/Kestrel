import Foundation

struct LifeListEntry: Codable, Identifiable, Hashable {
    let scientificName: String
    var commonName: String
    var firstSeen: Date
    var firstLocation: String?
    /// Coordinates of where the species was first seen. Populated from the
    /// CSV's `Latitude` / `Longitude` columns on import, or from the current
    /// device location when added manually via sound ID / search. Hidden from
    /// the Life List view; consumed by the Map tab.
    var firstLatitude: Double?
    var firstLongitude: Double?
    /// User-toggled "alert me" flag. Starred species fire notifications when
    /// heard, get blue row + spectrogram highlighting in the Identify tab,
    /// and skip the full-width image treatment reserved for unseen species.
    var isStarred: Bool = false

    /// Every sighting of this species *other than* the earliest one (which is
    /// the one surfaced via `firstSeen` / `first*` and shown in the UI). On an
    /// eBird import each CSV row becomes one observation; the earliest is
    /// promoted to the displayed fields and the rest are kept here. Drives the
    /// optional "Show repeat observations on map" mode; otherwise unused by the
    /// Life List UI, which only ever displays the earliest sighting.
    var otherObservations: [Observation] = []

    var id: String { scientificName }

    /// A single recorded sighting — date plus where it happened. Mirrors the
    /// per-row fields of an eBird CSV export.
    struct Observation: Codable, Hashable {
        var date: Date
        var location: String?
        var latitude: Double?
        var longitude: Double?
    }

    /// Every sighting of this species, earliest included: the displayed
    /// first-seen fields reconstituted as an `Observation`, followed by the
    /// stored extras. Used when re-merging during canonicalization and when
    /// plotting all observations on the map.
    var allObservations: [Observation] {
        [Observation(
            date: firstSeen,
            location: firstLocation,
            latitude: firstLatitude,
            longitude: firstLongitude
        )] + otherObservations
    }

    /// Builds an entry from an unordered set of observations: the earliest one
    /// becomes the displayed `first*` fields and the remainder are stored in
    /// `otherObservations`. Exact-duplicate observations are collapsed so
    /// re-importing the same CSV stays idempotent. On a date tie the more
    /// complete observation (coords, then location) is chosen as the displayed
    /// one — this reproduces the old "heal a coord-less earliest sighting from
    /// a same-date row" behavior.
    static func make(
        scientificName: String,
        commonName: String,
        isStarred: Bool,
        observations: [Observation]
    ) -> LifeListEntry {
        var seen = Set<Observation>()
        let deduped = observations.filter { seen.insert($0).inserted }
        let sorted = deduped.sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            func completeness(_ o: Observation) -> Int {
                (o.latitude != nil && o.longitude != nil ? 2 : 0) + (o.location != nil ? 1 : 0)
            }
            return completeness(a) > completeness(b)
        }
        let first = sorted.first
        return LifeListEntry(
            scientificName: scientificName,
            commonName: commonName,
            firstSeen: first?.date ?? Date(),
            firstLocation: first?.location,
            firstLatitude: first?.latitude,
            firstLongitude: first?.longitude,
            isStarred: isStarred,
            otherObservations: Array(sorted.dropFirst())
        )
    }

    // Custom decode so older JSON without `isStarred` / coords / observations
    // still loads.
    enum CodingKeys: String, CodingKey {
        case scientificName, commonName, firstSeen
        case firstLocation, firstLatitude, firstLongitude
        case isStarred
        case otherObservations
    }

    init(
        scientificName: String,
        commonName: String,
        firstSeen: Date,
        firstLocation: String? = nil,
        firstLatitude: Double? = nil,
        firstLongitude: Double? = nil,
        isStarred: Bool = false,
        otherObservations: [Observation] = []
    ) {
        self.scientificName = scientificName
        self.commonName = commonName
        self.firstSeen = firstSeen
        self.firstLocation = firstLocation
        self.firstLatitude = firstLatitude
        self.firstLongitude = firstLongitude
        self.isStarred = isStarred
        self.otherObservations = otherObservations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scientificName = try c.decode(String.self, forKey: .scientificName)
        self.commonName     = try c.decode(String.self, forKey: .commonName)
        self.firstSeen      = try c.decode(Date.self,   forKey: .firstSeen)
        self.firstLocation  = try c.decodeIfPresent(String.self, forKey: .firstLocation)
        self.firstLatitude  = try c.decodeIfPresent(Double.self, forKey: .firstLatitude)
        self.firstLongitude = try c.decodeIfPresent(Double.self, forKey: .firstLongitude)
        self.isStarred      = try c.decodeIfPresent(Bool.self,   forKey: .isStarred) ?? false
        self.otherObservations = try c.decodeIfPresent([Observation].self, forKey: .otherObservations) ?? []
    }
}
