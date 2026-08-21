import Foundation
import StoreKit
import UIKit

/// Decides when to ask the user for an App Store review, and asks.
///
/// The rule: once three birding sessions have run for at least a minute each,
/// the next session the user *ends on the phone* is followed — three seconds
/// later, so the prompt lands after the stop animation rather than on top of
/// it — by the system review sheet. Short sessions never count; a minute is
/// roughly the point at which the app has actually done its job.
///
/// Both halves are persisted in `UserDefaults`, so the count survives launches
/// and the "already asked" mark survives everything except an app update. The
/// mark is the app's *version*, not a bool: on a new version the user is asked
/// again, which is what makes a long-running install re-prompt after an update
/// instead of asking exactly once, forever. Requesting is only ever a request —
/// StoreKit decides whether a sheet actually appears and enforces its own
/// per-year cap, so this can afford to be permissive.
@MainActor
enum ReviewPrompt {
    private static let sessionCountKey = "review.qualifyingSessionCount"
    private static let promptedVersionKey = "review.promptedAppVersion"

    /// How long a session must run to count toward the threshold.
    static let minimumSessionDuration: TimeInterval = 60
    /// Qualifying sessions needed before we're willing to ask at all.
    private static let requiredSessions = 3
    /// Beat between the session ending and the prompt appearing, so the sheet
    /// doesn't collide with the stop button's morph.
    private static let promptDelay: Duration = .seconds(3)

    private static let defaults = UserDefaults.standard

    /// The running total of sessions that lasted at least `minimumSessionDuration`.
    /// Cumulative for the life of the install — never reset, so a user who has
    /// already put in the time is eligible the moment a new version ships.
    static var qualifyingSessionCount: Int {
        defaults.integer(forKey: sessionCountKey)
    }

    /// The app version we last showed (well, last *asked* to show) the prompt on.
    /// `nil` until the first ask.
    private static var promptedVersion: String? {
        defaults.string(forKey: promptedVersionKey)
    }

    /// Marketing version — what the user sees as "the app updated". Build number
    /// deliberately left out: a rebuild of the same release isn't an update from
    /// the user's point of view.
    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Records a finished session. Sessions shorter than a minute are ignored
    /// entirely rather than counted at a discount — a 20-second tap-and-stop is
    /// no evidence the app is worth reviewing.
    ///
    /// Counts sessions from *either* source: a walk recorded on the watch is as
    /// much a session as one recorded on the phone. Only the eventual prompt is
    /// phone-only, since that's where a review sheet can appear.
    static func recordSession(duration: TimeInterval) {
        guard duration >= minimumSessionDuration else { return }
        defaults.set(qualifyingSessionCount + 1, forKey: sessionCountKey)
    }

    /// Whether the user has earned the prompt and hasn't been asked on this
    /// version yet.
    static var isDue: Bool {
        qualifyingSessionCount >= requiredSessions && promptedVersion != currentVersion
    }

    /// Asks for a review a few seconds from now, if one is due. Safe to call on
    /// every phone-side session end — it's a no-op when the threshold hasn't been
    /// reached or this version has already asked.
    ///
    /// The version mark is only written once the request actually goes out. If
    /// the app is backgrounded when the delay expires there's no window to
    /// present in, so we skip and leave the user due for the next session end.
    static func requestIfDue() {
        guard isDue else { return }
        Task {
            try? await Task.sleep(for: promptDelay)
            guard isDue, let scene = activeScene else { return }
            defaults.set(currentVersion, forKey: promptedVersionKey)
            AppStore.requestReview(in: scene)
        }
    }

    /// The foreground-active window scene, or `nil` if the app isn't on screen.
    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
    }
}
