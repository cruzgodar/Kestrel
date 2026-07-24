import Foundation
import HealthKit
import SwiftUI

/// Runs a walking `HKWorkoutSession`, branded "Birding", for the duration of a
/// watch-started birding session. Two reasons it exists:
///
///   1. An active workout session (plus the `workout-processing` background
///      mode) keeps the app running — and the microphone live — when the wrist
///      drops or the screen turns off, which the default foreground-only
///      capture path can't do.
///   2. A birding walk is a real outdoor walk, so we offer to save it to
///      HealthKit where it counts toward the user's activity rings — the
///      legitimate, user-facing use that justifies the workout background mode.
///
/// **Saving is deferred and opt-in.** The extra runtime comes purely from the
/// session being in the `.running` state; `finishWorkout()` only ever happens
/// *after* `session.end()`, by which point the runtime benefit has already been
/// collected. So holding the finished builder until the user says "save" costs
/// nothing, and it stops an unattended session teardown (a watchdog giving up,
/// a crash-relaunch) from silently logging a workout — which Apple broadcasts
/// to the user's activity-sharing friends. See `end()` / `save()` / `discard()`.
///
/// The optical heart-rate sensor is deliberately left off (we never request HR
/// authorization and disable its collection on the live builder) — birding
/// doesn't need it and the green LEDs are a battery + wrist-comfort cost.
///
/// The session is started only for the watch's own recordings (not when the
/// watch is merely mirroring a phone-mic session).
@MainActor
@Observable
final class WatchWorkoutManager: NSObject, HKWorkoutSessionDelegate {
    static let shared = WatchWorkoutManager()

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    /// When the current workout began, so `end()` can discard walks shorter
    /// than `minimumDuration` rather than offering to log a trivially short one.
    private var startDate: Date?
    /// Birding walks this short aren't worth saving to HealthKit — they're
    /// usually an accidental start/stop, not a real walk.
    private let minimumDuration: TimeInterval = 15

    /// A walk waiting on the user's decision. Non-nil only between
    /// `pause()`/`end()` and `save()`/`discard()`/`resume()`; the view observes it
    /// to put up the confirmation. Nothing reaches HealthKit until `save()`.
    private(set) var pendingSave: PendingWorkout?

    /// Set when the *system* (not us) ended the session out from under a live
    /// recording — an OS-side termination we'd otherwise be blind to. Logged and
    /// surfaced so the failure is diagnosable instead of just "audio went quiet".
    private(set) var endedUnexpectedly = false

