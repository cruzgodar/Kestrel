import Foundation
import Observation

/// UserDefaults keys for `AppSettings`. `nonisolated` (the project defaults to
/// MainActor isolation) so the nonisolated persisted-value readers can
/// reference them without an actor hop.
private nonisolated enum SettingsKeys {
    static let watchEntitlement = "settings.watchUsesBackgroundAudioEntitlement"
    static let imageSource = "settings.imageSource"
}

/// Where species photos come from.
///
/// `.bundled` — the JPEGs shipped inside the app (`SpeciesImagesLarge`). Fast,
/// offline, but redistributes Macaulay Library photos, which is only licensed
/// for non-commercial use.
/// `.embed` — load each photo remotely from the Macaulay Library CDN at display
/// time, with an on-image attribution caption, instead of bundling the file.
/// This is the lighter-weight, closer-to-license-compliant path.
enum SpeciesImageSource: String, CaseIterable, Identifiable {
    case bundled
    case embed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bundled: return "Bundled photos"
        case .embed:   return "Official embed"
        }
    }
}

/// App-wide user settings, persisted to `UserDefaults`. A single shared
/// instance is read directly (`AppSettings.shared`) from SwiftUI view bodies —
/// `@Observable` tracks the property access there, so toggling a value
/// re-renders everything that reads it.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// When enabled, the watch attempts to keep its capture session running in
    /// the background using the declared `audio` background mode (which depends
    /// on a background-audio entitlement Apple does not generally grant) rather
    /// than relying solely on a `WKExtendedRuntimeSession`. Off by default — it
    /// only does anything on a build whose provisioning profile actually has
    /// the entitlement, so it's effectively a testing switch.
    var watchUsesBackgroundAudioEntitlement: Bool {
        didSet {
            defaults.set(watchUsesBackgroundAudioEntitlement, forKey: SettingsKeys.watchEntitlement)
            // Let the watch bridge re-push the value over WatchConnectivity.
            watchSyncHook?(watchUsesBackgroundAudioEntitlement)
        }
    }

    /// Source for species photos shown in the detection list, life list, and map.
    var imageSource: SpeciesImageSource {
        didSet { defaults.set(imageSource.rawValue, forKey: SettingsKeys.imageSource) }
    }

    /// Set by `WatchAudioBridge` so a change to `watchUsesBackgroundAudioEntitlement`
    /// is mirrored to the paired watch via `updateApplicationContext`. Kept as a
    /// closure so this model stays free of WatchConnectivity dependencies.
    var watchSyncHook: ((Bool) -> Void)?

    private let defaults = UserDefaults.standard

    /// Reads the persisted image source without touching the MainActor-isolated
    /// shared instance — usable from `App.init`, which runs before the main
    /// actor context the singleton requires.
    nonisolated static func persistedImageSource() -> SpeciesImageSource {
        SpeciesImageSource(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.imageSource) ?? "")
            ?? .bundled
    }

    private init() {
        watchUsesBackgroundAudioEntitlement = defaults.bool(forKey: SettingsKeys.watchEntitlement)
        imageSource = SpeciesImageSource(rawValue: defaults.string(forKey: SettingsKeys.imageSource) ?? "")
            ?? .bundled
    }
}
