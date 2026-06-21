import Foundation
import HealthKit

/// Runs an outdoor-walk `HKWorkoutSession` for the duration of a watch-started
/// birding session. Two reasons it exists:
///
///   1. An active workout session (plus the `workout-processing` background
///      mode) keeps the app running — and the microphone live — when the wrist
///      drops or the screen turns off, which the default foreground-only
///      capture path can't do.
///   2. A birding walk is a real outdoor walk, so we save it to HealthKit on
///      stop where it counts toward the user's activity rings — the legitimate,
///      user-facing use that justifies the workout background mode.
///
/// The session is started only for the watch's own recordings (not when the
/// watch is merely mirroring a phone-mic session) and finished + saved when the
/// user stops.
@MainActor
final class WatchWorkoutManager {
    static let shared = WatchWorkoutManager()

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private init() {}

    /// Requests permission to save workouts (and read the metrics the live
    /// builder collects). Idempotent — HealthKit only shows its sheet the first
    /// time, so it's safe to call on every launch.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKQuantityType.workoutType()]
        let read: Set<HKObjectType> = [
            HKQuantityType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
        ]
        do {
            try await healthStore.requestAuthorization(toShare: share, read: read)
        } catch {
            print("Kestrel Watch: HealthKit authorization error \(error)")
        }
    }

    /// Begins an outdoor-walk workout. No-op if HealthKit is unavailable or a
    /// session is already running.
    func start() async {
        guard HKHealthStore.isHealthDataAvailable(), session == nil else { return }

        let config = HKWorkoutConfiguration()
        config.activityType = .walking
        config.locationType = .outdoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: config
            )

            self.session = session
            self.builder = builder

            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
        } catch {
            print("Kestrel Watch: workout start error \(error)")
            session = nil
            builder = nil
        }
    }

    /// Ends the workout and saves it to HealthKit. No-op if none is running.
    func stop() async {
        guard let session, let builder else { return }
        // Clear our references first so a stop/start race can't end up finishing
        // a fresh session by mistake.
        self.session = nil
        self.builder = nil

        let end = Date()
        session.end()
        do {
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        } catch {
            print("Kestrel Watch: workout finish error \(error)")
        }
    }
}
