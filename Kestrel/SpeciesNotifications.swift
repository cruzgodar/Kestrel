import Foundation
import UserNotifications

/// Fires local notifications when a new species is detected while the
/// Identify spectrogram isn't on-screen (other tab, app backgrounded, screen
/// off). The notification carries the species' common name and bundled
/// thumbnail as an image attachment.
@MainActor
final class SpeciesNotifications {
    static let shared = SpeciesNotifications()

    private let center = UNUserNotificationCenter.current()
    private var didRequestAuth = false

    private init() {}

    /// Asks the system once for alert+sound permission. Called when the user
    /// first starts a recording session, so we don't pop the system prompt
    /// before there's any reason for notifications.
    func requestAuthorizationIfNeeded() {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        Task { [center] in
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                print("Kestrel: notification auth error — \(error)")
            }
        }
    }

    /// Schedules an immediate local notification for a new species. No-op if
    /// the user hasn't granted notification permission.
    func notifyNewSpecies(commonName: String, scientificName: String) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = commonName
        content.body  = "New species heard"
        content.sound = .default
        if let attachment = makeAttachment(scientificName: scientificName) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: "kestrel-species-\(UUID().uuidString)",
            content: content,
            trigger: nil  // deliver immediately
        )
        do {
            try await center.add(request)
        } catch {
            print("Kestrel: notification deliver error — \(error)")
        }
    }

    /// Bundled species thumbnails live inside the read-only app bundle.
    /// `UNNotificationAttachment` moves the file it's given into a private
    /// notification store, so we copy the bundle image into the temp
    /// directory first.
    private func makeAttachment(scientificName: String) -> UNNotificationAttachment? {
        guard let bundleURL = SpeciesImage.url(for: scientificName) else { return nil }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-\(UUID().uuidString).jpg")
        do {
            try FileManager.default.copyItem(at: bundleURL, to: tmpURL)
            return try UNNotificationAttachment(identifier: scientificName, url: tmpURL)
        } catch {
            print("Kestrel: notification attachment error — \(error)")
            return nil
        }
    }
}
