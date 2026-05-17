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
