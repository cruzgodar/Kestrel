import UIKit

/// Per-device screen geometry that has no public API.
///
/// The display corner radius is only exposed via the private `_displayCornerRadius`
/// key, which we deliberately avoid. Instead we key a hardcoded table off the
/// device model identifier (public via `uname`), covering every iOS-26-capable
/// iPhone. Same-size devices differ in radius (e.g. iPhone 11 vs 11 Pro Max are
/// both 414×896), so the identifier — not the screen size — is the key.
///
/// Used to round the *bottom* corners of the map card so they trace the phone's
/// physical screen corners (concentric); the top corners are a separate, tighter
/// manual value.
///
/// Values from the community ScreenCorners / device_corner_radius tables.
enum DeviceMetrics {
    /// The display's corner radius in points, by model.
    static var displayCornerRadius: CGFloat {
        switch modelIdentifier {
        // iPhone 11 family (A13 — the iOS 26 floor)
        case "iPhone12,1":                       return 41.5  // iPhone 11
        case "iPhone12,3", "iPhone12,5":         return 39.0  // 11 Pro / Pro Max
        // iPhone 12 family
        case "iPhone13,1":                       return 44.0  // 12 mini
        case "iPhone13,2", "iPhone13,3":         return 47.33 // 12 / 12 Pro
        case "iPhone13,4":                       return 53.33 // 12 Pro Max
        // iPhone 13 family
        case "iPhone14,4":                       return 44.0  // 13 mini
        case "iPhone14,5", "iPhone14,2":         return 47.33 // 13 / 13 Pro
        case "iPhone14,3":                       return 53.33 // 13 Pro Max
        // iPhone 14 family
        case "iPhone14,7":                       return 47.33 // 14
        case "iPhone14,8":                       return 53.33 // 14 Plus
        case "iPhone15,2", "iPhone15,3":         return 55.0  // 14 Pro / Pro Max
        // iPhone 15 family
        case "iPhone15,4", "iPhone15,5":         return 55.0  // 15 / 15 Plus
        case "iPhone16,1", "iPhone16,2":         return 55.0  // 15 Pro / Pro Max
        // iPhone 16 family
        case "iPhone17,3", "iPhone17,4":         return 55.0  // 16 / 16 Plus
        case "iPhone17,1", "iPhone17,2":         return 62.0  // 16 Pro / Pro Max
        case "iPhone17,5":                       return 47.33 // 16e
        // SE 2 / SE 3 have square (non-rounded) display corners.
        case "iPhone12,8", "iPhone14,6":         return 0
        default:                                 return defaultCornerRadius
        }
    }

    /// Fallback for unknown/future models — a common modern-iPhone radius.
    static let defaultCornerRadius: CGFloat = 55

    /// The device model identifier, e.g. `iPhone17,1`. On the simulator `uname`
    /// reports the host Mac, so we read the simulated model from the environment.
    static var modelIdentifier: String {
        #if targetEnvironment(simulator)
        if let id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return id
        }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            buffer.prefix { $0 != 0 }
        }
        return String(decoding: machine, as: UTF8.self)
    }
}
