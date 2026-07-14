import Foundation
import UserNotifications

/// Fires local notifications when a new species is detected while the
/// Identify spectrogram isn't on-screen (other tab, app backgrounded, screen
/// off). The notification carries the species' common name and embed
/// thumbnail as an image attachment.
@MainActor
final class SpeciesNotifications: NSObject {
    static let shared = SpeciesNotifications()

    private let center = UNUserNotificationCenter.current()
    private var didRequestAuth = false

    /// Category + action identifiers for the idle-timeout prompt. The prompt no
    /// longer stops the session outright — it asks, and carries an "End Session"
    /// action (revealed by pressing and holding / expanding the notification)
    /// that the delegate below routes back to the recording manager.
    nonisolated static let idleTimeoutCategory = "kestrel-idle-timeout"
    nonisolated static let endSessionAction = "kestrel-end-session"

    /// Invoked when the user taps the idle-timeout notification's "End Session"
    /// action. Wired by `KestrelApp` to end whichever session is active.
    var onEndSessionRequested: (() -> Void)?

    private override init() {
        super.init()
    }

    /// Registers the notification delegate + the idle-timeout category (so its
    /// "End Session" action button appears) and wires the end-session callback.
    /// Called once at launch from `KestrelApp`.
    func configure(onEndSession: @escaping () -> Void) {
        onEndSessionRequested = onEndSession
        center.delegate = self

        let endAction = UNNotificationAction(
            identifier: Self.endSessionAction,
            title: "End Session",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.idleTimeoutCategory,
            actions: [endAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Asks the system once for alert+sound permission, awaiting the user's
    /// choice. Called from the first Start Recording flow, after the location
    /// prompt has resolved, so the two prompts appear one at a time. A no-op on
    /// every call after the first.
    func requestAuthorizationIfNeeded() async {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.error("Notification auth error — \(error)")
        }
    }

    /// Schedules an immediate local notification for a new species. No-op if
    /// the user hasn't granted notification permission.
    enum Reason {
        case starred
        case newSpecies

        var body: String {
            switch self {
            case .starred:    return "Starred species heard"
            case .newSpecies: return "New species heard"
            }
        }
    }

    func notifyNewSpecies(commonName: String, scientificName: String, reason: Reason) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = commonName
        content.body  = reason.body
        content.sound = .default
        if let attachment = await makeAttachment(scientificName: scientificName) {
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
            Log.error("Notification deliver error — \(error)")
        }
    }

    /// Fires a plain text notification (no species thumbnail) used to tell
    /// the user that a watch streaming session ended — either because the
    /// system's 1-hour extended-runtime budget expired, or because audio
    /// stopped flowing from the watch (out of range, app crashed, battery).
    func notifySessionLifecycle(title: String, body: String) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "kestrel-watch-session-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            Log.error("Lifecycle notification error — \(error)")
        }
    }

    /// Fires the idle-timeout prompt: a rich notification asking whether to end
    /// the session after a stretch with no detections. It carries the "End
    /// Session" action (shown when the notification is pressed-and-held /
    /// expanded); tapping it ends the session via the delegate below. Unlike the
    /// old behavior, the session keeps running until the user chooses to end it.
    func notifyIdleTimeoutPrompt(minutes: Int) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "Kestrel"
        content.body = "No birds heard for \(minutes) minutes. End the session to save battery?"
        content.sound = .default
        content.categoryIdentifier = Self.idleTimeoutCategory

        let request = UNNotificationRequest(
            identifier: "kestrel-idle-timeout-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            Log.error("Idle-timeout notification error — \(error)")
        }
    }

    /// Pulls the species' embed photo from `RemoteSpeciesImageStore` (its disk
    /// cache, downloading if needed). `UNNotificationAttachment` moves the file
    /// it's given into a private notification store, so we copy the cached image
    /// into the temp directory first rather than letting it consume our cache.
    private func makeAttachment(scientificName: String) async -> UNNotificationAttachment? {
        guard let fileURL = await RemoteSpeciesImageStore.shared.localFileURL(for: scientificName) else {
            return nil
        }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kestrel-\(UUID().uuidString).jpg")
        do {
            try FileManager.default.copyItem(at: fileURL, to: tmpURL)
            return try UNNotificationAttachment(identifier: scientificName, url: tmpURL)
        } catch {
            Log.error("Notification attachment error — \(error)")
            return nil
        }
    }
}

extension SpeciesNotifications: UNUserNotificationCenterDelegate {
    /// Handles the user tapping the idle-timeout prompt's "End Session" action.
    /// The system delivers this on a background queue, so it's `nonisolated`;
    /// we hop to the main actor to invoke the callback and call the completion
    /// handler. Non-matching responses (a plain tap that just opens the app) are
    /// ignored.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        Task { @MainActor in
            if actionID == Self.endSessionAction {
                onEndSessionRequested?()
            }
            completionHandler()
        }
    }

    /// Presents the idle-timeout prompt even while the app is foregrounded, so its
    /// "End Session" action is reachable if the user happens to be in the app when
    /// the silence threshold is crossed. Other notifications keep the default
    /// foregrounded behavior (the species alerts already gate themselves on the
    /// spectrogram not being visible).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.categoryIdentifier == Self.idleTimeoutCategory {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([])
        }
    }
}
