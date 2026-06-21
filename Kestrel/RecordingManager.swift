import AVFoundation
import CoreHaptics
import CoreLocation
import Foundation
import Observation
import SwiftUI
import UIKit
import WatchConnectivity

@Observable
@MainActor
final class RecordingManager {
    private(set) var isRecording = false
    /// True while audio is being streamed in from the Apple Watch companion.
    /// The Identify view disables its own record button while this is true.
    private(set) var watchRecording = false
    /// Whether a paired Apple Watch currently has the Kestrel watch app
    /// installed. Pushed from `WatchAudioBridge` on activation and whenever the
    /// watch state changes. Drives watch-specific UI copy/controls (the Identify
    /// placeholder text and the Settings "Prefer Apple Watch microphone" toggle).
    private(set) var isWatchAppInstalled = false
    private(set) var detections: [Detection] = []
    private(set) var errorMessage: String?
    private(set) var locationStatus: String?
    /// IDs (scientific names) of detections whose confidence was just upgraded;
    /// the UI flashes their row yellow while they're in this set.
    private(set) var flashIDs: Set<String> = []
    /// Scientific names already in the life list when this recording session
    /// began. Used both by the UI (to decide which rows get the purple tint)
    /// and by `process(window:)` (to color the spectrogram detection band
    /// purple instead of goldenrod). Captured by the view via
    /// `snapshotLifeList(_:)` on the false → true transition of `isRecording`.
    private(set) var lifeListSnapshot: Set<String> = []
    /// Live set of scientific names the user has starred. The Identify UI
    /// pushes this in via `updateStarred(_:)` whenever the life list changes,
    /// so notifications/highlighting react to mid-session star toggles instead
    /// of being frozen to a snapshot.
    private(set) var starredNames: Set<String> = []

    /// Scientific names the user added to the life list *from the watch* during
    /// the current session. The life-list snapshot stays frozen for the session
    /// (so a bird the user added keeps its purple "new species" treatment and
    /// add button on the watch), so this separate set is what suppresses a
    /// repeat notification/haptic for a bird the user has already added. Reset
    /// at the start of every session.
    private var watchAddedThisSession: Set<String> = []

    /// Pushed from `KestrelApp`'s tab + scene-phase observers. When false,
    /// new-species events fire a local notification instead of relying on
    /// the in-app UI.
    var spectrogramVisible: Bool = true

    /// True while the iOS app is foregrounded (scene active), regardless of
    /// which tab is showing or which microphone is the audio source. Pushed
    /// from `KestrelApp`'s scene-phase observer. When true, fresh new/starred
    /// detections buzz the *phone* locally; when false, the haptic is sent to
    /// the watch instead.
    var appForegrounded: Bool = false

    /// The life list, wired up in `KestrelApp.init`. Held weakly since the
    /// app owns it for its whole lifetime. The manager reads it directly at
    /// session start so `lifeListSnapshot`/`starredNames` are correct even
    /// when a session is kicked off from the watch while the iOS app is
    /// suspended in the background and no SwiftUI view is observing — the
    /// case that otherwise left the snapshot empty and made every detection
    /// look like a brand-new species.
    weak var lifeListStore: LifeListStore?

    let spectrogram = SpectrogramRenderer()

