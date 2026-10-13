import Network
import SwiftUI
import UIKit

// MARK: - Retrying a load

/// Keeps a species photo loading until it arrives.
///
/// The store makes one attempt per call and gives up on any failure — a
/// timeout, a dropped connection, a CDN hiccup. Every species the manifest
/// lists has every size published, so a failure is never the final word on a
/// photo that is on screen: showing the placeholder and stopping there left a
/// tile blank for as long as the view lived, while the same bird's other size,
/// fetched a moment later, came through fine.
///
/// So a view keeps asking for as long as it is showing the bird, backing off
/// between attempts and cutting the wait short whenever a retry is likely to
/// go differently (see `PhotoRetrySignal`). A species with no photo published
/// at all is the one honest "no", and even that is only waited out until the
/// next manifest might change it.
enum SpeciesPhotoLoading {
    /// The first wait after a failure; each later one doubles, up to
    /// `maxDelay`.
    static let firstDelay: Duration = .seconds(1)
    static let maxDelay: Duration = .seconds(30)
    /// How long a bird with no published photo waits before checking again,
    /// should no manifest arrive to wake it sooner.
    static let unpublishedRecheck: Duration = .seconds(300)

    /// What a loader reports while it works, so its view can choose between
    /// the download indicator and the "no photo" placeholder.
    enum Phase {
        /// The photo exists and is on its way, or will be on the next try.
        case downloading
        /// No photo is published for this species.
        case unpublished
    }

    /// Calls `attempt` until it returns an image or the task is cancelled.
    /// Returns nil only on cancellation.
    static func load(
        _ scientificName: String,
        phase: (Phase) -> Void,
        attempt: () async -> UIImage?
    ) async -> UIImage? {
        var delay = firstDelay
        while !Task.isCancelled {
            guard RemoteSpeciesImageStore.shared.isPhotographed(scientificName) else {
                phase(.unpublished)
                await PhotoRetrySignal.shared.wait(upTo: unpublishedRecheck)
                continue
            }
            phase(.downloading)
            if let image = await attempt() { return image }
            guard !Task.isCancelled else { return nil }
            await PhotoRetrySignal.shared.wait(upTo: delay)
            delay = min(delay * 2, maxDelay)
        }
        return nil
    }

    /// Warms the medium photos either side of `index` in a swipeable viewer,
    /// so a swipe lands on a bird already in memory rather than on the
    /// download indicator.
    ///
    /// Waits for the bird on screen first — it is the one being looked at, and
    /// its neighbours shouldn't compete with it for the network — then fetches
    /// the next bird, and only after that one the previous. Run it from a
    /// `.task(id:)` keyed on the page, so turning the page cancels it and starts
    /// over around the new bird. Neighbours get one try each: their own page
    /// retries properly if the user does swipe to them.
    static func prefetchNeighbors(of names: [String], at index: Int) async {
        guard names.indices.contains(index) else { return }
        let store = RemoteSpeciesImageStore.shared
        let current = names[index]
        if store.isPhotographed(current), store.memoryImage(for: current) == nil {
            // Nil only when cancelled: the page has moved on.
            guard await load(current, phase: { _ in }, attempt: {
                await store.image(for: current)
            }) != nil else { return }
        }
        for neighbor in [index + 1, index - 1] where names.indices.contains(neighbor) {
            guard !Task.isCancelled else { return }
            let name = names[neighbor]
            guard store.isPhotographed(name), store.memoryImage(for: name) == nil else { continue }
            _ = await store.image(for: name)
        }
    }
}

/// Wakes waiting photo loads early, when another try is likely to work: the
/// network has come back, a manifest has changed which species have photos,
/// or the app has come back to the foreground.
@MainActor
final class PhotoRetrySignal {
    static let shared = PhotoRetrySignal()

    /// One suspended load: how to wake it, and the timer that will if nothing
    /// else does first.
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
        let timer: Task<Void, Never>
    }

    private var waiters: [UUID: Waiter] = [:]
    private let monitor = NWPathMonitor()
    private var wasOnline: Bool?

    /// How many loads are waiting. Read by the tests.
    var waitingCount: Int { waiters.count }

    /// Timers still asleep. Each wait's timer is stopped the moment its waiter
    /// is woken any other way; it used to sleep out its whole delay — up to
    /// five minutes for an unpublished species — and every foreground or
    /// network change re-armed every waiter with another, so they piled up.
    /// Read by the tests, which is how a timer left running shows up.
    private(set) var sleepingTimers = 0

    /// - Parameter watchesSystem: Whether the network coming back and the app
    ///   coming to the foreground wake the waiters. Off only in tests, which
    ///   call `fire` themselves; the handlers below reach the shared instance.
    init(watchesSystem: Bool = true) {
        guard watchesSystem else { return }
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in PhotoRetrySignal.shared.pathChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "PhotoRetrySignal.path"))
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { PhotoRetrySignal.shared.fire() }
        }
    }

    /// Wakes everything waiting. Safe to call from anywhere.
    nonisolated static func fireFromAnywhere() {
        Task { @MainActor in PhotoRetrySignal.shared.fire() }
    }

    func fire() {
        let pending = waiters
        waiters = [:]
        for waiter in pending.values {
            waiter.timer.cancel()
            waiter.continuation.resume()
        }
    }

    /// Suspends until `fire`, `delay` has passed, or the task is cancelled —
    /// whichever comes first.
    func wait(upTo delay: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                sleepingTimers += 1
                let timer = Task { @MainActor in
                    defer { self.sleepingTimers -= 1 }
                    try? await Task.sleep(for: delay)
                    // Stopped because its waiter was woken some other way.
                    guard !Task.isCancelled else { return }
                    self.resume(id)
                }
                waiters[id] = Waiter(continuation: continuation, timer: timer)
                // Cancelled before it was registered: the handler below has
                // already run and found nothing to resume.
                if Task.isCancelled { resume(id) }
            }
        } onCancel: {
            Task { @MainActor in self.resume(id) }
        }
    }

    private func resume(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume()
    }

    private func pathChanged(online: Bool) {
        defer { wasOnline = online }
        // Back online: everything that failed while offline can go again now
        // rather than at the end of its backoff.
        if online, wasOnline == false { fire() }
    }
}

// MARK: - Placeholder glyph

extension EnvironmentValues {
    /// Whether the species photo a placeholder stands in for is on its way,
    /// rather than not published at all.
    @Entry var speciesPhotoIsDownloading = false
}

/// The glyph a species photo's placeholder shows: a bird when the species has
/// no photo, and a pulsing cloud while its photo is on the way.
/// Callers dress it — font, colour, background — exactly as they did the bird
/// symbol it replaces.
struct SpeciesPhotoPlaceholderGlyph: View {
    @Environment(\.speciesPhotoIsDownloading) private var isDownloading

    var body: some View {
        Image(systemName: isDownloading ? "cloud" : "bird")
            .symbolEffect(.pulse, options: .repeating, isActive: isDownloading)
            .accessibilityLabel(isDownloading ? "Downloading photo" : "No photo")
    }
}
