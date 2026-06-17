import Foundation
import Observation

/// UserDefaults keys for `AppSettings`. `nonisolated` (the project defaults to
/// MainActor isolation) so the nonisolated persisted-value readers can
/// reference them without an actor hop.
private nonisolated enum SettingsKeys {
    static let watchEntitlement = "settings.watchUsesBackgroundAudioEntitlement"
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

    /// Set by `WatchAudioBridge` so a change to `watchUsesBackgroundAudioEntitlement`
    /// is mirrored to the paired watch via `updateApplicationContext`. Kept as a
    /// closure so this model stays free of WatchConnectivity dependencies.
    var watchSyncHook: ((Bool) -> Void)?

    private let defaults = UserDefaults.standard

    private init() {
        watchUsesBackgroundAudioEntitlement = defaults.bool(forKey: SettingsKeys.watchEntitlement)
    }
}
