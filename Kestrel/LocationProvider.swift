import CoreLocation
import Foundation

/// One-shot async wrapper around `CLLocationManager`. Returns the current
/// device location, or `nil` if permission is denied / fix times out / errors.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    /// Everyone waiting on the current fix.
    ///
    /// A list, not a single slot. It used to be one continuation, and a second
    /// caller arriving while a fix was in flight was answered `nil` outright —
    /// which reads as "there is no location" and is acted on as such. That is
    /// how a redundant `RecordingManager.refreshSpeciesFilter` could drop the
    /// nearby-species filter for a whole session: it asked while another refresh
    /// was already asking, was told there was no fix, and wrote its "showing all
    /// species" answer over the real one. Callers now join the fix in flight and
    /// all get the same answer.
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// The current location authorization status, read straight off the manager.
    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// Called on every authorization change (including the initial callback), so
    /// observers — e.g. `RecordingManager`, which grays the record button and
    /// tells the watch — can react to the user granting/denying access in Settings
    /// or at the prompt without polling.
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    /// Returns the authorization status, prompting once and awaiting the user's
    /// choice if it's still undetermined. Used to gate recording on location
    /// access — the nearby-species filter can't be built without it.
    func requestAuthorization() async -> CLAuthorizationStatus {
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return status }
        // Only one prompt can be outstanding; if one already is, report the
        // current (still-undetermined) status rather than stacking continuations.
        guard authContinuation == nil else { return status }
        return await withCheckedContinuation { (cont: CheckedContinuation<CLAuthorizationStatus, Never>) in
            self.authContinuation = cont
            self.manager.requestWhenInUseAuthorization()
        }
    }

    private func finishAuth(with status: CLAuthorizationStatus) {
        if let cont = authContinuation {
            authContinuation = nil
            cont.resume(returning: status)
        }
    }

    /// Returns a single `CLLocation` fix, or `nil` on denial/timeout/error.
    ///
    /// Concurrent callers share one request: the first starts it, the rest wait
    /// on the same answer. See `waiters`.
    func currentLocation(timeout: Duration = .seconds(5)) async -> CLLocation? {
        // Bail out early if we know permission is denied.
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return nil
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // Give the system a beat to deliver the permission result, then check again.
            try? await Task.sleep(for: .milliseconds(300))
            if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                return nil
            }
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            return nil
        }

        // Read before the append below, with no suspension in between: a
        // non-empty list means someone else already asked and we only have to
        // wait for the answer.
        let alreadyRequesting = !waiters.isEmpty
        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            self.waiters.append(cont)
            guard !alreadyRequesting else { return }
            self.manager.requestLocation()
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(with: nil)
            }
        }
    }

    /// Hands `location` to everyone waiting and clears the list. Safe to call
    /// more than once for one request — a fix that arrives just as the timeout
    /// fires finds no waiters left and does nothing.
    private func finish(with location: CLLocation?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard !waiters.isEmpty else { return }
        let pending = waiters
        waiters.removeAll()
        for cont in pending { cont.resume(returning: location) }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.finish(with: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.error("LocationProvider: \(error)")
        Task { @MainActor in self.finish(with: nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = self.manager.authorizationStatus
            // Notify observers of every transition (including the initial
            // notDetermined callback) so UI gating stays current.
            self.onAuthorizationChange?(status)
            // Ignore the initial callback that fires before the user has chosen;
            // resume only once the prompt resolves to a concrete status.
            guard status != .notDetermined else { return }
            self.finishAuth(with: status)
        }
    }
}

/// Process-wide latest known coordinate. Updated whenever any code path
/// resolves a fresh fix (currently `RecordingManager.refreshSpeciesFilter`
/// and the Map tab's first-appear), and read by the callsites that need
/// "where am I right now" without waiting on a fresh GPS lock.
@MainActor
final class LocationCache {
    static let shared = LocationCache()

    /// How long a fix is treated as *current*.
    ///
    /// This is not a memory cap, it is the correctness bound on the word
    /// "current". The cache used to have none: it kept the first fix of the
    /// process forever, refreshed only by a session start or an app foreground.
    /// Everything that asks this class "where am I now" therefore answered with
    /// where the user was when the session began — the map's recenter button
    /// flew back to the trailhead, and, worse, the observation flow's map picker
    /// seeded its pin (and `committableCoordinate`, which is what Save writes)
    /// at the same stale spot. A bird logged an hour into a walk went onto the
    /// life list a mile from where it was heard.
    ///
    /// A minute is short enough that no pin lands a walk away and long enough
    /// that the launch warm-up, an immediate map open, and an add a few taps
    /// later all share one fix.
    static let freshness: TimeInterval = 60

    /// The last coordinate resolved, *however old*. Deliberately not bounded by
    /// `freshness`: its one reader is `RecordingManager`'s offline
    /// species-filter fallback, which wants "the last place we know of" — a
    /// coarse regional list from an hour ago beats no list at all.
    private(set) var lastLatitude: Double?
    private(set) var lastLongitude: Double?
    /// When `lastLatitude` / `lastLongitude` were written, so `current()` can
    /// tell a fix that still describes where the user is from one that doesn't.
    private(set) var lastFixAt: Date?

    /// Resolves a fresh fix. Injected so a test can drive the freshness policy
    /// without CoreLocation — `shared` wires it to a real `LocationProvider`.
    private let fetch: @MainActor () async -> (latitude: Double, longitude: Double)?
    private var inflight: Task<(Double, Double)?, Never>?

    /// - Parameter fetch: `nil` (the default) means a real `LocationProvider`.
    init(fetch: (@MainActor () async -> (latitude: Double, longitude: Double)?)? = nil) {
        if let fetch {
            self.fetch = fetch
        } else {
            let provider = LocationProvider()
            self.fetch = {
                guard let loc = await provider.currentLocation() else { return nil }
                return (loc.coordinate.latitude, loc.coordinate.longitude)
            }
        }
    }

    func update(latitude: Double, longitude: Double, at now: Date = Date()) {
        lastLatitude = latitude
        lastLongitude = longitude
        lastFixAt = now
    }

    /// Whether the cached coordinate is recent enough to stand for "here, now".
    func isFresh(at now: Date = Date()) -> Bool {
        guard let lastFixAt else { return false }
        return now.timeIntervalSince(lastFixAt) < Self.freshness
    }

    /// Returns where the user is now: the cached coordinate while it is still
    /// fresh, otherwise a newly resolved fix.
    ///
    /// A failed refresh falls back to the stale coordinate rather than returning
    /// `nil` — offline, or with the fix timing out, a coordinate from earlier in
    /// the walk is still the best answer available, and it is what the recenter
    /// button and the picker's default pin had before. `nil` means we have never
    /// had a fix at all.
    ///
    /// **The fallback belongs to every caller, not just the one that started the
    /// fix.** A second caller arriving while a fix is in flight joins it rather
    /// than starting a second, and that join used to hand back the task's raw
    /// `nil` — so which of two callers got the stale coordinate came down to
    /// which of them asked first. Concretely: opening the Map tab starts a
    /// warm-up fix, and a recenter tap a moment later joins it; a fix that then
    /// timed out left the button doing nothing at all while a perfectly usable
    /// coordinate sat in the cache. Both paths coalesce to the same answer here.
    func current(now: Date = Date()) async -> (latitude: Double, longitude: Double)? {
        if let cached = cachedCoordinate, isFresh(at: now) { return cached }
        if let inflight { return await inflight.value ?? cachedCoordinate }
        let task = Task<(Double, Double)?, Never> { [fetch] in
            guard let fix = await fetch() else { return nil }
            return (fix.latitude, fix.longitude)
        }
        inflight = task
        let result = await task.value
        inflight = nil
        guard let result else { return cachedCoordinate }
        update(latitude: result.0, longitude: result.1, at: now)
        return (result.0, result.1)
    }

    private var cachedCoordinate: (latitude: Double, longitude: Double)? {
        guard let lastLatitude, let lastLongitude else { return nil }
        return (lastLatitude, lastLongitude)
    }
}
