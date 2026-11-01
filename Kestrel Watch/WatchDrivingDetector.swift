import CoreLocation
import Foundation

/// Notices the wearer getting into a car, so a birding walk ends where the
/// walking did instead of logging the drive home as miles walked.
///
/// The workout is an outdoor walk, and HealthKit's live data source happily
/// turns GPS movement at 60 mph into walking distance. Rather than trying to
/// carve the drive out of a running workout, the first sign of driving ends the
/// birding session and saves the walk outright — `onDetect` hands that to
/// `WatchSessionManager.handleDrivingDetected`. One-shot: the detector stops
/// itself once it fires.
///
/// Two kinds of evidence, either of which counts:
///
///   - **Speed.** Three fixes in a row, each confidently faster than anyone
///     walks or runs (see `isFast`). A fix with no speed of its own — common when
///     the watch is leaning on the phone's GPS — is judged by how far it is from
///     a fix at least `derivedSpeedWindow` earlier instead.
///   - **CarPlay.** The watch can't see CarPlay; the phone can, and reports it on
///     every heartbeat (see `RecordingManager.sendPhoneHeartbeat`). Only a
///     *connection during the walk* counts — "connected" after a report of
///     "disconnected" — so starting a session from the driver's seat before
///     getting out doesn't end it on the first beat.
@MainActor
final class WatchDrivingDetector: NSObject, CLLocationManagerDelegate {
    static let shared = WatchDrivingDetector()

    /// Faster than this is not on foot. ~18 mph — well above a sprint, below any
    /// road worth worrying about.
    nonisolated static let drivingSpeed: CLLocationSpeed = 8
    /// Fixes less precise than this say nothing either way.
    nonisolated static let maxHorizontalAccuracy: CLLocationAccuracy = 100
    /// Consecutive fast fixes that make driving.
    nonisolated static let requiredStreak = 3
    /// The shortest gap a speed is derived over when a fix carries none. Long
    /// enough that position error can't pass for motion.
    nonisolated static let derivedSpeedWindow: TimeInterval = 10

    enum Evidence {
        case speed
        case carPlay
    }

    /// Called on the main actor the first time driving is detected, with the
    /// moment the drive began — the first fast fix, or the CarPlay report.
    var onDetect: ((Evidence, Date) -> Void)?

    private let manager = CLLocationManager()
    private var isRunning = false
    /// When this walk's detection began. Fixes from before it are cached from
    /// earlier — possibly from the car the wearer just got out of.
    private var startedAt = Date.distantPast
    /// Recent usable fixes, for deriving a speed when a fix carries none.
    private var recentFixes: [CLLocation] = []
    /// The fixes in the current run of fast ones.
    private var fastStreak: [CLLocation] = []
    /// Whether the phone has reported CarPlay disconnected during this walk, so a
    /// later "connected" is a fresh connection rather than one we started in.
    private var sawCarPlayDisconnected = false
    private var loggedFirstFix = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.activityType = .fitness
    }

    /// Starts watching. Called when a workout comes up; the active workout
    /// session is what keeps these updates flowing with the wrist down.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        reset()
        startedAt = Date()
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            // No location — CarPlay reports still work. Picked up below if the
            // user grants it mid-walk.
            Log.warning("WatchDrivingDetector: no location access — CarPlay only")
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopUpdatingLocation()
        reset()
    }

    private func reset() {
        recentFixes = []
        fastStreak = []
        sawCarPlayDisconnected = false
        loggedFirstFix = false
    }

    /// The phone's CarPlay state, from its heartbeat.
    func handleCarPlay(connected: Bool) {
        guard isRunning else { return }
        guard connected else {
            sawCarPlayDisconnected = true
            return
        }
        guard sawCarPlayDisconnected else { return }
        detect(.carPlay, at: Date())
    }

    /// Whether one fix is confidently faster than walking pace, from its own
    /// speed. Nil when the fix has no usable speed and has to be judged by
    /// distance instead; imprecise fixes are never fast.
    ///
    /// A fix that reports its speed's accuracy has to be fast even at the bottom
    /// of that error bar. One that doesn't (`speedAccuracy` negative) is taken at
    /// its word — the streak is what guards against a single wild reading.
    nonisolated static func isFast(
        speed: CLLocationSpeed,
        speedAccuracy: CLLocationSpeedAccuracy,
        horizontalAccuracy: CLLocationAccuracy
    ) -> Bool? {
        guard horizontalAccuracy >= 0, horizontalAccuracy <= maxHorizontalAccuracy else { return false }
        guard speed >= 0 else { return nil }
        let floor = speedAccuracy >= 0 ? speed - speedAccuracy : speed
        return floor > drivingSpeed
    }

    /// Whether the trip between two fixes was confidently faster than walking:
    /// even if both were off by their full accuracy toward each other.
    nonisolated static func isFast(
        distance: CLLocationDistance,
        interval: TimeInterval,
        accuracies: (CLLocationAccuracy, CLLocationAccuracy)
    ) -> Bool {
        guard interval >= derivedSpeedWindow else { return false }
        return (distance - accuracies.0 - accuracies.1) / interval > drivingSpeed
    }

    private func observe(_ fix: CLLocation) {
        guard isRunning, fix.timestamp >= startedAt else { return }
        if !loggedFirstFix {
            loggedFirstFix = true
            Log.warning(
                "WatchDrivingDetector: first fix — speed \(fix.speed) ±\(fix.speedAccuracy), "
                + "accuracy \(fix.horizontalAccuracy)"
            )
        }

        let fast = Self.isFast(
            speed: fix.speed,
            speedAccuracy: fix.speedAccuracy,
            horizontalAccuracy: fix.horizontalAccuracy
        ) ?? derivedIsFast(fix)

        if fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= Self.maxHorizontalAccuracy {
            recentFixes.append(fix)
            recentFixes.removeAll { fix.timestamp.timeIntervalSince($0.timestamp) > Self.derivedSpeedWindow * 3 }
        }

        guard fast else {
            fastStreak = []
            return
        }
        fastStreak.append(fix)
        if fastStreak.count >= Self.requiredStreak, let first = fastStreak.first {
            detect(.speed, at: first.timestamp)
        }
    }

    /// Judges a fix with no speed of its own against the latest fix at least
    /// `derivedSpeedWindow` before it.
    private func derivedIsFast(_ fix: CLLocation) -> Bool {
        guard let anchor = recentFixes.last(where: {
            fix.timestamp.timeIntervalSince($0.timestamp) >= Self.derivedSpeedWindow
        }) else { return false }
        return Self.isFast(
            distance: fix.distance(from: anchor),
            interval: fix.timestamp.timeIntervalSince(anchor.timestamp),
            accuracies: (fix.horizontalAccuracy, anchor.horizontalAccuracy)
        )
    }

    private func detect(_ evidence: Evidence, at date: Date) {
        guard isRunning else { return }
        Log.warning("Driving detected (\(evidence)) — ending the walk")
        let onDetect = self.onDetect
        stop()
        onDetect?(evidence, max(date, startedAt))
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
