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

    var id: String { scientificName }

    // Custom decode so older JSON without `isStarred` / coords still loads.
    enum CodingKeys: String, CodingKey {
        case scientificName, commonName, firstSeen
        case firstLocation, firstLatitude, firstLongitude
        case isStarred
    }

    init(
        scientificName: String,
        commonName: String,
        firstSeen: Date,
        firstLocation: String? = nil,
        firstLatitude: Double? = nil,
        firstLongitude: Double? = nil,
        isStarred: Bool = false
    ) {
        self.scientificName = scientificName
        self.commonName = commonName
        self.firstSeen = firstSeen
        self.firstLocation = firstLocation
        self.firstLatitude = firstLatitude
        self.firstLongitude = firstLongitude
        self.isStarred = isStarred
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
    }
}