    private let pipeline = AudioPipeline()
    private let locationProvider = LocationProvider()
    private var classifierTask: Task<BirdNETClassifier, Error>?
    private var rangeFilterTask: Task<SpeciesRangeFilter, Error>?
    private var allowedIndices: Set<Int>?
    private var detectionMap: [String: Detection] = [:]
    /// Per-species timestamp of the last visual flash; used to enforce a
    /// 5-second cooldown so a species doesn't strobe on every overlapping
    /// 1.5 s window of inference.
    private var lastFlashAt: [String: Date] = [:]
    /// Last time each species fired a *notification*. A species becomes
    /// eligible for a fresh notification once it's been silent for the cooldown
    /// window (30 s), letting a bird that comes back later re-fire instead
    /// of staying muted for the rest of the session.
    private var lastHeardAt: [String: Date] = [:]
    /// Per-species timestamp of the last *haptic*. Haptics use a much shorter
    /// cooldown than notifications so a still-singing new/starred bird keeps
    /// buzzing on repeat detections instead of going quiet for the rest of the
    /// notification window.
    private var lastHapticAt: [String: Date] = [:]
    private let hapticCooldown: TimeInterval = 5
    private let notifyCooldown: TimeInterval = 30
    /// Scientific name of the species currently shown on the watch's "now
    /// hearing" screen, so we only push an update when it actually changes.
    /// Reset at the start of every session.
    private var lastWatchDisplaySci: String?
    /// Tracks the deferred audio engine start/stop task so rapid taps can
    /// cancel a pending transition before its sleep elapses.
    private var pendingTransitionTask: Task<Void, Never>?
    private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?
    /// Lazily-created Core Haptics engine for the new-lifer tap+buzz pattern.
    /// Rebuilt on demand if the system stops it (e.g. after an interruption).
    private var hapticEngine: CHHapticEngine?

    // Watch-audio ingestion state. Samples arrive 16 kHz Float mono from the
    // watch; we upsample to 48 kHz via linear interpolation, hand them to the
    // spectrogram, and accumulate into BirdNET-sized windows.
    private var watchWindowBuffer: [Float] = []
    private var watchLastSample: Float = 0
    /// Silent-audio playback used to keep the iOS app alive in the
    /// background while the watch is the audio source.
    private let watchKeepalive = BackgroundAudioKeepalive()
    /// Periodically checks whether audio is still flowing from the watch.
    /// If a generous gap elapses with no chunks, we assume the link
    /// dropped (out of range, watch crashed) and notify the user.
    private var watchHeartbeatTask: Task<Void, Never>?
    /// Timestamp of the most recent audio chunk delivered by the watch.
    private var lastWatchAudioAt: Date?
    private let watchDisconnectThreshold: TimeInterval = 60

    /// Watchdog that auto-stops the recording once the session goes 30 min
    /// without any detection. Reset each time `merge(_:)` sees at least one
    /// result; armed in `startLocally`/`startFromWatch`; cancelled in `stop`/
    /// `stopFromWatch`.
    private var idleTerminationTask: Task<Void, Never>?
    private var lastDetectionAt: Date?
    private let idleTerminationThreshold: TimeInterval = 30 * 60

