import Foundation

/// The single place a *sighting's* date is converted between a stored instant, a
/// picker, and text.
///
/// **The invariant.** Every `LifeListEntry.Observation.date` — and the
/// `firstSeen` promoted out of one — is midnight **UTC** on the day the bird was
/// seen. Nothing about a sighting is finer-grained than a day: the picker offers
/// days, eBird's CSV carries days, the export ledger keys on days, and every
/// place the app prints one prints a day. Pinning the stored instant to UTC
/// midnight is what makes that day the same day everywhere.
///
/// **Why.** The local-timezone formatters this replaces made a sighting's day a
/// function of where the phone happened to be. The export ledger keyed each
/// sighting on its local calendar day, so flying somewhere with a different UTC
/// offset moved every evening sighting onto the next day, the ledger no longer
/// recognized it, and the next "Export New Observations" handed eBird a second
/// copy of records it already held — which eBird, doing no deduplication of its
/// own, keeps. The same drift showed up quietly in the list, on the map cards,
/// and in the exported CSV's own Date column.
///
/// **The two conversions.** The date *picker* deliberately still works in the
/// device's time zone, because the day a person means is the day on their own
/// calendar; only the stored value is canonical. `canonical(_:)` maps a locally
/// chosen day onto midnight UTC, and `picker(for:)` maps it back. They are
/// inverses of each other but **neither is idempotent**, so a date is converted
/// exactly once at each boundary — see the one-shot migration in
/// `LifeListStore.load()`.
nonisolated enum ObservationDate {
    static let utc = TimeZone(secondsFromGMT: 0)!

    /// A Gregorian calendar in `zone`. Built per call rather than cached for two
    /// reasons: the device's time zone changes when the user travels, which is
    /// the whole scenario this file exists for, and `Calendar.current` follows
    /// the user's *calendar identifier* (Buddhist, Hebrew, …), whose day numbers
    /// aren't the ones eBird and the manifest are written in.
    private static func gregorian(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// Midnight UTC on the calendar day `date` falls on **in `zone`** (the
    /// device's own by default). The write-side conversion: what the date picker
    /// hands back, what a freshly-started draft opens on, and what the one-shot
    /// migration runs over rows written before this invariant existed.
    static func canonical(_ date: Date, in zone: TimeZone = .current) -> Date {
        let parts = gregorian(in: zone).dateComponents([.year, .month, .day], from: date)
        return gregorian(in: utc).date(from: parts) ?? date
    }

    /// Midnight UTC on today's date, as the device reckons "today". What a new
    /// sighting's draft opens on — `Date()` would carry a wall-clock time that
    /// lands on the wrong UTC day for anyone far enough east or west of it.
    static var today: Date { canonical(Date()) }

    /// The inverse of `canonical(_:)`: local midnight on the UTC day `date`
    /// names. The read-side conversion, used to seed a `DatePicker` — which
    /// renders in the device's time zone — so the wheel shows the stored day
    /// rather than the one before or after it.
    static func picker(for date: Date, in zone: TimeZone = .current) -> Date {
        let parts = gregorian(in: utc).dateComponents([.year, .month, .day], from: date)
        return gregorian(in: zone).date(from: parts) ?? date
    }

    // MARK: - Rendering

    /// The app's standard on-screen sighting date, e.g. "Jan 5, 2026". Localized
    /// (month names and field order follow the user's locale) but fixed to UTC,
    /// so the day shown is the day stored. Every list, card, and panel that
    /// prints a sighting's date uses this one style.
    static let dayStyle: Date.FormatStyle = {
        var style = Date.FormatStyle.dateTime.year().month(.abbreviated).day()
        style.timeZone = utc
        return style
    }()

    /// `dayStyle` as a plain string, for the places that can't take a `Text` —
    /// an alert's message, an accessibility label.
    static func dayString(_ date: Date) -> String {
        date.formatted(dayStyle)
    }

    /// `yyyy-MM-dd` in UTC — the day component of the export ledger's key.
    ///
    /// Ledger keys written before the UTC invariant landed stay valid: they were
    /// the *local* day of a date that the migration then rewrote to midnight UTC
    /// on that same local day, so this renders the identical string. Nothing has
    /// to be re-keyed, and nothing already sent to eBird looks new again.
    static func isoDay(_ date: Date) -> String {
        isoDayFormatter.string(from: date)
    }

    /// `MM/dd/yyyy` in UTC — the format eBird's Record Format requires in its
    /// Date column.
    static func eBirdDay(_ date: Date) -> String {
        eBirdDayFormatter.string(from: date)
    }

    /// Fixed-format formatters: `en_US_POSIX` so a device set to a non-Gregorian
    /// calendar or a different region can't emit anything else, and UTC so they
    /// agree with the stored instant.
    private static func fixedFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = utc
        f.dateFormat = format
        return f
    }

    private static let isoDayFormatter = fixedFormatter("yyyy-MM-dd")
    private static let eBirdDayFormatter = fixedFormatter("MM/dd/yyyy")
}
