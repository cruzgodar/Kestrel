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
}

/// Wakes waiting photo loads early, when another try is likely to work: the
/// network has come back, a manifest has changed which species have photos,
/// or the app has come back to the foreground.
@MainActor
final class PhotoRetrySignal {
    static let shared = PhotoRetrySignal()

    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let monitor = NWPathMonitor()
    private var wasOnline: Bool?

    private init() {
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
        for continuation in pending.values { continuation.resume() }
    }

    /// Suspends until `fire`, `delay` has passed, or the task is cancelled —
    /// whichever comes first.
    func wait(upTo delay: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                // Cancelled before it was registered: the handler below has
                // already run and found nothing to resume.
                if Task.isCancelled { resume(id) }
                Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    self.resume(id)
                }
            }
        } onCancel: {
            Task { @MainActor in PhotoRetrySignal.shared.resume(id) }
        }
    }

    private func resume(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
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
/// no photo, and a download arrow in a circle while its photo is on the way.
/// Callers dress it — font, colour, background — exactly as they did the bird
/// symbol it replaces.
struct SpeciesPhotoPlaceholderGlyph: View {
    @Environment(\.speciesPhotoIsDownloading) private var isDownloading

    var body: some View {
        Image(systemName: isDownloading ? "arrow.down.circle" : "bird")
            .accessibilityLabel(isDownloading ? "Downloading photo" : "No photo")
    }
}
