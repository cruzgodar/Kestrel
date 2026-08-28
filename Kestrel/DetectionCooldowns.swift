import Foundation

/// The per-species clocks a recording session keeps, so a bird that goes on
/// singing doesn't strobe its row, buzz the wrist every window, or re-notify
/// every three seconds.
///
/// There are three of them and they run at different rates, because they answer
/// different questions:
///
///   • **flash** — the row's visual pulse on a repeat match. Short, because the
///     pulse is the whole feedback that the bird was heard again.
///   • **haptic** — the tap for a new or starred bird (and, opt-in, for an
///     ordinary one). Deliberately the same short window as the flash: a
///     still-singing lifer should keep tapping rather than going quiet for the
///     rest of the walk.
///   • **notify** — the banner. Much longer, because a banner is an
///     interruption; the clock resets on *every* detection (see `markHeard`), so
///     a continuously-singing bird fires once and a bird that goes quiet and
///     comes back fires again.
///
/// **They live in one value so they can only be reset together.** They used to
/// be three dictionaries on `RecordingManager`, cleared by three parallel lines
/// in each of the two session-start paths — and the notify clock was missing
/// from all of them. Nothing failed loudly: a species heard within
/// `notify` seconds of the *previous* session's last detection simply had its
/// first banner of the new session swallowed, which is exactly the
/// stop-and-restart-while-a-bird-is-singing case. One `reset()` over one value
/// is a thing that can't be half-done.
///
/// `nonisolated` because the project is MainActor-by-default and this is plain
/// arithmetic over dictionaries — which is also what lets the tests drive it
/// with an explicit clock instead of a live recording session.
nonisolated struct DetectionCooldowns {
    /// How long a species' row waits between visual flashes.
    static let flash: TimeInterval = 5
    /// How long a species waits between haptics. Matches `flash` on purpose —
    /// the tap and the pulse are the same acknowledgement in two senses.
    static let haptic: TimeInterval = 5
    /// How long a species waits between notification banners.
    static let notify: TimeInterval = 30

    private var lastFlashAt: [String: Date] = [:]
    private var lastHeardAt: [String: Date] = [:]
    private var lastHapticAt: [String: Date] = [:]

    init() {}

    /// Clears every clock. Called at the top of each session-start path so a new
    /// session is never judged against the previous one's timings.
    mutating func reset() {
        self = DetectionCooldowns()
    }

    /// Whether this detection's row may flash now, stamping the clock if so.
    mutating func shouldFlash(_ id: String, at now: Date) -> Bool {
        Self.take(&lastFlashAt, id, Self.flash, now)
    }

    /// Whether this species may buzz now, stamping the clock if so.
    mutating func shouldBuzz(_ scientificName: String, at now: Date) -> Bool {
        Self.take(&lastHapticAt, scientificName, Self.haptic, now)
    }

    /// Whether this species may raise a banner now.
    ///
    /// A pure read, unlike the two above: the notify clock is stamped by
    /// `markHeard` on *every* detection, heard-worthy or not, so that a bird
    /// still singing keeps pushing its next banner out rather than earning one
    /// every `notify` seconds.
    func shouldNotify(_ scientificName: String, at now: Date) -> Bool {
        Self.hasElapsed(lastHeardAt[scientificName], Self.notify, by: now)
    }

    /// Records that a species was heard, whatever was done about it. This is the
    /// stamp `shouldNotify` reads.
    mutating func markHeard(_ scientificName: String, at now: Date) {
        lastHeardAt[scientificName] = now
    }

    /// Whether `interval` has passed since `last`. A clock that has never been
    /// stamped is always due — the first detection of a species is never on
    /// cooldown.
    private static func hasElapsed(_ last: Date?, _ interval: TimeInterval, by now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// `hasElapsed`, stamping the clock when it says yes — the check-and-claim
    /// the flash and haptic clocks both want.
    private static func take(
        _ clock: inout [String: Date],
        _ key: String,
        _ interval: TimeInterval,
        _ now: Date
    ) -> Bool {
        guard hasElapsed(clock[key], interval, by: now) else { return false }
        clock[key] = now
        return true
    }
}