    init() {
        registerInterruptionObserver()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// Begins loading the BirdNET classifier and the species-range model in
    /// background tasks so the first Start Recording tap is fast. Safe to call
    /// multiple times; subsequent calls are no-ops.
    func preload() {
        if classifierTask == nil {
            classifierTask = Task.detached(priority: .userInitiated) {
                try BirdNETClassifier()
            }
        }
        if rangeFilterTask == nil {
            rangeFilterTask = Task.detached(priority: .utility) {
                try SpeciesRangeFilter()
            }
        }

        // Pre-warm the audio pipeline in the background. Runs at .userInitiated
        // so it doesn't get scheduled behind the classifier load on the
        // executor; pipeline.start() awaits this task before activating the
        // session itself, so the two can't race on the shared AVAudioSession.
        pipeline.startPrewarm()

        // Kick off the location/range-filter lookup at launch so the
        // "Filtered to N species" caption is ready to fade in before the
        // user taps Start Recording, instead of appearing mid-session and
        // shoving the record button down.
        if locationStatus == nil {
            Task { await self.refreshSpeciesFilter() }
        }
    }

    func toggle() async {
        if watchRecording {
            // Active session was started on / for the watch — ask the watch
            // to stop. It'll tear down its streamer + ERS and send back a
            // "stop" handshake that flips our state.
            stopWatchSession()
        } else if isRecording {
            stop()
        } else {
            await start()
        }
    }

    /// Entry point for the Start Recording app intent (lock-screen widget /
    /// Shortcuts). Starts a new session only when nothing is already running,
    /// so a tap while recording is a no-op rather than a restart.
    func startFromIntent() async {
        guard !isRecording, !watchRecording else { return }
        await start()
    }

    /// Start recording on the phone. Tapping Start Recording on the phone always
    /// listens on the phone's own microphone; the watch's own Start button is
    /// what captures on the watch.
    func start() async {
        await startLocally()
    }

    /// Records whether a paired watch has the watch app installed. Called by
    /// `WatchAudioBridge` from the `WCSessionDelegate` callbacks.
    func updateWatchAppInstalled(_ installed: Bool) {
        isWatchAppInstalled = installed
    }

    /// Update the watch's "now hearing" screen with a freshly-heard species —
    /// any species, since the watch always shows the last one heard. `highlight`
    /// ("starred"/"newSpecies"/"normal") tints the watch background. No haptic:
    /// buzzing is reserved for new/starred birds and sent via `sendHapticToWatch`.
    private func sendBirdDisplayToWatch(commonName: String, scientificName: String, highlight: String) {
        sendToWatch([
            "birdCommon": commonName,
            "birdSci": scientificName,
            "highlight": highlight,
        ])
    }

    /// Buzz the wrist for a fresh new/starred bird. The kind picks a distinct
    /// `WKHapticType` on the watch (sharper for starred, softer for a new
    /// species) and is independent of the display — an already-known bird
    /// updates the screen without a tap.
    private func sendHapticToWatch(reason: SpeciesNotifications.Reason) {
        let kind: String
        switch reason {
        case .starred:    kind = "starred"
        case .newSpecies: kind = "newSpecies"
        }
        sendToWatch(["haptic": kind])
    }

    /// Buzz the *phone* for a fresh new/starred bird while its app is
    /// foregrounded. Mirrors the watch's distinction: a softer `.success`
    /// notification for a starred bird, and a sharp tap followed by a buzz for a
    /// brand-new lifer (the phone analogue of the watch's `.notification`).
    private func playLocalHaptic(reason: SpeciesNotifications.Reason) {
        switch reason {
        case .starred:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .newSpecies:
            playNewLiferHaptic()
        }
    }

    /// A crisp transient tap immediately followed by a short continuous buzz —
    /// the phone version of the watch's brand-new-lifer alert. The canned
    /// `UINotificationFeedbackGenerator` styles can't express a tap→buzz, so
    /// this builds it with Core Haptics. Falls back to a `.warning` notification
    /// on hardware without haptics or if the engine fails to start.
    private func playNewLiferHaptic() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        do {
            let engine: CHHapticEngine
            if let existing = hapticEngine {
                engine = existing
            } else {
                engine = try CHHapticEngine()
                // Forget the engine if the system stops it (e.g. audio
                // interruption) so the next lifer lazily rebuilds it; recover
                // in place on a reset.
                engine.stoppedHandler = { [weak self] _ in
                    Task { @MainActor in self?.hapticEngine = nil }
                }
                engine.resetHandler = { [weak engine] in try? engine?.start() }
                hapticEngine = engine
            }
            try engine.start()

            // Sharp tap at t=0, then a softer, less-sharp buzz a beat later.
            let tap = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
                ],
                relativeTime: 0
            )
            let buzz = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
                ],
                relativeTime: 0.12,
                duration: 0.28
            )
            let pattern = try CHHapticPattern(events: [tap, buzz], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    /// Shared watch delivery. Live `sendMessage` is the fast path when the watch
    /// app is reachable; `transferUserInfo` is the background-tolerant fallback
    /// — used both when unreachable and as the recovery path for a `sendMessage`
    /// that races the app backgrounding (it queues and can wake a suspended app).
    private func sendToWatch(_ payload: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated,
              s.isPaired,
              s.isWatchAppInstalled else { return }
        if s.isReachable {
            s.sendMessage(payload, replyHandler: nil, errorHandler: { _ in
                WCSession.default.transferUserInfo(payload)
            })
        } else {
            s.transferUserInfo(payload)
        }
    }

    private func stopWatchSession() {
        let s = WCSession.default
        s.sendMessage(["cmd": "remoteStop"], replyHandler: nil, errorHandler: nil)
        s.transferUserInfo(["cmd": "remoteStop"])
        // Don't flip `watchRecording` here — the watch sends "stop" back
        // through its normal channel and we let that update our state, so
        // the UI matches reality even if the remote tear-down is slow.
    }

    func startLocally() async {
        // If a pending stop task is in its post-animation sleep, drop it before
        // we kick off a fresh start. Same applies the other direction.
        pendingTransitionTask?.cancel()
        pendingTransitionTask = nil

        guard !isRecording else { return }

        // If the engine is still running because we just cancelled a pending
        // stop task before it could fire pipeline.stop, this is a "resume" of
        // the same recording, not a fresh one. Flip the UI flag back and bail
        // — re-running pipeline.start on an already-running engine causes the
        // tap to be re-installed and audio to double-process.
        if pipeline.isRunning {
            isRecording = true
            return
        }

        errorMessage = nil

        guard await requestMicrophonePermission() else {
            errorMessage = "Microphone permission denied."
            return
        }

        detections = []
        detectionMap = [:]
        flashIDs = []
        lastFlashAt = [:]
        lastHapticAt = [:]
        lastWatchDisplaySci = nil
        watchAddedThisSession = []
        spectrogram.reset()
        refreshLifeListFromStore()
        // Don't clear locationStatus — leave the previous filter visible until
        // refreshSpeciesFilter overwrites it, otherwise the text flickers.
        isRecording = true

        // Mirror this phone-mic session onto the watch so its "now hearing"
        // screen shows the same birds, as though the watch were the source.
        sendToWatch(["cmd": "phoneStart"])

        // Audio engine startup secretly uses main-thread time even when called
        // from a detached task (AVAudioEngine posts route-change callbacks to
        // main during first activation). Letting it run concurrently with the
        // button morph animation freezes the UI for ~200 ms. We defer the
        // engine start until just after the animation has committed.
        let pipeline = self.pipeline
        let spectrogram = self.spectrogram
        pendingTransitionTask = Task.detached(priority: .userInitiated) { [weak self] in
            await pipeline.awaitPrewarm()
            // Wait out the morph animation. Cancel-aware sleep so a rapid
            // tap that flips us back to stop can short-circuit this task.
            do {
                try await Task.sleep(for: .milliseconds(280))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                try pipeline.start(
                    onWindow: { window in
                        Task { @MainActor [weak self] in
                            await self?.process(window: window)
                        }
                    },
                    onChunk: { chunk in
                        spectrogram.ingest(chunk)
                    }
                )
            } catch {
                await MainActor.run {
                    self?.errorMessage = "Failed to start audio: \(error.localizedDescription)"
                    self?.isRecording = false
                }
                print("Kestrel: failed to start pipeline — \(error)")
            }
        }

        preload()
        Task { await self.refreshSpeciesFilter() }
        startIdleWatchdog()
    }

    func stop() {
        pendingTransitionTask?.cancel()
        pendingTransitionTask = nil
        cancelIdleWatchdog()

        guard isRecording else { return }
        isRecording = false

        // Tell the watch to drop its mirrored "now hearing" display.
        sendToWatch(["cmd": "phoneStop"])

        // If the engine never actually started (we cancelled a pending start
        // task before its 280ms sleep elapsed), there's nothing to tear down.
        guard pipeline.isRunning else { return }

        // engine.stop() + setActive(false) tax main internally during teardown.
        // Defer until after the SwiftUI morph animation has committed so the
        // button transition feels instant.
        let pipeline = self.pipeline
        pendingTransitionTask = Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(for: .milliseconds(280))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            pipeline.stop()
        }
    }

    // MARK: - Watch audio ingestion

    /// Called when the watch sends a "start" handshake. Resets per-session
    /// state the same way `start()` does but skips the local AVAudioEngine —
    /// the watch is the audio source now.
    func startFromWatch() async {
        pendingTransitionTask?.cancel()
        pendingTransitionTask = nil

        // If a phone-driven recording is already running, don't clobber it.
        if isRecording && !watchRecording { return }
        guard !watchRecording else { return }

        errorMessage = nil
        detections = []
        detectionMap = [:]
        flashIDs = []
        lastFlashAt = [:]
        lastHapticAt = [:]
        lastWatchDisplaySci = nil
        watchAddedThisSession = []
        watchWindowBuffer.removeAll(keepingCapacity: true)
        watchLastSample = 0
        spectrogram.reset()
        refreshLifeListFromStore()

        isRecording = true
        watchRecording = true

        // Activate the silent-audio keepalive so iOS doesn't suspend us
        // if the user puts the phone away mid-session.
        watchKeepalive.start()

        lastWatchAudioAt = Date()
        startWatchLifecycleWatchdogs()

        preload()
        Task { await self.refreshSpeciesFilter() }
        startIdleWatchdog()
    }

    /// Called when the watch sends a "stop" handshake.
    func stopFromWatch() {
        guard watchRecording else { return }
        watchRecording = false
        isRecording = false
        watchWindowBuffer.removeAll(keepingCapacity: true)
        watchKeepalive.stop()
        cancelWatchLifecycleWatchdogs()
        cancelIdleWatchdog()
    }

    /// Called when the watch reports that the *system* killed its recording
    /// session (e.g. the wrist dropped without the background-audio
    /// entitlement, or the runtime budget expired). Unlike a user-initiated
    /// stop, the user didn't ask for this, so we surface a notification before
    /// tearing down. Guarded by `stopFromWatch`'s own `watchRecording` check so
    /// it's a no-op (and fires no duplicate alert) if the heartbeat watchdog
    /// already tore the session down.
    func stopFromWatchUnexpectedly() {
        guard watchRecording else { return }
        Task {
            await SpeciesNotifications.shared.notifySessionLifecycle(
                title: "Kestrel",
                body: "Watch recording stopped. Re-tap the watch button to keep listening."
            )
        }
        stopFromWatch()
    }

    // MARK: - Idle auto-termination

    private func startIdleWatchdog() {
        idleTerminationTask?.cancel()
        lastDetectionAt = Date()
        idleTerminationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                let shouldStop = await self.checkIdleAndMaybeStop()
                if shouldStop { return }
            }
        }
    }

    private func cancelIdleWatchdog() {
        idleTerminationTask?.cancel()
        idleTerminationTask = nil
        lastDetectionAt = nil
    }

    /// Returns true if the watchdog tore the session down and the polling
    /// loop should exit.
    private func checkIdleAndMaybeStop() -> Bool {
        guard isRecording, let last = lastDetectionAt else { return true }
        let gap = Date().timeIntervalSince(last)
        guard gap >= idleTerminationThreshold else { return false }

        Task {
            await SpeciesNotifications.shared.notifySessionLifecycle(
                title: "Kestrel",
                body: "No birds heard for 30 minutes — recording stopped."
            )
        }
        if watchRecording {
            stopWatchSession()
        } else {
            stop()
        }
        return true
    }

    private func startWatchLifecycleWatchdogs() {
        watchHeartbeatTask?.cancel()
        watchHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                let stillAlive = await self.checkWatchHeartbeat()
                if !stillAlive { return }
            }
        }
    }

    private func cancelWatchLifecycleWatchdogs() {
        watchHeartbeatTask?.cancel()
        watchHeartbeatTask = nil
        lastWatchAudioAt = nil
    }

    /// Returns false once it tears the session down so the caller can exit
    /// its polling loop. Returns true while everything looks healthy.
    private func checkWatchHeartbeat() -> Bool {
        guard watchRecording, let last = lastWatchAudioAt else { return false }
        let gap = Date().timeIntervalSince(last)
        guard gap >= watchDisconnectThreshold else { return true }
        // Sync watch state so it stops claiming "recording" while we've
        // already given up on it. sendMessage covers the live path;
        // transferUserInfo queues for delivery if the watch is currently
        // unreachable, which is exactly the case that tripped this branch.
        let s = WCSession.default
        if s.activationState == .activated {
            s.sendMessage(["cmd": "remoteStop"], replyHandler: nil, errorHandler: nil)
            s.transferUserInfo(["cmd": "remoteStop"])
        }
        Task {
            await SpeciesNotifications.shared.notifySessionLifecycle(
                title: "Kestrel",
                body: "Watch disconnected. Re-tap the watch button to keep listening."
            )
        }
        stopFromWatch()
        return false
    }

    /// Ingest a chunk of 16 kHz mono Float samples from the watch.
    /// Linear-interpolation 3× upsample to 48 kHz, feed the spectrogram,
    /// then slice into BirdNET windows and dispatch inference.
    func ingestWatchSamples16k(_ samples16k: [Float]) {
        guard watchRecording, !samples16k.isEmpty else { return }
        lastWatchAudioAt = Date()

        // 3× linear upsample: between each input sample we emit two
        // interpolated samples. Carries `watchLastSample` across chunks so
        // we don't introduce a discontinuity at chunk boundaries.
        var upsampled = [Float]()
        upsampled.reserveCapacity(samples16k.count * 3)
        var prev = watchLastSample
        for s in samples16k {
            upsampled.append(prev)
            upsampled.append(prev + (s - prev) * (1.0 / 3.0))
            upsampled.append(prev + (s - prev) * (2.0 / 3.0))
            prev = s
        }
        watchLastSample = prev

        spectrogram.ingest(upsampled)

        watchWindowBuffer.append(contentsOf: upsampled)
        while watchWindowBuffer.count >= AudioPipeline.windowSamples {
            let window = Array(watchWindowBuffer.prefix(AudioPipeline.windowSamples))
            watchWindowBuffer.removeFirst(AudioPipeline.hopSamples)
            Task { await self.process(window: window) }
        }
    }

    // MARK: - Model accessors

    private func getClassifier() async -> BirdNETClassifier? {
        if classifierTask == nil { preload() }
        do {
            return try await classifierTask?.value
        } catch {
            errorMessage = "Failed to load BirdNET: \(error.localizedDescription)"
            print("Kestrel: classifier load — \(error)")
            return nil
        }
    }

    private func getRangeFilter() async -> SpeciesRangeFilter? {
        if rangeFilterTask == nil { preload() }
        do {
            return try await rangeFilterTask?.value
        } catch {
            print("Kestrel: range filter unavailable — \(error)")
            return nil
        }
    }

    // MARK: - Per-window inference

    private func process(window: [Float]) async {
        guard let classifier = await getClassifier() else { return }
        do {
            let results = try await classifier.classify(window, allowedIndices: allowedIndices)
            if !results.isEmpty {
                // Tint priority within a single window: starred > needs-add
                // > known lifer. Picks the most attention-grabbing color
                // when multiple species overlap on the same band.
                let kind: SpectrogramRenderer.TintKind
                if results.contains(where: { starredNames.contains($0.scientificName) }) {
                    kind = .starred
                } else if results.contains(where: { !lifeListSnapshot.contains($0.scientificName) }) {
                    kind = .needsAdd
                } else {
                    kind = .lifer
                }
                spectrogram.markDetection(kind: kind)
            }
            await MainActor.run { self.merge(results) }
        } catch {
            print("Kestrel: inference error — \(error)")
        }
    }

    /// Captures the set of life-list scientific names at the moment a new
    /// recording session starts. The UI calls this on the false → true
    /// transition of `isRecording`.
    func snapshotLifeList(_ scientificNames: Set<String>) {
        lifeListSnapshot = scientificNames
    }

    /// Populates `lifeListSnapshot` + `starredNames` straight from the store.
    /// Called at the top of every start path (local and watch-driven) so the
    /// "is this species already a lifer?" check is correct regardless of
    /// whether a SwiftUI view happens to be mounted and observing — without
    /// this, a watch-initiated background session started a stale (often
    /// empty) snapshot and notified for every bird heard.
    private func refreshLifeListFromStore() {
        guard let store = lifeListStore else { return }
        lifeListSnapshot = Set(store.entries.map(\.scientificName))
        starredNames = store.starredNames
    }

    /// Live mirror of the user's starred species. Unlike `lifeListSnapshot`
    /// this is *not* frozen at session start — toggling a star mid-session
    /// should immediately change which detections fire notifications and
    /// which spectrogram bands get the blue tint.
    func updateStarred(_ scientificNames: Set<String>) {
        starredNames = scientificNames
    }

    /// Adds a bird to the life list in response to the watch's add button.
    /// Persists it via the store (back-filling the first-seen coordinate the
    /// same way the in-app add flows do) and records it in
    /// `watchAddedThisSession` so it won't re-notify/buzz this session. The
    /// life-list snapshot stays frozen, so the watch keeps showing it as a new
    /// species with the add button in its checkmark state.
    func addBirdToLifeListFromWatch(commonName: String, scientificName: String) {
        guard let store = lifeListStore else { return }
        watchAddedThisSession.insert(scientificName)
        if let lat = LocationCache.shared.lastLatitude,
           let lon = LocationCache.shared.lastLongitude {
            store.add(
                scientificName: scientificName,
                commonName: commonName,
                latitude: lat,
                longitude: lon
            )
        } else {
            store.add(scientificName: scientificName, commonName: commonName)
            Task {
                guard let coord = await LocationCache.shared.current() else { return }
                store.updateFirstLocation(
                    scientificName: scientificName,
                    latitude: coord.latitude,
                    longitude: coord.longitude
                )
            }
        }
    }

    /// Undoes a watch-initiated add (second tap of the add button). Removes the
    /// species from the store and clears its notify/haptic suppression, so it's
    /// treated as a fresh new species again if heard later.
    func removeBirdFromLifeListFromWatch(scientificName: String) {
        guard let store = lifeListStore else { return }
        watchAddedThisSession.remove(scientificName)
        store.remove(scientificName: scientificName)
    }

    private func merge(_ results: [Detection]) {
        // Flash any repeat match (regardless of confidence change), but
        // enforce a per-species cooldown so the same row doesn't strobe on
        // every overlapping inference window.
        let now = Date()
        if !results.isEmpty { lastDetectionAt = now }
        let cooldown: TimeInterval = 5
        var repeatedIDs: [String] = []
        // Detections that should fire a notification this batch: species heard
        // with no detection in the last `notifyCooldown` s.
        var notifications: [(common: String, scientific: String, reason: SpeciesNotifications.Reason)] = []
        // Detections that should buzz this batch — gated by the much shorter
        // `hapticCooldown`, so a repeated new/starred bird keeps tapping even
        // while its notification is still on cooldown.
        var haptics: [SpeciesNotifications.Reason] = []
        for d in results {
            if let existing = detectionMap[d.id] {
                if d.confidence > existing.confidence {
                    detectionMap[d.id] = d  // takes new confidence + new lastSeen
                } else {
                    var updated = existing
                    updated.lastSeen = d.lastSeen
                    detectionMap[d.id] = updated
                }
                let lastFlash = lastFlashAt[d.id]
                if lastFlash == nil || now.timeIntervalSince(lastFlash!) >= cooldown {
                    repeatedIDs.append(d.id)
                    lastFlashAt[d.id] = now
                }
            } else {
                detectionMap[d.id] = d
            }

            // Notify when (a) the species is interesting (starred or
            // not-yet-in-life-list), and (b) it hasn't been heard for at
            // least `notifyCooldown` seconds. The clock resets on every
            // detection, so a continuously-singing bird only triggers
            // once; a bird that goes silent and returns re-fires.
            let isStarred = starredNames.contains(d.scientificName)
            let isNew = !lifeListSnapshot.contains(d.scientificName)
            // A bird the user already added from the watch this session stays a
            // "new species" for display (frozen snapshot) but shouldn't buzz or
            // notify again — they've acknowledged it.
            let alreadyAdded = watchAddedThisSession.contains(d.scientificName)
            if (isStarred || isNew) && !alreadyAdded {
                let reason: SpeciesNotifications.Reason = isStarred ? .starred : .newSpecies
                let last = lastHeardAt[d.scientificName]
                if last == nil || now.timeIntervalSince(last!) >= notifyCooldown {
                    notifications.append((d.commonName, d.scientificName, reason))
                }
                // Haptic on its own, shorter clock so repeats still buzz while
                // the notification stays muted for the rest of its window.
                let lastBuzz = lastHapticAt[d.scientificName]
                if lastBuzz == nil || now.timeIntervalSince(lastBuzz!) >= hapticCooldown {
                    haptics.append(reason)
                    lastHapticAt[d.scientificName] = now
                }
            }
            lastHeardAt[d.scientificName] = now
        }

        // Only surface to the user when the Identify spectrogram isn't on
        // screen — otherwise the visible rows already convey it.
        if !spectrogramVisible {
            for item in notifications {
                Task {
                    await SpeciesNotifications.shared.notifyNewSpecies(
                        commonName: item.common,
                        scientificName: item.scientific,
                        reason: item.reason
                    )
                }
            }
        }
        // Haptics fire for new/starred birds — including repeats, on the short
        // `hapticCooldown` — since a tap signals something worth looking up,
        // regardless of which microphone is the audio source. When the phone's
        // app is foregrounded the phone buzzes itself (the device in hand);
        // otherwise the wrist gets it.
        for reason in haptics {
            if appForegrounded {
                playLocalHaptic(reason: reason)
            } else {
                sendHapticToWatch(reason: reason)
            }
        }

        // The watch's "now hearing" screen always shows the *last* species
        // heard, interesting or not. Push the most-confident detection of this
        // window when it differs from what the watch is already showing, so a
        // continuously-singing bird isn't re-sent every window.
        if let top = results.max(by: { $0.confidence < $1.confidence }),
           top.scientificName != lastWatchDisplaySci {
            lastWatchDisplaySci = top.scientificName
            let highlight: String
            if starredNames.contains(top.scientificName) {
                highlight = "starred"
            } else if !lifeListSnapshot.contains(top.scientificName) {
                highlight = "newSpecies"
            } else {
                highlight = "normal"
            }
            sendBirdDisplayToWatch(
                commonName: top.commonName,
                scientificName: top.scientificName,
                highlight: highlight
            )
        }

        for id in repeatedIDs {
            flashIDs.insert(id)
        }

        // Sort by lastSeen so the most recently heard species is always at
        // the top. Reorder is animated so rows visibly slide into place.
        withAnimation(.easeInOut(duration: 0.3)) {
            detections = detectionMap.values.sorted { $0.lastSeen > $1.lastSeen }
        }

        for id in repeatedIDs {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                await MainActor.run { _ = self?.flashIDs.remove(id) }
            }
        }
    }

    // MARK: - Location + species filter

    private func refreshSpeciesFilter() async {
        guard let rangeFilter = await getRangeFilter() else {
            allowedIndices = nil
            locationStatus = "Showing all species"
            return
        }
        let location = await locationProvider.currentLocation()
        let week = SpeciesRangeFilter.birdnetWeek()
        if let location {
            LocationCache.shared.update(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            do {
                let allowed = try await rangeFilter.computeAndCache(
                    lat: location.coordinate.latitude,
                    lon: location.coordinate.longitude,
                    week: week
                )
                allowedIndices = allowed
                prefetchRegionImages(allowed)
                locationStatus = "Filtered to \(allowed.count) nearby species"
                return
            } catch {
                print("Kestrel: geo inference failed — \(error)")
            }
        }
        if let cached = await rangeFilter.loadCached() {
            allowedIndices = cached
            prefetchRegionImages(cached)
            locationStatus = "Using last-known list (\(cached.count) species)"
        } else {
            allowedIndices = nil
            locationStatus = "Showing all species (no location yet)"
        }
    }

    /// Kicks off a background download of the embed photos for the just-computed
    /// region species so they're cached and available offline.
    private func prefetchRegionImages(_ allowed: Set<Int>) {
        let all = SpeciesCatalog.shared.all
        let names = allowed.compactMap { all.indices.contains($0) ? all[$0].scientificName : nil }
        // The region just changed — refresh the set the image-cache cap
        // protects from eviction (life list + nearby) before prefetching.
        let lifeNames = lifeListStore?.entries.map(\.scientificName) ?? []
        RemoteSpeciesImageStore.shared.setProtectedSpecies(lifeNames + names)
        RemoteSpeciesImageStore.shared.prefetch(scientificNames: names)
    }

    // MARK: - System plumbing

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    private func registerInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                self.handleInterruption(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            if isRecording { pipeline.stop(); isRecording = false }
        case .ended:
            break
        @unknown default:
            break
        }
    }
}
