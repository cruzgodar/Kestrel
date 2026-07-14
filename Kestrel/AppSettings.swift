import Foundation
import Observation

/// UserDefaults keys for `AppSettings`. `nonisolated` (the project defaults to
/// MainActor isolation) so the nonisolated persisted-value readers can
/// reference them without an actor hop.
private nonisolated enum SettingsKeys {
    static let showRepeatObservations = "settings.showRepeatObservationsOnMap"
    static let noBirdTimeout = "settings.noBirdTimeout"
    static let hapticForAllBirds = "settings.hapticForAllBirds"
}

/// App-wide user settings, persisted to `UserDefaults`. A single shared
/// instance is read directly (`AppSettings.shared`) from SwiftUI view bodies —
/// `@Observable` tracks the property access there, so toggling a value
/// re-renders everything that reads it.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// How long a birding session may go without hearing any bird before Kestrel
    /// automatically stops it to save battery. `.never` disables the auto-stop.
    /// The raw value is the timeout in minutes (0 for `.never`), which is also
    /// what's persisted.
    enum NoBirdTimeout: Int, CaseIterable, Identifiable {
        case fifteenMinutes = 15
        case thirtyMinutes = 30
        case sixtyMinutes = 60
        case never = 0

        var id: Int { rawValue }

        /// The timeout in seconds, or nil for `.never` (keep listening forever).
        var seconds: TimeInterval? {
            self == .never ? nil : TimeInterval(rawValue * 60)
        }

        /// The picker row label.
        var label: String {
            switch self {
            case .fifteenMinutes: return "15 Minutes"
            case .thirtyMinutes:  return "30 Minutes"
            case .sixtyMinutes:   return "60 Minutes"
            case .never:          return "Never"
            }
        }
    }

    /// Auto-stop timeout after a stretch with no detections. Defaults to 30
    /// minutes — the value the watchdog was previously hardcoded to.
    var noBirdTimeout: NoBirdTimeout {
        didSet {
            defaults.set(noBirdTimeout.rawValue, forKey: SettingsKeys.noBirdTimeout)
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

    /// When enabled, Kestrel plays a single subtle haptic whenever it identifies a
    /// bird that's already on the user's life list and isn't starred — the birds
    /// that otherwise buzz nothing (new species and starred birds have their own,
    /// stronger haptics). Off by default so the wrist/phone only buzzes for the
    /// noteworthy birds unless the user opts in. Read live in
    /// `RecordingManager.merge(_:)`.
    var hapticForAllBirds: Bool {
        didSet {
            defaults.set(hapticForAllBirds, forKey: SettingsKeys.hapticForAllBirds)
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        // Defaults to on.
        showRepeatObservationsOnMap = defaults.object(forKey: SettingsKeys.showRepeatObservations) as? Bool ?? true
        // Defaults to 30 minutes.
        let storedTimeout = defaults.object(forKey: SettingsKeys.noBirdTimeout) as? Int
        noBirdTimeout = storedTimeout.flatMap(NoBirdTimeout.init(rawValue:)) ?? .thirtyMinutes
        // Defaults to off.
        hapticForAllBirds = defaults.object(forKey: SettingsKeys.hapticForAllBirds) as? Bool ?? false
    }
}
