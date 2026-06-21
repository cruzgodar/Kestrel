import AppIntents
import Foundation

/// Shared between the app and its widget/complication extensions. Carries the
/// "please start a recording" request from a tapped widget into the running app.
///
/// `StartRecordingIntent` declares `openAppWhenRun = true`, so the system
/// foregrounds the app and runs `perform()` *in the app's process*. That lets
/// `fire()` reach the app directly — a `Notification` for the warm case (app
/// already active) plus a `UserDefaults` flag the app drains the next time it
/// becomes active (cold-launch case). Neither path references any app-only
/// type, so this file compiles cleanly into the widget extensions too.
enum RecordingIntentRequest {
    /// Posted (in-app) the moment the intent runs, for an already-active app.
    static let notification = Notification.Name("KestrelStartRecordingIntent")
    private static let pendingKey = "KestrelPendingStartRecording"

    /// Deep link the watch complication opens (via `widgetURL`) to ask the app
    /// to start recording. Handled in-process by the app's `onOpenURL`, which
    /// calls `fire()` — reliable where the widget-extension AppIntent path was
    /// not (its `perform()` runs out-of-process and never reached the app).
    static let startRecordingURL = URL(string: "kestrel://start-recording")!

    /// Called from `StartRecordingIntent.perform()` (which runs in the app
    /// process). Leaves a flag for a cold launch and posts for a warm one.
    static func fire() {
        UserDefaults.standard.set(true, forKey: pendingKey)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// Returns whether a start was requested, clearing the flag so it fires
    /// only once. Call when the app becomes active.
    static func consume() -> Bool {
        let pending = UserDefaults.standard.bool(forKey: pendingKey)
        if pending { UserDefaults.standard.set(false, forKey: pendingKey) }
        return pending
    }
}

/// App intent vended as a lock-screen widget (iOS) and a complication
/// (watchOS): start a new recording if one isn't already in progress. The
/// actual start is performed by the app when it consumes the request — the
/// app checks its own recording state, so a tap while recording is a no-op.
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription(
        "Start listening for birds if a recording isn't already in progress."
    )
    /// Foreground the app to run the intent and bring up the microphone.
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordingIntentRequest.fire()
        return .result()
    }
}