    /// The metadata a pending walk needs to describe itself in the confirmation
    /// prompt, so the view never has to touch the builder.
    struct PendingWorkout: Equatable, Identifiable {
        let start: Date
        let end: Date
        /// Whether the underlying workout session is merely *paused* and can be
        /// picked back up as one continuous walk. False once the session is
        /// truly over — the system ended it, a watchdog gave up, or it was
        /// recovered as an orphan — where the only honest choices are keep or
        /// throw away.
        let canResume: Bool
        var id: Date { start }
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    private override init() {
        super.init()
    }

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
            Log.error("HealthKit authorization error: \(error)")
        }
    }

    /// Begins a walking workout branded "Birding". No-op if HealthKit is
    /// unavailable or a session is already running.
    func start() async {
        guard HKHealthStore.isHealthDataAvailable(), session == nil else { return }

        // Ask for HealthKit access lazily, the first time a session is actually
        // started, rather than at app launch. Idempotent — HealthKit only shows
        // its sheet the first time, so later starts pass straight through.
        await requestAuthorization()

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
            // Without a delegate an OS-side end (or error) is completely
            // invisible to us: the mic goes dead, the app loses its background
            // runtime, and the first symptom is silence. See the delegate
            // methods below.
            session.delegate = self

            self.session = session
            self.builder = builder
            self.endedUnexpectedly = false

            let start = Date()
            self.startDate = start
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            // Brand the workout "Birding" so it shows up under that name in the
            // Fitness app instead of the generic "Outdoor Walk".
            try await builder.addMetadata([HKMetadataKeyWorkoutBrandName: "Birding"])
        } catch {
            Log.error("Workout start error: \(error)")
            session = nil
            builder = nil
            startDate = nil
        }
    }

    /// The user tapped stop. *Pauses* the workout rather than ending it, and
    /// parks it in `pendingSave` for a finish/resume/discard decision.
    ///
    /// Pausing is what makes "Resume" seamless: an `HKWorkoutSession` is
    /// terminal once ended, so ending here and starting a new session on resume
    /// would split one birding walk into two workouts with a hole between them.
    /// A paused session keeps both the walk and our background runtime intact,
    /// so resuming is genuinely a continuation.
    ///
    /// Trivially short walks skip the prompt entirely — a stop a few seconds in
    /// is a mistake or a change of mind, and re-tapping record is less friction
    /// than a prompt. Those return false so the caller can `end()` them instead,
    /// which discards them outright.
    ///
    /// Synchronous on purpose. The watch morphs the stop button *directly* into
    /// the prompt's Cancel button, so `pendingSave` has to land in the same turn
    /// the morph starts. Behind an `await` there'd be a beat where the view sees
    /// neither "recording" nor "prompting", and the button would slingshot back
    /// toward center before snapping into the corner.
    ///
    /// Only the decision is made here: HealthKit isn't touched until
    /// `applyPause()`, which the session manager calls once the morph has played,
    /// so the tap's frame carries nothing but state flips.
    @discardableResult
    func pause() -> Bool {
        guard session != nil, let builder, let started = startDate else { return false }
        guard Date().timeIntervalSince(started) >= minimumDuration else { return false }

        pendingBuilder = builder
        pendingSave = PendingWorkout(start: started, end: Date(), canResume: true)
        pendingPause = true
        startAbandonTimeout()
        return true
    }

    /// The HealthKit half of `pause()`, run after the stop button has finished
    /// morphing down into the prompt. A no-op if the user already answered the
    /// prompt inside that window — there's nothing to pause a session for when
    /// it's about to end (or has just carried on).
    func applyPause() {
        guard pendingPause else { return }
        pendingPause = false
        guard pendingSave?.canResume == true, let session else { return }
        session.pause()
        pausedForPrompt = true
    }

    /// Set between `pause()` and `applyPause()` — the walk is parked for the
    /// prompt, but HealthKit hasn't been told yet.
    private var pendingPause = false
    /// True once `applyPause()` has actually paused the session, so `applyResume()`
    /// knows whether there's a pause to undo.
    private var pausedForPrompt = false

    /// The user chose to keep birding. Clears the prompt so the Cancel button can
    /// animate straight back up into the stop button; the workout itself is
    /// un-paused by `applyResume()` once that has played. Returns false if the
    /// session was no longer resumable, in which case the caller must not act as
    /// though it recovered.
    @discardableResult
    func resume() -> Bool {
        guard session != nil, pendingSave?.canResume == true else { return false }
        cancelAbandonTimeout()
        // The builder keeps collecting into the same workout; nothing to reset.
        pendingBuilder = nil
        pendingSave = nil
        return true
    }

    /// The HealthKit half of `resume()`, run after the morph. If the pause never
    /// reached HealthKit (the user hit Cancel inside the morph window) this just
    /// cancels it rather than resuming a session that was never paused.
    func applyResume() {
        pendingPause = false
        guard pausedForPrompt, let session else { return }
        pausedForPrompt = false
        session.resume()
    }

    /// Drops the prompt without deciding anything. The view calls this the instant
    /// a tapped Save/Discard button has finished morphing back into the record
    /// button, so the HealthKit work that follows — which can take a moment —
    /// never leaves the answered prompt sitting on screen behind the animation.
    func dismissPrompt() {
        cancelAbandonTimeout()
        pendingSave = nil
    }

    /// A paused walk the user never answered shouldn't hold the workout session —
    /// and the background runtime it grants — open indefinitely. After this long,
    /// end the session for real; the prompt stays up but loses its Resume option.
    private let abandonTimeout: TimeInterval = 10 * 60
    private var abandonTask: Task<Void, Never>?

    private func startAbandonTimeout() {
        cancelAbandonTimeout()
        abandonTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.abandonTimeout ?? 600))
            guard !Task.isCancelled, let self, self.pendingSave?.canResume == true else { return }
            Log.warning("Paused workout left unanswered — ending it, keeping the save prompt")
            await self.endPausedSession()
        }
    }

    private func cancelAbandonTimeout() {
        abandonTask?.cancel()
        abandonTask = nil
    }

    /// Closes out a session that's sitting paused behind the prompt, leaving the
    /// pending save in place but no longer resumable. Shared by the abandon
    /// timeout and by `save()`/`discard()`, both of which need the session
    /// properly ended before they touch the builder.
    private func endPausedSession() async {
        guard let session, let builder else { return }
        self.session = nil
        self.builder = nil
        pendingPause = false
        pausedForPrompt = false
        cancelAbandonTimeout()

        let end = Date()
        session.end()
        do {
            try await builder.endCollection(at: end)
        } catch {
            Log.error("Workout endCollection error: \(error)")
        }
        if let pending = pendingSave {
            // Losing Resume re-centers the two remaining buttons, so animate it
            // rather than letting the prompt jump under the user's thumb. The
            // view animates nothing implicitly — every transition is driven from
            // an explicit transaction like this one.
            withAnimation(.easeInOut(duration: 0.3)) {
                pendingSave = PendingWorkout(start: pending.start, end: pending.end, canResume: false)
            }
        }
    }

    /// Ends the workout session and stops collecting, but saves *nothing* yet.
    /// A walk long enough to be real is parked in `pendingSave` for the user to
    /// confirm; a trivially short one is discarded outright. No-op if none is
    /// running.
    ///
    /// This is the *unattended* teardown — a watchdog giving up, the system
    /// ending the session, an orphan being reclaimed — so the resulting prompt
    /// offers no Resume. A user-initiated stop goes through `pause()` instead.
    func end() async {
        guard let session, let builder else { return }
        // Clear our references first so a stop/start race can't end up finishing
        // a fresh session by mistake.
        self.session = nil
        self.builder = nil
        pendingPause = false
        pausedForPrompt = false
        let started = startDate
        self.startDate = nil

        let end = Date()
        session.end()

        do {
            try await builder.endCollection(at: end)
        } catch {
            Log.error("Workout endCollection error: \(error)")
            builder.discardWorkout()
            return
        }

        // Too short to be a real birding walk — throw it away without bothering
        // the user about it.
        guard let started, end.timeIntervalSince(started) >= minimumDuration else {
            builder.discardWorkout()
            return
        }

        // Hold the builder open. Nothing is written to HealthKit (and so no
        // activity-sharing notification fires) until `save()`.
        self.pendingBuilder = builder
        // This is the unattended path — the prompt arrives on its own rather
        // than under a button's morph — so it fades in on its own transaction.
        withAnimation(.easeInOut(duration: 0.3)) {
            self.pendingSave = PendingWorkout(start: started, end: end, canResume: false)
        }
    }

    /// The ended-but-unwritten builder behind `pendingSave`.
    private var pendingBuilder: HKLiveWorkoutBuilder?

    /// User confirmed: write the pending walk to HealthKit. This is the only
    /// path that creates a workout sample (and the only one that can notify the
    /// user's activity-sharing friends).
    func save() async {
        // Coming from a paused walk (the user picked Finish over Resume), the
        // session is still live — close it out before the builder can be
        // finished, or `finishWorkout()` has nothing valid to write.
        await endPausedSession()
        guard let builder = pendingBuilder else { return }
        pendingBuilder = nil
        pendingSave = nil
        do {
            _ = try await builder.finishWorkout()
        } catch {
            Log.error("Workout finish error: \(error)")
        }
    }

    /// User declined (or the prompt was dismissed): drop the walk. Also the path
    /// taken when a new session starts while an old prompt is still up, so a
    /// stale walk can never be attributed to the new one.
    func discard() async {
        // As in `save()`: a paused session has to be ended before its builder
        // can be disposed of.
        await endPausedSession()
        guard let builder = pendingBuilder else {
            pendingSave = nil
            return
        }
        pendingBuilder = nil
        pendingSave = nil
        builder.discardWorkout()
    }

    /// Reattaches to a workout session that outlived the app — the case where
    /// watchOS terminated or the app crashed mid-birding-walk and then relaunched
    /// while the session was still running. Without this the orphaned session
    /// keeps the workout state machine (and its battery cost) alive with nothing
    /// driving it, and a fresh `start()` would be refused by HealthKit.
    ///
    /// We deliberately *end* the recovered session rather than resuming capture:
    /// the audio pipeline and the phone link both need an explicit user tap to
    /// come back up, so silently pretending to still be recording would be a lie.
    /// The recovered walk still goes through the same confirm-before-save path.
    func recoverOrphanedSession() async {
        guard HKHealthStore.isHealthDataAvailable(), session == nil else { return }
        let recovered: HKWorkoutSession?
        do {
            recovered = try await healthStore.recoverActiveWorkoutSession()
        } catch {
            Log.error("Workout recovery error: \(error)")
            return
        }
        guard let recovered else { return }

        Log.warning("Recovered an orphaned workout session — app was terminated mid-session")
        let builder = recovered.associatedWorkoutBuilder()
        recovered.delegate = self
        self.session = recovered
        self.builder = builder
        self.startDate = builder.startDate ?? recovered.startDate
        await end()
    }

    // MARK: - HKWorkoutSessionDelegate

    /// The session changed state without us asking. `.ended` while we still
    /// think we're recording is exactly the failure mode we were blind to
    /// before: the OS pulled our background runtime, so the mic is about to stop
    /// producing audio. Flag it so the session manager can tear down cleanly and
    /// tell the user, rather than leaving a dead-but-apparently-live recording.
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            guard toState == .ended || toState == .stopped else { return }
            // Our own `end()` clears `session` before calling `session.end()`, so
            // a still-set session here means this end came from the system.
            guard self.session === workoutSession else { return }
            Log.warning("Workout session ended by the system (from \(fromState.rawValue))")
            self.endedUnexpectedly = true
            await self.end()
            // Our background runtime went with the session, so the mic is about
            // to stop producing audio. Tear the recording down deliberately
            // instead of leaving a live-looking session that hears nothing.
            WatchSessionManager.shared.handleWorkoutEndedBySystem()
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            Log.error("Workout session failed: \(error)")
            guard self.session === workoutSession else { return }
            self.endedUnexpectedly = true
            await self.end()
            // Our background runtime went with the session, so the mic is about
            // to stop producing audio. Tear the recording down deliberately
            // instead of leaving a live-looking session that hears nothing.
            WatchSessionManager.shared.handleWorkoutEndedBySystem()
        }
    }
}
