import Foundation
import UserNotifications

/// Watch-local notifications. A watch-first user may start a session from the
/// wrist with the iPhone pocketed or never opened, so the watch asks for its own
/// notification permission (alongside mic + location) at the first start and
/// posts its own alerts when a session ends without the user asking — e.g. the
/// phone link is lost for good. Without this the only signal would be the screen
/// silently returning to idle.
enum WatchNotifications {
    /// Requests alert/sound authorization if it hasn't been decided yet. Called
    /// at the first Start Recording tap on the watch, after mic + location, so a
    /// brand-new user grants everything the birding flow needs in one go.
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Posts a local notification that a session ended on its own (not a user
    /// stop). No-op if notifications were denied.
    static func notifySessionEnded(body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Kestrel"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}
