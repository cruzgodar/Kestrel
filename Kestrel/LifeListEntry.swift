import Foundation

struct LifeListEntry: Codable, Identifiable, Hashable {
    let scientificName: String
    var commonName: String
    var firstSeen: Date
    var firstLocation: String?

    var id: String { scientificName }
}
