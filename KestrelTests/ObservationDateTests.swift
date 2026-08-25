import Foundation
import Testing
@testable import Kestrel

/// The UTC-midnight invariant every stored sighting holds to.
///
/// The bug these guard: dates were formatted and compared in the *device's* time
/// zone, so a sighting's day became a function of where the phone happened to be.
/// Flying somewhere with a different UTC offset moved every evening sighting onto
/// the next day, the export ledger stopped recognizing it, and the next "Export
/// New Observations" handed eBird a second copy of records it already held.
@Suite("ObservationDate")
struct ObservationDateTests {

    // MARK: canonical

    /// The core promise: whatever time of day a sighting is written at, and
    /// wherever the phone is, the stored instant is midnight UTC on the day the
    /// user's own calendar was showing.
    @Test("canonical pins any instant to midnight UTC on the local day", arguments: TestZones.all)
    func canonicalPinsToUTCMidnight(zone: TimeZone) {
        // Every hour of one local day must land on the same stored instant.
        let expected = utcDay(2026, 5, 4)
        for hour in 0..<24 {
            let local = instant(2026, 5, 4, hour, zone: zone)
            #expect(
                ObservationDate.canonical(local, in: zone) == expected,
                "\(zone.identifier) \(hour):00 should store as 2026-05-04T00:00Z"
            )
        }
    }

    /// The specific case that broke the ledger: an evening sighting east or west
    /// of UTC. In local terms it is still that day; only a local-zone formatter
    /// would call it the next one.
    @Test("late-evening and pre-dawn sightings keep their local day", arguments: TestZones.all)
    func edgeHoursKeepLocalDay(zone: TimeZone) {
        let lateEvening = instant(2026, 5, 4, 23, 59, zone: zone)
        let preDawn = instant(2026, 5, 4, 0, 1, zone: zone)
        #expect(ObservationDate.canonical(lateEvening, in: zone) == utcDay(2026, 5, 4))
        #expect(ObservationDate.canonical(preDawn, in: zone) == utcDay(2026, 5, 4))
    }

    /// Canonicalizing an already-canonical date must not move it — otherwise the
    /// value would drift a day every time it passed through. (`canonical` is not
    /// idempotent in general across zones, which is why the migration runs once;
    /// but for a date *already* at UTC midnight it has to be a no-op in any zone
    /// whose offset doesn't push it over a day boundary. The two extreme zones
    /// below are the ones where it does, and the migration's own doc calls that
    /// out.)
    @Test("canonical is a no-op on an already-canonical date, in UTC")
    func canonicalIdempotentInUTC() {
        let day = utcDay(2026, 5, 4)
        #expect(ObservationDate.canonical(day, in: TestZones.utc) == day)
    }

    /// `today` is the day the *user* is having, not the day UTC is having.
    @Test("today is the local calendar day, pinned to UTC midnight")
    func todayIsLocalDay() {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let localParts = calendar.dateComponents([.year, .month, .day], from: now)
        let expected = utcDay(localParts.year!, localParts.month!, localParts.day!)
        #expect(ObservationDate.today == expected)
    }

    // MARK: picker round trip

    /// `picker` and `canonical` are inverses. This is what makes the date wheel
    /// show the day that is actually stored: the wheel renders in local time, so
    /// a stored instant has to be converted out and back at that one boundary.
    @Test("picker and canonical round-trip in every zone", arguments: TestZones.all)
    func pickerRoundTrips(zone: TimeZone) {
        for offset in 0..<400 {
            let stored = utcDay(2026, 1, 1).addingTimeInterval(Double(offset) * 86_400)
            let onWheel = ObservationDate.picker(for: stored, in: zone)
            #expect(
                ObservationDate.canonical(onWheel, in: zone) == stored,
                "day \(offset) failed to round-trip through \(zone.identifier)"
            )
        }
    }

    /// The wheel's value must be local midnight, not the stored instant — seeding
    /// a `DatePicker` with the raw UTC value is what showed the day before or
    /// after for anyone off UTC.
    @Test("picker yields local midnight on the stored day", arguments: TestZones.all)
    func pickerIsLocalMidnight(zone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let wheel = ObservationDate.picker(for: utcDay(2026, 5, 4), in: zone)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: wheel)
        #expect(parts.year == 2026)
        #expect(parts.month == 5)
        #expect(parts.day == 4)
        #expect(parts.hour == 0)
        #expect(parts.minute == 0)
    }

    /// A new sighting opens on today, and today must be selectable under the
    /// picker's `...Date()` upper bound. If `picker(for: .today)` were ever
    /// *after* now, the wheel would open on a date it refuses to accept.
    @Test("today is never in the future on the picker's own scale", arguments: TestZones.all)
    func todayIsSelectable(zone: TimeZone) {
        let wheelValue = ObservationDate.picker(for: ObservationDate.canonical(Date(), in: zone), in: zone)
        #expect(wheelValue <= Date())
    }

    // MARK: rendering

    /// Every rendering is fixed to UTC, so the day shown is the day stored. A
    /// local-zone formatter here is the original bug in its most visible form.
    @Test("dayString prints the stored UTC day whatever the device zone is")
    func dayStringIsUTC() {
        #expect(ObservationDate.dayString(utcDay(2026, 1, 5)).contains("2026"))
        #expect(ObservationDate.dayString(utcDay(2026, 1, 5)).contains("5"))
        // A date that is a *different day* in most of the Americas.
        #expect(ObservationDate.isoDay(utcDay(2026, 1, 1)) == "2026-01-01")
    }

    @Test("isoDay renders yyyy-MM-dd in UTC")
    func isoDayFormat() {
        #expect(ObservationDate.isoDay(utcDay(2026, 5, 4)) == "2026-05-04")
        #expect(ObservationDate.isoDay(utcDay(1999, 12, 31)) == "1999-12-31")
        #expect(ObservationDate.isoDay(utcDay(2000, 2, 29)) == "2000-02-29")
    }

    @Test("eBirdDay renders MM/dd/yyyy in UTC — the format eBird's importer requires")
    func eBirdDayFormat() {
        #expect(ObservationDate.eBirdDay(utcDay(2026, 5, 4)) == "05/04/2026")
        #expect(ObservationDate.eBirdDay(utcDay(1999, 12, 31)) == "12/31/1999")
        #expect(ObservationDate.eBirdDay(utcDay(2026, 1, 1)) == "01/01/2026")
    }

    /// Zero-padding matters: eBird rejects `5/4/2026`.
    @Test("eBirdDay zero-pads single-digit months and days")
    func eBirdDayPads() {
        let rendered = ObservationDate.eBirdDay(utcDay(2026, 3, 7))
        #expect(rendered == "03/07/2026")
        #expect(rendered.count == 10)
    }

    /// The formatters are pinned to `en_US_POSIX` and the Gregorian calendar, so
    /// a device set to a Buddhist or Hebrew calendar — whose year numbers are not
    /// the ones eBird is written in — still emits Gregorian days.
    @Test("fixed formatters ignore the device's calendar and locale")
    func formattersAreLocaleIndependent() {
        // The formatters are private statics; assert through what they produce.
        // A Buddhist-calendar device would render 2026 as 2569 if the formatter
        // followed `Calendar.current`.
        #expect(!ObservationDate.isoDay(utcDay(2026, 5, 4)).hasPrefix("2569"))
        #expect(ObservationDate.isoDay(utcDay(2026, 5, 4)).hasPrefix("2026"))
    }

    // MARK: ledger-key stability across the migration

    /// The migration's central claim: rewriting a stored date to midnight UTC on
    /// the day it *currently reads as locally* leaves the export ledger's keys
    /// unchanged. Old keys were the local day of the old date; new keys are the
    /// UTC day of the new one — and those are the same string, so nothing already
    /// uploaded to eBird looks new again.
    @Test("migrating a date preserves its ledger day string", arguments: TestZones.all)
    func migrationPreservesLedgerDay(zone: TimeZone) {
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.calendar = Calendar(identifier: .gregorian)
        localFormatter.timeZone = zone
        localFormatter.dateFormat = "yyyy-MM-dd"

        for hour in [0, 1, 9, 12, 18, 23] {
            let legacy = instant(2019, 5, 4, hour, zone: zone)
            let keyBefore = localFormatter.string(from: legacy)          // old scheme
            let migrated = ObservationDate.canonical(legacy, in: zone)
            let keyAfter = ObservationDate.isoDay(migrated)              // new scheme
            #expect(keyBefore == keyAfter, "\(zone.identifier) @\(hour):00 changed its ledger key")
        }
    }

    /// Ordering has to survive the migration too, or an entry's earliest sighting
    /// could stop being its earliest and the displayed first-seen fields would
    /// need re-promoting (which the migration deliberately doesn't do).
    @Test("migration is monotonic in day order", arguments: TestZones.all)
    func migrationPreservesOrder(zone: TimeZone) {
        let earlier = instant(2019, 5, 4, 23, zone: zone)
        let later = instant(2019, 5, 5, 1, zone: zone)
        #expect(earlier < later)
        #expect(ObservationDate.canonical(earlier, in: zone) < ObservationDate.canonical(later, in: zone))
    }
}
