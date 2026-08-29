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

    /// Category stamped on the per-bird alerts (`notifyNewSpecies`). It carries
    /// no actions — it exists so `willPresent` can tell "a bird was heard" apart
    /// from the app's few lifecycle notifications and drop the sound for it. See
    /// `presentationOptions(forCategory:)`.
    nonisolated static let speciesCategory = "kestrel-species"

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
        let idleCategory = UNNotificationCategory(
            identifier: Self.idleTimeoutCategory,
            actions: [endAction],
            intentIdentifiers: [],
            options: []
        )
        // Registered despite having no actions of its own, so the identifier the
        // species alerts carry is a declared category rather than a bare string
        // the system has never heard of.
        let speciesCategory = UNNotificationCategory(
            identifier: Self.speciesCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([idleCategory, speciesCategory])
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
        // Kept for delivery while the app is *away* — a pocketed phone's only
        // announcement. The foreground case drops it; see `willPresent`.
        content.sound = .default
        content.categoryIdentifier = Self.speciesCategory
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
        } catch {
            Log.error("Notification attachment copy error — \(error)")
            return nil
        }
        do {
            return try UNNotificationAttachment(identifier: scientificName, url: tmpURL)
        } catch {
            // The copy landed but the attachment was rejected, so nothing is going
            // to move the file into the notification store — clean it up rather
            // than leaving a stray JPEG in tmp for every failed notification. The
            // app already leaked gigabytes into tmp once (see `CoreMLModelCache`).
            try? FileManager.default.removeItem(at: tmpURL)
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

    /// Presents everything Kestrel posts, foregrounded or not.
    ///
    /// **Whether an alert is wanted is decided where it is posted, not here.**
    /// Every `add` in this file already sits behind a condition that knows the
    /// context: a species alert only exists when
    /// `RecordingManager.spectrogramVisible` is false, a lifecycle alert only
    /// when a watch session has actually ended, the idle prompt only after a
    /// silent stretch. There is nothing left for this method to second-guess.
    ///
    /// Suppressing everything but the idle prompt looked like "don't interrupt
    /// the foreground", but it was a *different* rule from the one the post site
    /// applies, and the gap between them swallowed real alerts.
    /// `spectrogramVisible` means "on the Identify tab **and** active", so
    /// recording while looking at the Map, Life List or Settings tab posted a
    /// new-species notification that was then dropped here. The haptic still
    /// fired (the app is foregrounded, so `RecordingManager.merge` buzzes the
    /// phone), leaving a pulse for a new lifer with nothing anywhere naming the
    /// bird. "Watch disconnected" went the same way.
    ///
    /// The bird was not left un-announceable for the rest of
    /// `DetectionCooldowns.notify`, though — `RecordingManager.merge` calls
    /// `DetectionCooldowns.markHeard` on every detection whether or not it queued
    /// a notification, so the window was already running regardless. What was lost
    /// was the one banner, not the ones after it.
    ///
    /// What it *doesn't* do is play a sound for a bird. See
    /// `presentationOptions(forCategory:)`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(
            Self.presentationOptions(
                forCategory: notification.request.content.categoryIdentifier
            )
        )
    }

    /// How a notification is presented while the app is on screen.
    ///
    /// Everything banners (see `willPresent`). The **sound** is the part that
    /// depends on what is being said, and a per-bird alert is the one thing that
    /// must not make one.
    ///
    /// A species alert already has a signal, and it isn't audible:
    /// `RecordingManager.merge` buzzes the phone for exactly these birds whenever
    /// the app is foregrounded. Letting the banner ring on top of that means a
    /// walk spent with the Map tab open chirps out loud at every new lifer — from
    /// an app whose whole premise is that you can put the phone away and let your
    /// wrist tell you. The sound stays on `content.sound` so a *backgrounded*
    /// delivery still announces itself, which is the case with no haptic and no
    /// screen to look at.
    ///
    /// The handful of lifecycle notifications keep theirs. Each one is a one-off
    /// asking for a decision or reporting that recording has stopped — "no birds
    /// heard for 30 minutes, end the session?", "watch recording stopped" — none
    /// of which repeats, and all of which are worth interrupting for.
    nonisolated static func presentationOptions(
        forCategory category: String
    ) -> UNNotificationPresentationOptions {
        category == speciesCategory ? [.banner] : [.banner, .sound]
    }
}
