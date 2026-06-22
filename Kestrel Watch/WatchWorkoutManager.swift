import Foundation
import HealthKit

/// Runs a walking `HKWorkoutSession`, branded "Birding", for the duration of a
/// watch-started birding session. Two reasons it exists:
///
///   1. An active workout session (plus the `workout-processing` background
///      mode) keeps the app running — and the microphone live — when the wrist
///      drops or the screen turns off, which the default foreground-only
///      capture path can't do.
///   2. A birding walk is a real outdoor walk, so we save it to HealthKit on
///      stop where it counts toward the user's activity rings — the legitimate,
///      user-facing use that justifies the workout background mode.
///
/// The optical heart-rate sensor is deliberately left off (we never request HR
/// authorization and disable its collection on the live builder) — birding
/// doesn't need it and the green LEDs are a battery + wrist-comfort cost.
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
    /// When the current workout began, so `stop()` can discard walks shorter
    /// than `minimumDuration` rather than logging a trivially short workout.
    private var startDate: Date?
    /// Birding walks under a minute aren't worth saving to HealthKit — they're
    /// usually an accidental start/stop, not a real walk.
    private let minimumDuration: TimeInterval = 60

    private init() {}

    /// Requests permission to save workouts (and read the metrics the live
    /// builder collects). Idempotent — HealthKit only shows its sheet the first
    /// time, so it's safe to call on every launch.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKQuantityType.workoutType()]
        // No heart rate — we never use the optical HR sensor during a birding
        // walk, so we don't ask for it (keeping it out of the permission sheet).
        let read: Set<HKObjectType> = [
            HKQuantityType.workoutType(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
        ]
        do {
            try await healthStore.requestAuthorization(toShare: share, read: read)
        } catch {
            print("Kestrel Watch: HealthKit authorization error \(error)")
        }
    }

    /// Begins a walking workout branded "Birding". No-op if HealthKit is
    /// unavailable or a session is already running.
    func start() async {
        guard HKHealthStore.isHealthDataAvailable(), session == nil else { return }

        let config = HKWorkoutConfiguration()
        config.activityType = .walking
        config.locationType = .outdoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            let dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: config
            )
            // Never collect heart rate — keep the optical sensor off for the
            // whole walk. The live data source enables HR by default for a
            // walking workout, so we explicitly disable it.
            dataSource.disableCollection(for: HKQuantityType(.heartRate))
            builder.dataSource = dataSource

            self.session = session
            self.builder = builder

            let start = Date()
            self.startDate = start
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            // Brand the workout "Birding" so it shows up under that name in the
            // Fitness app instead of the generic "Outdoor Walk".
            try await builder.addMetadata([HKMetadataKeyWorkoutBrandName: "Birding"])
        } catch {
            print("Kestrel Watch: workout start error \(error)")
            session = nil
            builder = nil
            startDate = nil
        }
    }

    /// Ends the workout. Saves it to HealthKit only if it ran for at least
    /// `minimumDuration`; shorter walks are discarded so a quick start/stop
    /// doesn't litter the user's activity history. No-op if none is running.
    func stop() async {
        guard let session, let builder else { return }
        // Clear our references first so a stop/start race can't end up finishing
        // a fresh session by mistake.
        self.session = nil
        self.builder = nil
        let started = startDate
        self.startDate = nil

        let end = Date()
        session.end()

        // Too short to be a real birding walk — end collection and throw the
        // workout away rather than saving it.
        if let started, end.timeIntervalSince(started) < minimumDuration {
            do {
                try await builder.endCollection(at: end)
                builder.discardWorkout()
            } catch {
                print("Kestrel Watch: workout discard error \(error)")
            }
            return
        }

        do {
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        } catch {
            print("Kestrel Watch: workout finish error \(error)")
        }
    }
}
