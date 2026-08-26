import BackgroundTasks
import Foundation
import Network

/// Owns the app's two `BGTaskScheduler` jobs, both about keeping species photos
/// available offline without the app in the foreground:
///
///   • **prefetch** (`BGAppRefreshTask`) — resumes the region + life-list photo
///     prefetch. iOS runs app-refresh tasks opportunistically and *without*
///     requiring power or Wi-Fi, so a traveler who computed a region on Wi-Fi but
///     left before it finished keeps filling it in over cellular in ~30 s bursts.
///     Each fire re-enqueues from scratch; already-downloaded files are skipped,
///     so successive fires chip away at whatever's left.
///
///   • **imageRefresh** (`BGProcessingTask`) — the high-power photo-update pass.
///     Requested with `requiresExternalPower`, and additionally gated here on an
///     unmetered (Wi-Fi) path, so it only runs plugged in on Wi-Fi. It fetches
///     the published manifest and both discovers newly-added photos and
///     re-downloads changed ones (see
///     `RemoteSpeciesImageStore.checkForPhotoUpdates`).
///
/// Register once at launch (before the app finishes launching) and schedule both
/// whenever the app backgrounds. Each handler reschedules its own next run.
///
/// `@unchecked Sendable`: `BGTaskScheduler` delivers launch handlers on a private
/// queue (not guaranteed the main thread), so this type does its own locking and
/// hops to the main actor only for the one main-actor read it needs (the life
/// list). The `BGTask` itself is shuttled into the async work via
/// `TaskCompletionBox`, which serializes the `setTaskCompleted` call.
final class BackgroundRefreshCoordinator: @unchecked Sendable {
    static let shared = BackgroundRefreshCoordinator()

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let prefetchTaskID = "com.cruzgodar.Kestrel.prefetch"
    static let imageUpdateTaskID = "com.cruzgodar.Kestrel.imageRefresh"

    private let lock = NSLock()
    /// Reads the current life-list scientific names on the main actor. Set at
    /// launch so a background prefetch can protect + warm them even when no view
    /// is mounted to supply them.
    private var lifeListNamesProvider: (@MainActor @Sendable () -> [String])?
    private var registered = false

    private init() {}

