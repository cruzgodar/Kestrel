import Foundation

/// The two prefetchable species-photo sizes. The full-resolution (2400) tier is
/// deliberately absent — it's only ever fetched on demand when a card opens
/// full-screen, never queued. `pixels` is the size component the Macaulay CDN
/// serves (300 isn't a valid CDN size; 320 is the smallest, and it's exactly
/// what the watch's "now hearing" screen wants).
enum ImageSize: Sendable {
    case thumb
    case medium

    var pixels: Int {
        switch self {
        case .thumb: return 320
        case .medium: return 900
        }
    }
}

/// Ordered, bounded-concurrency prefetch queue with an in-flight coalescer,
/// shared by on-demand and background photo loads so no asset is ever fetched
/// twice at once.
///
/// Two ways in:
///   • `fetch` — on-demand. Starts (or joins) the download **immediately**,
///     jumping ahead of the background queue. Used by the views and the watch
///     bridge, which need the bytes now.
///   • `enqueue` — background prefetch. Four tiers drain strictly in order —
///     nearby thumbnails, then life-list thumbnails, then nearby medium, then
///     life-list medium — at most `maxConcurrent` at a time.
///
/// Both funnel through the same coalescing map (`inFlight`), keyed by
/// (slug, size), so a background item that an on-demand load already grabbed
/// resolves instantly instead of downloading a second time.
actor ImageDownloadQueue {
    /// Background prefetch tiers, drained low raw value → high. On-demand
    /// `fetch` bypasses these entirely.
    enum Tier: Int, CaseIterable, Sendable {
        case nearbyThumb
        case lifeListThumb
        case nearbyMedium
        case lifeListMedium
    }

    struct Request: Sendable {
        let slug: String
        let name: String
        let size: ImageSize
    }

    private struct Key: Hashable { let slug: String; let size: ImageSize }

    /// Downloads + persists one asset, returning its bytes (or nil). Supplied by
    /// the store; the queue only orchestrates ordering and coalescing.
    private let download: @Sendable (_ slug: String, _ name: String, _ size: ImageSize) async -> Data?
    private let maxConcurrent: Int

    private var tiers: [[Request]]
    private var queuedKeys: Set<Key> = []
    private var inFlight: [Key: Task<Data?, Never>] = [:]
    private var activeBulk = 0

    init(
        maxConcurrent: Int = 6,
        download: @escaping @Sendable (String, String, ImageSize) async -> Data?
    ) {
        self.maxConcurrent = maxConcurrent
        self.download = download
        self.tiers = Tier.allCases.map { _ in [] }
    }

    // MARK: - On-demand

    /// Begins (or joins) the download for one asset immediately and returns its
    /// bytes. This is the "bump to the top" path — it never waits behind the
    /// background tiers.
    func fetch(slug: String, name: String, size: ImageSize) async -> Data? {
        await run(Key(slug: slug, size: size), name: name)
    }

    // MARK: - Background prefetch

    /// Drops all not-yet-started background jobs so a fresh wake can
    /// re-prioritize from scratch. In-flight downloads keep running.
    func resetPrefetch() {
        tiers = Tier.allCases.map { _ in [] }
        queuedKeys.removeAll()
    }

    /// Appends background jobs to a tier, skipping any whose (slug, size) is
    /// already queued or in flight (so a species that's both nearby and on the
    /// life list is fetched once, at its earlier tier). Kicks the pump.
    func enqueue(_ requests: [Request], tier: Tier) {
        for request in requests {
            let key = Key(slug: request.slug, size: request.size)
            guard !queuedKeys.contains(key), inFlight[key] == nil else { continue }
            queuedKeys.insert(key)
            tiers[tier.rawValue].append(request)
        }
        pump()
    }

    // MARK: - Internals

    /// Coalesced single-asset download. Concurrent callers for the same key all
    /// await one shared task; the entry is cleared once it resolves.
    private func run(_ key: Key, name: String) async -> Data? {
        if let existing = inFlight[key] { return await existing.value }
        let download = self.download
        let task = Task<Data?, Never> {
            await download(key.slug, name, key.size)
        }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        return data
    }

    private func nextRequest() -> Request? {
        for index in tiers.indices where !tiers[index].isEmpty {
            let request = tiers[index].removeFirst()
            queuedKeys.remove(Key(slug: request.slug, size: request.size))
            return request
        }
        return nil
    }

    /// Fills idle worker slots from the highest-priority non-empty tier.
    private func pump() {
        while activeBulk < maxConcurrent, let request = nextRequest() {
            activeBulk += 1
            Task { await self.drain(request) }
        }
    }

    private func drain(_ request: Request) async {
        _ = await run(Key(slug: request.slug, size: request.size), name: request.name)
        activeBulk -= 1
        pump()
    }
}
