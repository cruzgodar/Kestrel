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
    private var continuation: CheckedContinuation<CLLocation?, Never>?
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
    func currentLocation(timeout: Duration = .seconds(8)) async -> CLLocation? {
        if continuation != nil { return nil }
        switch manager.authorizationStatus {
        case .denied, .restricted, .notDetermined:
            return nil
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            return nil
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = cont
            self.manager.requestLocation()
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(with: nil)
            }
        }
    }

    private func finish(with location: CLLocation?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: location)
        }
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
