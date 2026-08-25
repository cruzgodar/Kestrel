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
/// After an ask, six more qualifying sessions have to go by before the next
/// one: asks land at 3 sessions, then 9, then 15. The spacing is counted in
/// sessions rather than marked against the app version, so a user who declines
/// isn't asked again on their very next walk, and a heavy user isn't asked
/// again the moment a new version ships. Requesting is only ever a request —
/// StoreKit decides whether a sheet actually appears and enforces its own
/// per-year cap, so this can afford to be permissive.
@MainActor
enum ReviewPrompt {
    private static let sessionCountKey = "review.qualifyingSessionCount"
    private static let promptedAtCountKey = "review.promptedAtSessionCount"
    /// Pre-cooldown installs recorded only the version they last asked on. Read
    /// for migration (see `promptedAtSessionCount`), never written any more.
    private static let promptedVersionKey = "review.promptedAppVersion"

    /// How long a session must run to count toward the threshold.
    static let minimumSessionDuration: TimeInterval = 60
    /// Qualifying sessions needed before we're willing to ask at all.
    private static let requiredSessions = 3
    /// Qualifying sessions that must go by *after* an ask before the next one.
    private static let sessionsBetweenPrompts = 6
    /// Beat between the session ending and the prompt appearing, so the sheet
    /// doesn't collide with the stop button's morph.
    private static let promptDelay: Duration = .seconds(3)

    /// Swappable so a test can run against a scratch suite. Every counter here
    /// is *cumulative for the life of the install* and never reset, so a test
    /// against the real defaults would permanently skew when the running app
    /// next asks for a review.
    static var defaults = UserDefaults.standard

    /// The running total of sessions that lasted at least `minimumSessionDuration`.
    /// Cumulative for the life of the install and never reset — the cooldown is
    /// expressed as an offset from this, so it has to keep climbing.
    static var qualifyingSessionCount: Int {
        defaults.integer(forKey: sessionCountKey)
    }

    /// `qualifyingSessionCount` as it stood the last time we asked, or `nil` if
    /// this install has never been asked. A pure read — see
    /// `migrateLegacyPromptRecord`, which is what puts a value here for an
    /// install that predates the cooldown.
    private static var promptedAtSessionCount: Int? {
        defaults.object(forKey: promptedAtCountKey) as? Int
    }

    /// Pins the ask point for an install that predates the cooldown, which
    /// recorded only the version it asked on.
    ///
    /// Backdates that ask to *now* rather than to zero, so someone who was
    /// already asked waits out a full cooldown instead of being asked again on
    /// their very next session. Runs once — the count it writes is what every
    /// later read sees — and is a no-op on an install that has either been asked
    /// under the current scheme or never been asked at all.
    ///
    /// Called explicitly at launch rather than lazily from `promptedAtSessionCount`.
    /// Doing it in that getter meant merely *reading* `isDue` consumed the
    /// migration and rewrote once-per-install state, which is not something a
    /// property named like a question should do — and it made the backdate land
    /// at whatever moment something first happened to ask.
    static func migrateLegacyPromptRecord() {
        guard defaults.object(forKey: promptedAtCountKey) == nil,
              defaults.string(forKey: promptedVersionKey) != nil else { return }
        defaults.set(qualifyingSessionCount, forKey: promptedAtCountKey)
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

    /// Whether the user has earned the prompt and is far enough past the last
    /// ask — `requiredSessions` in for the first one, `sessionsBetweenPrompts`
    /// more for every one after that.
    static var isDue: Bool {
        guard qualifyingSessionCount >= requiredSessions else { return false }
        guard let asked = promptedAtSessionCount else { return true }
        return qualifyingSessionCount >= asked + sessionsBetweenPrompts
    }

    /// Asks for a review a few seconds from now, if one is due. Safe to call on
    /// every phone-side session end — it's a no-op when the threshold hasn't been
    /// reached or the last ask is still inside its cooldown.
    ///
    /// The cooldown mark is only written once the request actually goes out. If
    /// the app is backgrounded when the delay expires there's no window to
    /// present in, so we skip and leave the user due for the next session end.
    static func requestIfDue() {
        guard isDue else { return }
        Task {
            try? await Task.sleep(for: promptDelay)
            guard isDue, let scene = activeScene else { return }
            defaults.set(qualifyingSessionCount, forKey: promptedAtCountKey)
            AppStore.requestReview(in: scene)
        }
    }

    /// The foreground-active window scene, or `nil` if the app isn't on screen.
    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
    }
}
