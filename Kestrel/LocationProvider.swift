import CoreLocation
import Foundation

/// One-shot async wrapper around `CLLocationManager`. Returns the current
/// device location, or `nil` if permission is denied / fix times out / errors.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Returns a single `CLLocation` fix, or `nil` on denial/timeout/error.
    func currentLocation(timeout: Duration = .seconds(5)) async -> CLLocation? {
        // If we already have a pending request, don't start another one.
        if continuation != nil { return nil }

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

        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = cont
            self.manager.requestLocation()
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.finish(with: nil)
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

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.finish(with: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("LocationProvider: error \(error)")
        Task { @MainActor in self.finish(with: nil) }
    }
}

/// Process-wide latest known coordinate. Updated whenever any code path
/// resolves a fresh fix (currently `RecordingManager.refreshSpeciesFilter`
/// and the Map tab's first-appear), and read by the life-list add callsites
/// so manually-added species pick up "where am I right now" without waiting
/// for a new GPS lock.
@MainActor
final class LocationCache {
    static let shared = LocationCache()

    private(set) var lastLatitude: Double?
    private(set) var lastLongitude: Double?
    private let provider = LocationProvider()
    private var inflight: Task<(Double, Double)?, Never>?

    private init() {}

    func update(latitude: Double, longitude: Double) {
        lastLatitude = latitude
        lastLongitude = longitude
    }

    /// Returns a coordinate, requesting a fresh fix if we don't already
    /// have one cached. `nil` if permission was denied or the request
    /// timed out.
    func current() async -> (latitude: Double, longitude: Double)? {
        if let lat = lastLatitude, let lon = lastLongitude {
            return (lat, lon)
        }
        if let inflight { return await inflight.value }
        let task = Task<(Double, Double)?, Never> { [provider] in
            guard let loc = await provider.currentLocation() else { return nil }
            return (loc.coordinate.latitude, loc.coordinate.longitude)
        }
        inflight = task
        let result = await task.value
        inflight = nil
        if let result {
            lastLatitude = result.0
            lastLongitude = result.1
        }
        return result
    }
}
