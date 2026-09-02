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

/// App intent that starts a new recording if one isn't already in progress. The
/// actual start is performed by the app when it consumes the request — the
/// app checks its own recording state, so a tap while recording is a no-op.
///
/// Vended as a lock-screen widget and a Control Center control on iOS
/// (`KestrelWidget`). On watchOS it is reachable from **Shortcuts only** — the
/// complication deliberately just opens the app rather than starting a walk on a
/// stray tap (see `StartRecordingComplicationView`), so nothing on the wrist
/// runs this by itself. Both apps drain it the same way, through
/// `RecordingIntentRequest.consume()` on becoming active.
struct StartRecordingIntent: AppIntent {
    // "Start Birding", matching the app's own record button — every user-facing
    // string for this action says the same thing, in Shortcuts, in the widget
    // gallery and on screen. (The *type* keeps its name: it is the widget's
    // stored `kind` and the app's own vocabulary for the mechanism.)
    static var title: LocalizedStringResource = "Start Birding"
    static var description = IntentDescription(
        "Start listening for birds if a session isn\u{2019}t already in progress."
    )
    /// Foreground the app to run the intent and bring up the microphone.
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordingIntentRequest.fire()
        return .result()
    }
}
