import CoreLocation
import Foundation

/// Decides whether the wearer is in a car, so a birding walk doesn't log the
/// drive between spots as miles walked.
///
/// The workout is an outdoor walk, and HealthKit's live data source happily
/// turns GPS movement at 60 mph into walking distance (and the active energy it
/// estimates from that pace). `WatchWorkoutManager` listens to `onChange` and
/// stops collecting both while this says the wearer is driving.
///
/// Two kinds of evidence, either of which counts:
///
///   - **Speed.** Two fixes in a row, each confidently faster than anyone walks
///     or runs (see `isFast`). Two, not one, so a single wild fix can't throw
///     away minutes of real walking.
///   - **CarPlay.** The watch can't see CarPlay; the phone can, and reports it on
///     every heartbeat (see `RecordingManager.sendPhoneHeartbeat`). A report of
///     "connected" counts as evidence the moment it lands — which also covers the
///     stop-and-go traffic the speed check would miss.
///
/// Driving then holds for `hold` after the last piece of evidence, so a red
/// light or a crawl through a parking lot doesn't hand the distance back. The
/// cost is the first couple of minutes of walking after parking, which is the
/// right side to err on: a walk a little short beats a walk with a highway in it.
@MainActor
final class WatchDrivingDetector: NSObject, CLLocationManagerDelegate {
    static let shared = WatchDrivingDetector()

    /// Faster than this is not on foot. ~18 mph — well above a sprint, below any
    /// road worth worrying about.
    nonisolated static let drivingSpeed: CLLocationSpeed = 8
    /// How long driving outlasts its last piece of evidence.
    nonisolated static let hold: TimeInterval = 120

    /// Called on the main actor whenever `isDriving` flips.
    var onChange: ((Bool) -> Void)?
    private(set) var isDriving = false

    private let manager = CLLocationManager()
    private var isRunning = false
    /// The latest moment we had evidence of driving.
    private var lastEvidenceAt: Date?
    /// Consecutive fast fixes; two make evidence.
    private var fastStreak = 0
    /// Re-evaluates once `hold` has run out, in case no fix arrives to do it —
    /// the watch can go quiet on location updates while standing still.
    private var expiryTask: Task<Void, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.activityType = .fitness
    }

    /// Starts watching speed. Called when a workout comes up; the active workout
    /// session is what keeps these updates flowing with the wrist down.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        reset()
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            // No location — CarPlay reports still work. Picked up below if the
            // user grants it mid-walk.
            break
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopUpdatingLocation()
        reset()
    }

    private func reset() {
        lastEvidenceAt = nil
        fastStreak = 0
        expiryTask?.cancel()
        expiryTask = nil
        isDriving = false
    }

    /// The phone's CarPlay state, from its heartbeat.
    func handleCarPlay(connected: Bool) {
        guard isRunning, connected else { return }
        addEvidence(at: Date())
    }

    /// Whether one fix is confidently faster than walking pace. Invalid speeds
    /// (negative) and imprecise fixes don't count either way.
    nonisolated static func isFast(
        speed: CLLocationSpeed,
        speedAccuracy: CLLocationSpeedAccuracy,
        horizontalAccuracy: CLLocationAccuracy
    ) -> Bool {
        guard speed >= 0, speedAccuracy >= 0, horizontalAccuracy >= 0, horizontalAccuracy <= 50 else {
            return false
        }
        return speed - speedAccuracy > drivingSpeed
    }

    /// Whether the wearer is still driving, given the last evidence of it.
    nonisolated static func isDriving(lastEvidenceAt: Date?, now: Date) -> Bool {
        guard let lastEvidenceAt else { return false }
        return now.timeIntervalSince(lastEvidenceAt) < hold
    }

    private func observe(_ fix: CLLocation) {
        guard isRunning else { return }
        if Self.isFast(
            speed: fix.speed,
            speedAccuracy: fix.speedAccuracy,
            horizontalAccuracy: fix.horizontalAccuracy
        ) {
            fastStreak += 1
            if fastStreak >= 2 { addEvidence(at: fix.timestamp) }
        } else {
            fastStreak = 0
            reevaluate()
        }
    }

    private func addEvidence(at date: Date) {
        lastEvidenceAt = max(lastEvidenceAt ?? date, date)
        reevaluate()
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.hold + 1))
            guard !Task.isCancelled else { return }
            self?.reevaluate()
        }
    }

    private func reevaluate() {
        let driving = Self.isDriving(lastEvidenceAt: lastEvidenceAt, now: Date())
        guard driving != isDriving else { return }
        isDriving = driving
        Log.warning(driving ? "Driving detected — pausing walk distance" : "Driving over — resuming walk distance")
        onChange?(driving)
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for fix in locations { self.observe(fix) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.error("WatchDrivingDetector: \(error)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.isRunning else { return }
            switch self.manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.startUpdatingLocation()
            default: break
            }
        }
    }
}
