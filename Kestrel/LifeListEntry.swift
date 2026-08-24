import Foundation

nonisolated struct LifeListEntry: Codable, Identifiable, Hashable {
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
    /// Provenance of the displayed first sighting — see
    /// `Observation.isImported`. Stored out here for the same reason
    /// `firstLocation` is: the earliest observation's fields live on the entry
    /// rather than in `otherObservations`.
    var firstIsImported: Bool = false
    /// User-toggled "alert me" flag. Starred species fire notifications when
    /// heard, get blue row + spectrogram highlighting in the Identify tab,
    /// and skip the full-width image treatment reserved for unseen species.
    var isStarred: Bool = false

    /// Every sighting of this species *other than* the earliest one (which is
    /// the one surfaced via `firstSeen` / `first*` and shown in the UI). On an
    /// eBird import each CSV row becomes one observation; the earliest is
    /// promoted to the displayed fields and the rest are kept here. Every one of
    /// them is plotted on the map and listed by the observation pickers; the Life
    /// List's own rows only ever display the earliest.
    var otherObservations: [Observation] = []

    var id: String { scientificName }

    /// A single recorded sighting — date plus where it happened. Mirrors the
    /// per-row fields of an eBird CSV export.
    nonisolated struct Observation: Codable, Hashable {
        var date: Date
        var location: String?
        var latitude: Double?
        var longitude: Double?
        /// True when this sighting arrived on an eBird CSV import rather than
        /// being recorded in Kestrel. The eBird export skips these: they came
        /// *from* eBird, so handing them back would duplicate records the
        /// account already has.
        var isImported: Bool = false

        /// Everything that makes two records the *same* sighting. Deliberately
        /// excludes `isImported`, which is provenance rather than identity — a
        /// bird added by hand and later restated by an import is one
        /// observation, not two.
        nonisolated struct Identity: Hashable {
            let date: Date
            let location: String?
            let latitude: Double?
            let longitude: Double?
        }

        var identity: Identity {
            Identity(date: date, location: location, latitude: latitude, longitude: longitude)
        }

        /// Whether this sighting can be put on a map. False for anything logged
        /// before coordinates were recorded, and for eBird rows whose Latitude /
        /// Longitude columns were blank — the UI hides its map affordances for
        /// those rather than offering a tap that goes nowhere.
        var hasCoordinate: Bool { latitude != nil && longitude != nil }

        init(
            date: Date,
            location: String? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            isImported: Bool = false
        ) {
            self.date = date
            self.location = location
            self.latitude = latitude
            self.longitude = longitude
            self.isImported = isImported
        }

        enum CodingKeys: String, CodingKey {
            case date, location, latitude, longitude, isImported
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date      = try c.decode(Date.self, forKey: .date)
            location  = try c.decodeIfPresent(String.self, forKey: .location)
            latitude  = try c.decodeIfPresent(Double.self, forKey: .latitude)
            longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
            // Sightings persisted before provenance was tracked default to
            // *imported*. Nearly all of them are — seeding the list from an
            // eBird export is the intended onboarding — and the two failure
            // modes aren't symmetric: wrongly calling one Kestrel-native
            // duplicates a record in eBird, which is the whole thing this flag
            // exists to prevent, while wrongly calling one imported just means
            // reaching for "Export All Observations" once.
            isImported = try c.decodeIfPresent(Bool.self, forKey: .isImported) ?? true
        }
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
            longitude: firstLongitude,
            isImported: firstIsImported
        )] + otherObservations
    }

    /// Collapses observations sharing an `Observation.Identity`, preserving first
    /// -seen order. Keyed on identity rather than on whole-value equality so the
    /// same sighting recorded twice with different provenance still merges; the
    /// flags OR together, since if any copy came from an import then eBird has it.
    /// Only ever reached through `make(dedupe: true)` — see the note there.
    private static func collapseByIdentity(_ observations: [Observation]) -> [Observation] {
        var byIdentity: [Observation.Identity: Observation] = [:]
        var order: [Observation.Identity] = []
        for observation in observations {
            let identity = observation.identity
            guard var existing = byIdentity[identity] else {
                byIdentity[identity] = observation
                order.append(identity)
                continue
            }
            if observation.isImported && !existing.isImported {
                existing.isImported = true
                byIdentity[identity] = existing
            }
        }
        return order.compactMap { byIdentity[$0] }
    }

    /// Builds an entry from an unordered set of observations: the earliest one
    /// becomes the displayed `first*` fields and the remainder are stored in
    /// `otherObservations`. On a date tie the more complete observation (coords,
    /// then location) is chosen as the displayed one — this reproduces the old
    /// "heal a coord-less earliest sighting from a same-date row" behavior.
    ///
    /// `dedupe` collapses observations that share an `Observation.Identity`, and
    /// is for **merging records from outside the app only** — an eBird import,
    /// or the canonicalization pass that folds two taxonomic spellings of one
    /// species together. It is what keeps re-importing the same CSV idempotent.
    ///
    /// Every path where the *user* writes a sighting directly — recording one,
    /// editing one, deleting one — passes `false`. Two identical sightings are a
    /// thing a person can legitimately record, and an edit must never be able to
    /// make a record disappear: with dedupe on, correcting one imported sighting's
    /// date onto a same-place sibling's date produced an identical identity and
    /// silently collapsed the two into one, with no warning and no undo.
    static func make(
        scientificName: String,
        commonName: String,
        isStarred: Bool,
        observations: [Observation],
        dedupe: Bool
    ) -> LifeListEntry {
        let resolved = dedupe ? collapseByIdentity(observations) : observations
        let sorted = resolved.sorted { a, b in
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
            firstIsImported: first?.isImported ?? false,
            isStarred: isStarred,
            otherObservations: Array(sorted.dropFirst())
        )
    }

    // Custom decode so older JSON without `isStarred` / coords / observations
    // still loads.
    enum CodingKeys: String, CodingKey {
        case scientificName, commonName, firstSeen
        case firstLocation, firstLatitude, firstLongitude
        case firstIsImported
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
        firstIsImported: Bool = false,
        isStarred: Bool = false,
        otherObservations: [Observation] = []
    ) {
        self.scientificName = scientificName
        self.commonName = commonName
        self.firstSeen = firstSeen
        self.firstLocation = firstLocation
        self.firstLatitude = firstLatitude
        self.firstLongitude = firstLongitude
        self.firstIsImported = firstIsImported
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
        // Legacy rows default to imported — same reasoning as
        // `Observation.init(from:)`.
        self.firstIsImported = try c.decodeIfPresent(Bool.self, forKey: .firstIsImported) ?? true
        self.isStarred      = try c.decodeIfPresent(Bool.self,   forKey: .isStarred) ?? false
        self.otherObservations = try c.decodeIfPresent([Observation].self, forKey: .otherObservations) ?? []
    }
}
