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
    /// When the current walk began, so `end()` can discard walks shorter
    /// than `minimumDuration` rather than offering to log a trivially short one.
    ///
    /// The instant the record button was tapped, handed in by
    /// `start(walkStartedAt:)` — *not* the instant this method runs. See that
    /// parameter.
    private var startDate: Date?
    /// Birding walks this short aren't worth saving to HealthKit — they're
    /// usually an accidental start/stop, not a real walk.
    ///
    /// `static`, and measured from the tap (see `isLongEnough`), because the
    /// phone keeps the same threshold under the same name
    /// (`RecordingManager.minimumWorkoutDuration`) and the two have to agree
    /// about which walks are worth prompting over.
    nonisolated static let minimumDuration: TimeInterval = 15

    /// Whether a walk that began at `walkStartedAt` and ended at `endedAt` ran
    /// long enough to be worth keeping.
    ///
    /// **`walkStartedAt` is the tap, not the HealthKit bring-up**, and that is the
    /// whole point of stating this as a function. The phone measures its own copy
    /// of this threshold from the `start` handshake, which the watch sends 320 ms
    /// after the tap and *before* the microphone prompt and the audio-engine
    /// bring-up — seconds, on a cold start. Timed from `start()`'s own `Date()`
    /// the watch's clock therefore ran *behind* the phone's, and the band between
    /// them was a hole a walk fell through: the phone offered "Save Workout" for a
    /// 16-second walk, the user tapped Save, and the watch — which made it 13
    /// seconds — refused to park it, discarded it in `end()`, and left the relayed
    /// `.save` with neither a builder nor a span to write. Silently.
    ///
    /// Starting the walk at the tap puts the watch's clock *ahead* of the phone's
    /// by the handshake delay instead, which is the safe direction: the phone may
    /// decline to prompt for a walk the watch would have kept, and the `.ask` it
    /// sends then puts the question on the wrist, which is the documented
    /// fallback. See `WatchSessionManager.beginSession`.
    nonisolated static func isLongEnough(walkStartedAt: Date, endedAt: Date) -> Bool {
        endedAt.timeIntervalSince(walkStartedAt) >= minimumDuration
    }

    /// A walk waiting on the user's decision. Non-nil only between
    /// `pause()`/`end()` and `save()`/`discard()`/`resume()`; the view observes it
    /// to put up the confirmation. Nothing reaches HealthKit until `save()`.
    private(set) var pendingSave: PendingWorkout?

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

    /// Begins a walking workout branded "Birding". No-op if a session is already
    /// running.
    ///
    /// A failure to bring the live session up is *not* fatal to the save prompt:
    /// `startDate` is recorded first and kept whatever happens below, so a walk
    /// HealthKit refused to collect live can still be offered when the user stops
    /// and written after the fact (see `pause()` / `save()`). Before this, an
    /// unauthorized or otherwise failed `HKWorkoutSession` meant no prompt ever
    /// appeared — a device-only failure that never reproduced in the simulator.
    ///
    /// - Parameter walkStartedAt: when the user tapped record, which is when the
    ///   walk began — not when this runs, which is after the morph, the
    ///   microphone prompt and the audio-engine bring-up. Passing it in is what
    ///   keeps this side's `minimumDuration` from being reached later than the
    ///   phone's copy of the same threshold; see `isLongEnough`. HealthKit takes
    ///   the slightly-past instant for both `startActivity` and `beginCollection`,
    ///   and it is the more honest start for the workout anyway.
    func start(walkStartedAt: Date) async {
        guard session == nil else { return }
        startDate = walkStartedAt

        guard HKHealthStore.isHealthDataAvailable() else {
            Log.warning("HealthKit unavailable — birding walk can't be collected or saved")
            return
        }

        // Ask for HealthKit access lazily, the first time a session is actually
        // started, rather than at app launch. Idempotent — HealthKit only shows
        // its sheet the first time, so later starts pass straight through.
        await requestAuthorization()
        if workoutSharingStatus != .sharingAuthorized {
            // The single likeliest reason a walk never reaches the save prompt on
            // a real watch, and invisible without this line.
            Log.warning("Workout sharing is \(Self.describe(workoutSharingStatus)) — this walk can't be saved to Health")
        }

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

            let start = startDate ?? Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            // Brand the workout "Birding" so it shows up under that name in the
            // Fitness app instead of the generic "Outdoor Walk".
            try await builder.addMetadata([HKMetadataKeyWorkoutBrandName: "Birding"])
        } catch {
            Log.error("Workout start error: \(error) (sharing status: \(Self.describe(workoutSharingStatus)))")
            session = nil
            builder = nil
            // `startDate` deliberately survives: the walk is still happening, and
            // the save prompt is keyed off its duration, not off HealthKit having
            // come up. `save()` writes it retroactively.
        }
    }

    /// Whether HealthKit will let us write workouts. Read for diagnostics and to
    /// decide whether offering to save a walk would be honest.
    private var workoutSharingStatus: HKAuthorizationStatus {
        healthStore.authorizationStatus(for: HKQuantityType.workoutType())
    }

    /// Whether a walk could be written to HealthKit at all, ignoring how long it
    /// ran. The half of `canOfferSave` that has nothing to do with the walk —
    /// and the half the *phone* can't work out for itself, so it is pushed across
    /// (see `WatchSessionManager.sendWorkoutSavable`).
    ///
    /// Without that push the phone's stop prompt offered "Save Workout" to a user
    /// who had denied workout sharing on the watch, and the tap did nothing at
    /// all: `pause()` refuses to park an unsavable walk, `end()` discards it, and
    /// `save()` then finds neither a builder nor a span to write. Silently.
    var canSaveWorkouts: Bool {
        Self.canSaveWorkouts(
            healthDataAvailable: HKHealthStore.isHealthDataAvailable(),
            sharing: workoutSharingStatus
        )
    }

    /// The rule behind `canSaveWorkouts`, as a pure function of the two facts it
    /// turns on, so both sides of the pair can be tested without a health store.
    ///
    /// `notDetermined` counts as savable: the authorization sheet hasn't been
    /// shown yet (it goes up on the first `start()`), and refusing to offer a save
    /// before the user has been asked would be its own kind of wrong. The push is
    /// repeated once that resolves, so a denial lands before the first stop.
    nonisolated static func canSaveWorkouts(
        healthDataAvailable: Bool,
        sharing: HKAuthorizationStatus
    ) -> Bool {
        healthDataAvailable && sharing != .sharingDenied
    }

    private static func describe(_ status: HKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:      return "not determined"
        case .sharingDenied:      return "denied"
        case .sharingAuthorized:  return "authorized"
        @unknown default:         return "unknown (\(status.rawValue))"
        }
    }

    /// Whether a walk of this span is worth putting the save prompt up for: long
    /// enough to be a real walk, and actually writable to HealthKit. Offering to
    /// save a walk we know can't be written would be a lie, so a denied
    /// authorization skips the prompt (loudly — that's the case that used to look
    /// like the prompt was simply broken).
    private func canOfferSave(started: Date?, end: Date) -> Bool {
        guard let started else { return false }
        let elapsed = end.timeIntervalSince(started)
        guard Self.isLongEnough(walkStartedAt: started, endedAt: end) else { return false }
        guard canSaveWorkouts else {
            Log.warning(
                "No save prompt for a \(Int(elapsed))s walk — "
                + (HKHealthStore.isHealthDataAvailable()
                    ? "workout sharing is denied in Health"
                    : "HealthKit unavailable")
            )
            return false
        }
        return true
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
    /// A live session is *not* required. If HealthKit refused to start one (the
    /// device-only failure that made this prompt look broken on a real watch),
    /// the walk still happened and is still offered — just without Resume, since
    /// there's no paused session to continue. `save()` writes it after the fact.
    ///
    /// Synchronous on purpose. The watch morphs the stop button *directly* into
    /// the prompt's Resume button, so `pendingSave` has to land in the same turn
    /// the morph starts. Behind an `await` there'd be a beat where the view sees
    /// neither "recording" nor "prompting", and the button would slingshot back
    /// toward center before snapping into the corner.
    ///
    /// Only the decision is made here: HealthKit isn't touched until
    /// `applyPause()`, which the session manager calls once the morph has played,
    /// so the tap's frame carries nothing but state flips.
    @discardableResult
    func pause() -> Bool {
        let end = Date()
        guard let started = startDate, canOfferSave(started: started, end: end) else { return false }

        // Only a session we're actually holding can be paused and picked back up.
        let live = session != nil && builder != nil
        if !live {
            Log.warning("Stop with no live workout session — offering the walk without Resume")
        }

        pendingBuilder = builder
        pendingSpan = (started, end)
        pendingSave = PendingWorkout(start: started, end: end, canResume: live)
        pendingPause = live
        if live { startAbandonTimeout() }
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

    /// The user chose to keep birding. Clears the prompt so the Resume button can
    /// animate straight back up into the stop button; the workout itself is
    /// un-paused by `applyResume()` once that has played. Returns false if the
    /// session was no longer resumable, in which case the caller must not act as
    /// though it recovered.
    @discardableResult
    func resume() -> Bool {
        guard Self.canPickBackUp(hasLiveSession: session != nil, pending: pendingSave) else {
            return false
        }
        cancelAbandonTimeout()
        // The builder keeps collecting into the same workout; nothing to reset.
        pendingBuilder = nil
        pendingSpan = nil
        pendingSave = nil
        return true
    }

    /// Whether a Resume tap can actually pick the walk back up: the prompt has to
    /// be offering a resume *and* there has to be a live session left to un-pause.
    ///
    /// The second half is not redundant with the first, and the gap between them
    /// is a window the user can land in rather than a theoretical race.
    /// `endPausedSession()` — which the ten-minute abandon timeout runs — clears
    /// `session` and only then re-parks `pendingSave` as non-resumable, with an
    /// `await` on HealthKit's `endCollection` in between. For the whole of that
    /// call the prompt still draws its Resume row and still takes taps, while the
    /// session behind it is already gone.
    ///
    /// `WatchSessionManager.resumeBirding` treats a `false` from `resume()` as
    /// "do not start anything": the walk is parked and unanswered, and beginning a
    /// session over it would let the next stop overwrite it. Extracted as a static
    /// so that window is pinned by a test rather than by a comment.
    nonisolated static func canPickBackUp(
        hasLiveSession: Bool,
        pending: PendingWorkout?
    ) -> Bool {
        hasLiveSession && pending?.canResume == true
    }

    /// The HealthKit half of `resume()`, run after the morph. If the pause never
    /// reached HealthKit (the user hit Resume inside the morph window) this just
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

        // The parked stop moment, not now — same reason as `end()`. This path is
        // reached by the abandon timeout, ten minutes after the user tapped stop,
        // and closing collection at *that* moment would hand Health a walk ten
        // minutes longer than the one they took. The session has been paused
        // since the tap, so there is nothing in that window to collect anyway.
        let end = Self.endInstant(parked: pendingSpan?.end, now: Date())
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
        // A walk `pause()` already parked carries its true stop moment — the
        // instant the user tapped stop. Reaching here afterwards (a watchdog, the
        // system ending the session, a remote stop relayed from the phone) must
        // not restate that as *now*: a prompt left sitting for ten minutes would
        // silently stretch the walk by ten minutes, and Health would record a
        // birding walk that ran long after the user stopped birding. Only a walk
        // nothing has parked yet ends at this moment.
        let end = Self.endInstant(parked: pendingSpan?.end, now: Date())
        let started = pendingSpan?.start ?? startDate
        self.startDate = nil
        pendingPause = false
        pausedForPrompt = false

        guard let session, let builder else {
            // No live session to end — HealthKit never brought one up. The walk
            // itself still happened, so offer it on the same terms; `save()`
            // writes it retroactively.
            //
            // `pendingBuilder`, not a bare nil: there may already be a *parked*
            // builder here, holding a walk that was collected live and then had
            // its session closed out by `endPausedSession()` (the ten-minute
            // abandon timeout). Passing nil would drop that builder on the floor,
            // and `save()` would then re-write the walk retroactively — same span,
            // but with none of the distance or energy HealthKit had actually
            // collected. Handing the existing one straight back is a no-op when
            // there isn't one.
            park(started: started, end: end, builder: pendingBuilder)
            return
        }
        // Clear our references first so a stop/start race can't end up finishing
        // a fresh session by mistake.
        self.session = nil
        self.builder = nil

        session.end()

        do {
            try await builder.endCollection(at: end)
        } catch {
            Log.error("Workout endCollection error: \(error)")
            builder.discardWorkout()
            return
        }

        // Too short (or unsavable) — throw it away without bothering the user.
        guard canOfferSave(started: started, end: end) else {
            builder.discardWorkout()
            return
        }

        // Hold the builder open. Nothing is written to HealthKit (and so no
        // activity-sharing notification fires) until `save()`.
        park(started: started, end: end, builder: builder)
    }

    /// When a walk actually ended.
    ///
    /// A walk `pause()` already parked carries its true stop moment — the instant
    /// the user tapped stop. Every later teardown path (`end()`, and the abandon
    /// timeout's `endPausedSession()`) must use *that*, not the moment it happens
    /// to run: a prompt left sitting for ten minutes would otherwise stretch the
    /// walk by ten minutes, and Health would record a birding walk that ran long
    /// after the user stopped birding. The session has been paused since the tap,
    /// so there is nothing in that window to collect anyway.
    ///
    /// Only a walk nothing has parked yet ends at the current instant.
    nonisolated static func endInstant(parked: Date?, now: Date) -> Date {
        parked ?? now
    }

    /// Parks a finished, unattended walk in `pendingSave` so the prompt fades in
    /// on its own (rather than under a button's morph, which is `pause()`'s job).
    /// A nil `builder` means nothing was collected live and `save()` will have to
    /// write the walk after the fact.
    private func park(started: Date?, end: Date, builder: HKLiveWorkoutBuilder?) {
        guard let started, canOfferSave(started: started, end: end) else { return }
        pendingBuilder = builder
        pendingSpan = (started, end)
        withAnimation(.easeInOut(duration: 0.3)) {
            pendingSave = PendingWorkout(start: started, end: end, canResume: false)
        }
    }

    /// The ended-but-unwritten builder behind `pendingSave`, when the walk was
    /// collected live.
    private var pendingBuilder: HKLiveWorkoutBuilder?

    /// The span of the walk behind `pendingSave`. Kept separately because
    /// `dismissPrompt()` clears `pendingSave` the moment the answer has finished
    /// animating — before `save()` runs — and a walk with no live builder has
    /// nothing else left to describe it.
    private var pendingSpan: (start: Date, end: Date)?

    /// User confirmed: write the pending walk to HealthKit. This is the only
    /// path that creates a workout sample (and the only one that can notify the
    /// user's activity-sharing friends).
    func save() async {
        // Coming from a paused walk (the user picked Finish over Resume), the
        // session is still live — close it out before the builder can be
        // finished, or `finishWorkout()` has nothing valid to write.
        await endPausedSession()
        let builder = pendingBuilder
        let span = pendingSpan
        pendingBuilder = nil
        pendingSpan = nil
        pendingSave = nil
        startDate = nil

        if let builder {
            do {
                _ = try await builder.finishWorkout()
            } catch {
                Log.error("Workout finish error: \(error)")
            }
            return
        }
        // Nothing was collected live — HealthKit never gave us a session for this
        // walk. Write it from the span we recorded instead, so Save still means
        // saved. No distance or energy samples, but the walk itself is logged.
        guard let span else { return }
        await saveRetroactively(start: span.start, end: span.end)
    }

    /// Writes a walk that was never collected live, using a plain (non-live)
    /// builder over the span the recording actually ran for.
    private func saveRetroactively(start: Date, end: Date) async {
        let config = HKWorkoutConfiguration()
        config.activityType = .walking
        config.locationType = .outdoor
        let builder = HKWorkoutBuilder(
            healthStore: healthStore,
            configuration: config,
            device: .local()
        )
        do {
            try await builder.beginCollection(at: start)
            try await builder.addMetadata([HKMetadataKeyWorkoutBrandName: "Birding"])
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        } catch {
            Log.error("Retroactive workout save error: \(error) (sharing status: \(Self.describe(workoutSharingStatus)))")
        }
    }

    /// User declined (or the prompt was dismissed): drop the walk. Also the path
    /// taken when a new session starts while an old prompt is still up, so a
    /// stale walk can never be attributed to the new one.
    func discard() async {
        // As in `save()`: a paused session has to be ended before its builder
        // can be disposed of.
        await endPausedSession()
        let builder = pendingBuilder
        pendingBuilder = nil
        pendingSpan = nil
        pendingSave = nil
        startDate = nil
        // A walk with no live builder was never collected, so there's nothing to
        // throw away — dropping the pending state above is the whole discard.
        builder?.discardWorkout()
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
    /// producing audio. Log it, wind the walk down, and hand off to the session
    /// manager — which tells the user — rather than leaving a
    /// dead-but-apparently-live recording.
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
            await self.end()
            // Our background runtime went with the session, so the mic is about
            // to stop producing audio. Tear the recording down deliberately
            // instead of leaving a live-looking session that hears nothing.
            WatchSessionManager.shared.handleWorkoutEndedBySystem()
        }
    }
}
