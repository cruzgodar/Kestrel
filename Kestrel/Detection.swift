import Foundation

struct Detection: Identifiable, Hashable {
    let scientificName: String
    let commonName: String
    var confidence: Float
    var lastSeen: Date

    var id: String { scientificName }
}
