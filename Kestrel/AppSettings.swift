import Foundation
import Observation

/// UserDefaults keys for `AppSettings`. `nonisolated` (the project defaults to
/// MainActor isolation) so the nonisolated persisted-value readers can
/// reference them without an actor hop.
private nonisolated enum SettingsKeys {
    static let preferWatchMic = "settings.preferWatchMicrophone"
    static let showRepeatObservations = "settings.showRepeatObservationsOnMap"
}

/// App-wide user settings, persisted to `UserDefaults`. A single shared
/// instance is read directly (`AppSettings.shared`) from SwiftUI view bodies —
/// `@Observable` tracks the property access there, so toggling a value
/// re-renders everything that reads it.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// When enabled (the default), tapping Start Recording on either device
    /// uses the paired Apple Watch's microphone if it's reachable, falling back
    /// to the phone mic otherwise. When disabled, both devices' Start buttons
    /// always capture with the phone's own microphone.
    /// Phone-only: the watch's own Start always uses the watch mic, so this
    /// preference doesn't need to sync over WatchConnectivity.
    var preferWatchMicrophone: Bool {
        didSet {
            defaults.set(preferWatchMicrophone, forKey: SettingsKeys.preferWatchMic)
        }
    }

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

    private let defaults = UserDefaults.standard

    private init() {
        // Defaults to on when the user has never set it.
        preferWatchMicrophone = defaults.object(forKey: SettingsKeys.preferWatchMic) as? Bool ?? true
        // Defaults to on.
        showRepeatObservationsOnMap = defaults.object(forKey: SettingsKeys.showRepeatObservations) as? Bool ?? true
    }
}