    /// Registers both task handlers. Call from the app's initializer — task
    /// handlers must be registered before launch completes. Idempotent; only the
    /// first call registers, later calls just refresh the life-list provider.
    func register(lifeListNames: @escaping @MainActor @Sendable () -> [String]) {
        lock.lock()
        lifeListNamesProvider = lifeListNames
        let alreadyRegistered = registered
        registered = true
        lock.unlock()
        guard !alreadyRegistered else { return }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.prefetchTaskID, using: nil
        ) { [weak self] task in
            self?.handlePrefetch(task)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.imageUpdateTaskID, using: nil
        ) { [weak self] task in
            self?.handleImageUpdate(task)
        }
    }

    private func currentProvider() -> (@MainActor @Sendable () -> [String])? {
        lock.lock(); defer { lock.unlock() }
        return lifeListNamesProvider
    }

    // MARK: - Scheduling

    /// Submit both requests. Call when the app moves to the background.
    func scheduleAll() {
        schedulePrefetch()
        scheduleImageUpdate()
    }

    private func schedulePrefetch() {
        let request = BGAppRefreshTaskRequest(identifier: Self.prefetchTaskID)
        // Soonest the system may run it; iOS still decides the actual time.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Code 1 (unavailable) is expected on the simulator and when
            // Background App Refresh is off — logged at info, not error.
            Log.info("Prefetch task submit failed: \(error)")
        }
    }

    private func scheduleImageUpdate() {
        let request = BGProcessingTaskRequest(identifier: Self.imageUpdateTaskID)
        request.requiresNetworkConnectivity = true
        // "High power": only while charging. Wi-Fi is enforced separately in the
        // handler — there's no per-request unmetered flag.
        request.requiresExternalPower = true
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.info("Image-update task submit failed: \(error)")
        }
    }

    // MARK: - Handlers

    private func handlePrefetch(_ task: BGTask) {
        // Reschedule up front so a crash mid-run doesn't drop the chain.
        schedulePrefetch()

        let provider = currentProvider()
        let completion = TaskCompletionBox(task)
        let op = Task {
            // Discover photos added to the CDN (cellular is fine — this only pulls
            // the small manifest, then the new nearby/life-list images). Changed
            // photos are deferred to the Wi-Fi + power pass.
            await RemoteSpeciesImageStore.shared.checkForPhotoUpdates(includeChanged: false)

            let lifeNames = await MainActor.run { provider?() ?? [] }
            let nearby = RemoteSpeciesImageStore.nearbyNames()
            RemoteSpeciesImageStore.shared.setProtectedSpecies(
                RemoteSpeciesImageStore.launchTargets(lifeList: lifeNames)
            )
            await RemoteSpeciesImageStore.shared.prefetchWakeAwaitingDrain(
                lifeList: lifeNames, nearby: nearby
            )
            completion.complete(success: !Task.isCancelled)
        }
        // Cancelling the work is not the same as finishing it: `setTaskCompleted`
        // still has to be called, or iOS scores the window as a failure and
        // throttles this task's future scheduling. `complete` is idempotent, so
        // whichever of the two gets there first wins.
        completion.setExpirationHandler {
            op.cancel()
            completion.complete(success: false)
        }
    }

    private func handleImageUpdate(_ task: BGTask) {
        scheduleImageUpdate()

        let provider = currentProvider()
        let completion = TaskCompletionBox(task)
        let op = Task {
            // The request guaranteed power; also require Wi-Fi (unmetered) so a
            // metered/hotspot connection doesn't burn the user's data on a
            // rarely-needed refresh.
            guard await Self.isOnUnmeteredNetwork() else {
                Log.info("Image-update task skipped: metered network")
                completion.complete(success: false)
                return
            }
            // Plugged in on Wi-Fi: the full pass — discover new photos *and*
            // re-download changed ones.
            let result = await RemoteSpeciesImageStore.shared.checkForPhotoUpdates(includeChanged: true)
            Log.info(
                "Image-update task: \(result.newCount) new, \(result.changedCount) changed "
                + "(\(result.refreshedCount) re-downloaded)"
            )
            // Then sweep anything whose one-day freshness window has lapsed but
            // that the change diff didn't touch, so the whole cache gets
            // re-confirmed even when the app is rarely foregrounded.
            //
            // Handed the manifest the pass above already fetched: the two passes
            // want the same file, and downloading it twice in one background
            // window was pure waste.
            let revalidated = await RemoteSpeciesImageStore.shared.revalidateStaleImages(
                using: result.manifest
            )
            if !revalidated.isEmpty {
                Log.info(
                    "Revalidation: \(revalidated.confirmed) confirmed, "
                    + "\(revalidated.refreshed) refreshed, \(revalidated.failed) deferred, "
                    + "\(revalidated.withdrawn) withdrawn, "
                    + "\(revalidated.discoveredSlugs.count) newly published"
                )
            }

            // Both passes above *record* the slugs they discovered, which is what
            // makes them downloadable — and also what stops any later pass from
            // ever reporting them as new again. So this is the one chance to warm
            // them: without a prefetch here a newly published photo for a
            // life-list species would only ever arrive one lazy load at a time,
            // as its row happened to scroll into view. `handlePrefetch` and the
            // foreground check both already do this; this task was the hole.
            //
            // And it is the best possible moment for it — the task ran at all
            // only because the device is plugged in and on Wi-Fi.
            // `changedCount`, not `refreshedCount`: a changed species whose bytes
            // weren't cached is never "refreshed", but its hash was advanced so a
            // lazy load would fetch the new photo — which is exactly the trickle
            // this prefetch exists to pre-empt.
            if result.newCount > 0 || result.changedCount > 0
                || !revalidated.discoveredSlugs.isEmpty {
                let lifeNames = await MainActor.run { provider?() ?? [] }
                RemoteSpeciesImageStore.shared.setProtectedSpecies(
                    RemoteSpeciesImageStore.launchTargets(lifeList: lifeNames)
                )
                await RemoteSpeciesImageStore.shared.prefetchWakeAwaitingDrain(
                    lifeList: lifeNames,
                    nearby: RemoteSpeciesImageStore.nearbyNames()
                )
            }
            completion.complete(success: !Task.isCancelled)
        }
        // Cancelling the work is not the same as finishing it: `setTaskCompleted`
        // still has to be called, or iOS scores the window as a failure and
        // throttles this task's future scheduling. `complete` is idempotent, so
        // whichever of the two gets there first wins.
        completion.setExpirationHandler {
            op.cancel()
            completion.complete(success: false)
        }
    }

    // MARK: - Network check

    /// How long to wait for `NWPathMonitor` to report before giving up. It fires
    /// almost immediately in practice; this exists so the wait can't be
    /// unbounded (see `isOnUnmeteredNetwork`).
    private static let pathResolveTimeout: DispatchTimeInterval = .seconds(5)

    /// Resolves whether the current path is a satisfied, unmetered (Wi-Fi/wired)
    /// connection. Used to keep the high-power image refresh off cellular.
    ///
    /// Always resolves. A `withCheckedContinuation` cannot be cancelled, so a
    /// monitor that never reported would park this task forever — and the
    /// background window it runs in would then expire with its work neither
    /// finished nor abandoned. The timeout answers `false`, which is the safe
    /// direction: the caller skips the refresh and reschedules rather than
    /// spending the user's data on a connection it couldn't classify.
    static func isOnUnmeteredNetwork() async -> Bool {
        // `nonisolated` as well as `@unchecked Sendable`: the project is
        // MainActor-by-default, so without it this box is main-actor isolated
        // and the path handler — which runs on its own queue — can't touch it.
        // The lock is what actually makes the flag safe.
        nonisolated final class Box: @unchecked Sendable {
            let lock = NSLock()
            var resumed = false

            /// True for exactly one caller, so the continuation is resumed once
            /// however the race between the monitor and the timeout falls out.
            func claim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if resumed { return false }
                resumed = true
                return true
            }
        }
        let box = Box()
        let queue = DispatchQueue(label: "com.cruzgodar.Kestrel.netcheck")
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                guard box.claim() else { return }
                monitor.cancel()
                let unmetered = path.status == .satisfied
                    && !path.isExpensive
                    && !path.isConstrained
                cont.resume(returning: unmetered)
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.pathResolveTimeout) {
                guard box.claim() else { return }
                monitor.cancel()
                Log.info("Network check timed out; treating the path as metered")
                cont.resume(returning: false)
            }
        }
    }
}

/// Serializes completion of a `BGTask` whose work runs on a Swift concurrency
/// task that may resume on a different thread than the one the launch handler
/// was delivered on. Guards against calling `setTaskCompleted` twice (e.g. both
/// the work finishing and the expiration handler firing). `@unchecked Sendable`:
/// the lock makes the single mutable field safe to touch across threads.
private final class TaskCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: BGTask?

    init(_ task: BGTask) { self.task = task }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.expirationHandler = handler
    }

    func complete(success: Bool) {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.setTaskCompleted(success: success)
    }
}
