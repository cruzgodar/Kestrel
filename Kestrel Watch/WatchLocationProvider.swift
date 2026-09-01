import CoreLocation
import Foundation

/// One-shot async wrapper around `CLLocationManager` for the watch. The watch now
/// supplies its *own* coordinate to the phone with the start handshake so a
/// watch-first user (who may never have opened the iPhone app) can still get a
/// nearby-species filter — the phone runs BirdNET but no longer needs its own
/// location. Mirrors the phone's `LocationProvider`, trimmed to what the watch
/// needs: request authorization, and return a single fix.
@MainActor
final class WatchLocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = WatchLocationProvider()

    private let manager = CLLocationManager()
    /// Everyone waiting on the current fix.
    ///
    /// A list, not a single slot — the same fix the phone's `LocationProvider`
    /// carries, and for the same reason. A second caller arriving while a fix was
    /// in flight used to be answered `nil` outright, which reads as "there is no
    /// location" and is acted on as such: `resolveLocationAndNotifications` would
    /// simply never send `watchLocation`, and the phone would build its
    /// nearby-species filter from its own location — which for a watch-first user
    /// is nowhere at all. Reachable by stopping and restarting a session inside
    /// the eight-second fix window. Callers now join the fix in flight and all get
    /// the same answer.
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var timeoutTask: Task<Void, Never>?
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        super.init()
        manager.delegate = self
        // The species filter is coarse (BirdNET buckets by ~half-degree grid), so
        // a rough fix is plenty — and cheaper on the watch's battery + faster to
        // acquire than a precise one.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// True once the user has explicitly *denied* (or restricted) location — the
    /// record button locks in that case, since the watch can't build a useful
    /// nearby list without a coordinate. Undetermined does not lock (the first
    /// start prompts).
    var isDenied: Bool {
        let s = manager.authorizationStatus
        return s == .denied || s == .restricted
    }

    /// Prompts for when-in-use access if still undetermined, awaiting the choice.
    @discardableResult
    func requestAuthorization() async -> CLAuthorizationStatus {
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return status }
        guard authContinuation == nil else { return status }
        return await withCheckedContinuation { (cont: CheckedContinuation<CLAuthorizationStatus, Never>) in
            self.authContinuation = cont
            self.manager.requestWhenInUseAuthorization()
        }
    }

    /// Returns a single `CLLocation` fix, or `nil` on denial / timeout / error.
    ///
    /// Concurrent callers share one request: the first starts it, the rest wait
    /// on the same answer. See `waiters`.
    func currentLocation(timeout: Duration = .seconds(8)) async -> CLLocation? {
        switch manager.authorizationStatus {
        case .denied, .restricted, .notDetermined:
            return nil
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            return nil
        }

        // Read before the append below, with no suspension in between: a
        // non-empty list means someone else already asked and we only have to
        // wait for the answer.
        let startsRequest = Self.startsNewRequest(pendingWaiters: waiters.count)
        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            self.waiters.append(cont)
            guard startsRequest else { return }
            self.manager.requestLocation()
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(with: nil)
            }
        }
    }

    /// Whether a caller has to start a fix of its own, or can simply wait on one
    /// already in flight.
    ///
    /// Trivial, and extracted anyway: the thing that was wrong here was not the
    /// arithmetic but the *answer given to the second caller*, which was `nil`
    /// rather than a place in the queue. Stated as a function so narrowing it
    /// back to "one caller at a time" is a change a test objects to. The phone's
    /// `LocationProvider` carries the same shape.
    nonisolated static func startsNewRequest(pendingWaiters: Int) -> Bool {
        pendingWaiters == 0
    }

    /// Hands `location` to everyone waiting and clears the list. Safe to call
    /// more than once for one request — a fix that arrives just as the timeout
    /// fires finds no waiters left and does nothing.
    private func finish(with location: CLLocation?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard !waiters.isEmpty else { return }
        // Cancel any fix still outstanding. `requestLocation()` delivers exactly
        // one callback and that callback carries no idea of *which* request it
        // belongs to — so a request we gave up on goes on running and answers
        // whatever batch of waiters exists when it finally lands. Concretely: a
        // fix that times out resolves everyone `nil`, a fresh caller arrives and
        // starts a new request, and the abandoned one's callback then resolves
        // *that* caller with a coordinate resolved for the previous one.
        // `stopUpdatingLocation()` is the documented cancel for a pending
        // `requestLocation()`; on the paths where the fix already arrived it is
        // simply a no-op.
        manager.stopUpdatingLocation()
        let pending = waiters
        waiters.removeAll()
        for cont in pending { cont.resume(returning: location) }
    }

    private func finishAuth(with status: CLAuthorizationStatus) {
        if let cont = authContinuation {
            authContinuation = nil
            cont.resume(returning: status)
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.finish(with: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.error("WatchLocationProvider: \(error)")
        Task { @MainActor in self.finish(with: nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = self.manager.authorizationStatus
            guard status != .notDetermined else { return }
            self.finishAuth(with: status)
        }
    }
}
