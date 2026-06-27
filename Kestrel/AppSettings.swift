import Foundation
import Observation

/// UserDefaults keys for `AppSettings`. `nonisolated` (the project defaults to
/// MainActor isolation) so the nonisolated persisted-value readers can
/// reference them without an actor hop.
private nonisolated enum SettingsKeys {
    static let showRepeatObservations = "settings.showRepeatObservationsOnMap"
    static let updateMapDuringGesture = "settings.updateMapDuringGesture"
    static let fadeMapThumbnails = "settings.fadeMapThumbnails"
    static let forceOfflineSpeciesList = "settings.forceOfflineSpeciesList"
}

/// App-wide user settings, persisted to `UserDefaults`. A single shared
/// instance is read directly (`AppSettings.shared`) from SwiftUI view bodies —
/// `@Observable` tracks the property access there, so toggling a value
/// re-renders everything that reads it.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// When enabled (the default), the Map tab plots every stored sighting of
    /// each species, not just the earliest one — so a bird imported with many
    /// eBird observations drops a pin at each location. The extra observations
    /// are always stored on import regardless; this just controls whether
    /// they're mapped.
    var showRepeatObservationsOnMap: Bool {
        didSet {
            defaults.set(showRepeatObservationsOnMap, forKey: SettingsKeys.showRepeatObservations)
        }
    }

    /// When on, the map's annotation set is rebuilt/culled live during a pan or
    /// pinch (thumbnails appear/disappear continuously while the gesture is in
    /// progress). When off (the default), the rebuild is deferred to the instant
    /// the touch lifts, so thumbnails snap into place once rather than churning
    /// mid-gesture.
    var updateMapDuringGesture: Bool {
        didSet {
            defaults.set(updateMapDuringGesture, forKey: SettingsKeys.updateMapDuringGesture)
        }
    }

    /// When on, map thumbnails fade in/out as they enter and leave the visible
    /// cluster set; when off (the default), they snap instantly.
    var fadeMapThumbnails: Bool {
        didSet {
            defaults.set(fadeMapThumbnails, forKey: SettingsKeys.fadeMapThumbnails)
        }
    }

    /// Debug: when on, identification skips the live geo model and the cached
    /// list and forces the bundled offline species filter, logging how long each
    /// lookup into it takes. Off by default.
    var forceOfflineSpeciesList: Bool {
        didSet {
            defaults.set(forceOfflineSpeciesList, forKey: SettingsKeys.forceOfflineSpeciesList)
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        // Defaults to on.
        showRepeatObservationsOnMap = defaults.object(forKey: SettingsKeys.showRepeatObservations) as? Bool ?? true
        // The rest default to off.
        updateMapDuringGesture = defaults.bool(forKey: SettingsKeys.updateMapDuringGesture)
        fadeMapThumbnails = defaults.bool(forKey: SettingsKeys.fadeMapThumbnails)
        forceOfflineSpeciesList = defaults.bool(forKey: SettingsKeys.forceOfflineSpeciesList)
    }
}
