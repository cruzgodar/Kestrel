import Foundation

struct LifeListEntry: Codable, Identifiable, Hashable {
    let scientificName: String
    var commonName: String
    var firstSeen: Date
    var firstLocation: String?
    /// User-toggled "alert me" flag. Starred species fire notifications when
    /// heard, get blue row + spectrogram highlighting in the Identify tab,
    /// and skip the full-width image treatment reserved for unseen species.
    var isStarred: Bool = false

    var id: String { scientificName }

    // Custom decode so older JSON without `isStarred` still loads.
    enum CodingKeys: String, CodingKey {
        case scientificName, commonName, firstSeen, firstLocation, isStarred
    }

    init(scientificName: String, commonName: String, firstSeen: Date, firstLocation: String? = nil, isStarred: Bool = false) {
        self.scientificName = scientificName
        self.commonName = commonName
        self.firstSeen = firstSeen
        self.firstLocation = firstLocation
        self.isStarred = isStarred
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scientificName = try c.decode(String.self, forKey: .scientificName)
        self.commonName     = try c.decode(String.self, forKey: .commonName)
        self.firstSeen      = try c.decode(Date.self,   forKey: .firstSeen)
        self.firstLocation  = try c.decodeIfPresent(String.self, forKey: .firstLocation)
        self.isStarred      = try c.decodeIfPresent(Bool.self,   forKey: .isStarred) ?? false
    }
}
