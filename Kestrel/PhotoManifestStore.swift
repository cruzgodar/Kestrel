import Foundation

/// A photo manifest: a global `version` (the jsDelivr git tag the app fetches
/// images from — empty means "serve from the default branch") plus a
/// slug→content-hash map. `scripts/build_species_photos.py` emits it in three
/// places: the app bundle (`Models/photos_manifest.json`, the baseline shipped
/// with each build), the published photo repo's default branch (the copy the
/// app fetches to detect updates), and the git tag named by `version`.
struct PhotoManifest: Decodable, Sendable {
    let version: String
    let files: [String: String]

    init(version: String, files: [String: String]) {
        self.version = version
        self.files = files
    }

    init?(data: Data) {
        guard let decoded = try? JSONDecoder().decode(PhotoManifest.self, from: data) else {
            return nil
        }
        self = decoded
    }
}

/// Tracks which photo *version* the app is serving and the content hash of each
/// species' image bytes as they exist locally, so the high-power "check for
/// updated images" pass can re-download only what actually changed (see
/// `RemoteSpeciesImageStore.refreshUpdatedImages`).
///
/// Two manifests feed it:
///   • **bundled** (`Models/photos_manifest.json`) — the baseline shipped with
///     the build. Reconciled at launch: any slug whose bundled hash differs from
///     what's recorded locally shipped an updated photo, so its stale on-disk
///     copy is invalidated (by the image store) and the newer `version` adopted.
///   • **remote** (fetched from the photo repo's branch) — diffed by the
///     background refresh to catch photos updated *after* this build shipped.
///
/// The locally-recorded hash is the app's notion of "what the bytes at
/// `currentVersion` hash to" for each slug — it's what incoming manifests are
/// diffed against. `@unchecked Sendable` + an internal lock: read from view/
/// prefetch/background paths, mutated as manifests are applied.
nonisolated final class PhotoManifestStore: @unchecked Sendable {
    static let shared = PhotoManifestStore()

    /// The manifest baked into this build. Nil only if the build script hasn't
    /// emitted one yet (older builds), in which case reconciliation is a no-op.
    let bundled: PhotoManifest?

    private let lock = NSLock()
    /// The app's persisted view of what's on disk: the version whose bytes the
    /// image URLs point at, and each slug's recorded content hash.
    private var localVersion: String
    private var localHashes: [String: String]

    private static func localURL() -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("photos_manifest_local.json")
    }

    private init() {
        let bundled: PhotoManifest?
        if let url = Bundle.main.url(forResource: "photos_manifest", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            bundled = PhotoManifest(data: data)
        } else {
            bundled = nil
        }
        self.bundled = bundled

        if let url = Self.localURL(), let data = try? Data(contentsOf: url),
           let local = PhotoManifest(data: data) {
            localVersion = local.version
            localHashes = local.files
        } else {
            // First run (or unreadable): seed from the bundled baseline so the
            // app starts out believing disk matches the shipped version. Nothing
            // is on disk yet, so there's nothing to invalidate.
            localVersion = bundled?.version ?? ""
            localHashes = bundled?.files ?? [:]
            persistLocked()
        }
    }

    /// The jsDelivr ref image URLs are built from. Empty → the default branch.
    var currentVersion: String {
        lock.lock(); defer { lock.unlock() }
        return localVersion
    }

    /// Slugs whose `incoming` hash differs from what's recorded locally — i.e.
    /// species whose photo changed relative to what the app has. Slugs present in
    /// `incoming` but not locally are treated as changed too (a newly-added
    /// photo), so the fresh version is fetched.
    func changedSlugs(against incoming: PhotoManifest) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return incoming.files.compactMap { slug, hash in
            localHashes[slug] == hash ? nil : slug
        }
    }

    /// Adopts an incoming manifest's version so subsequent image URLs point at
    /// its bytes. Call *before* re-downloading changed slugs so the new bytes are
    /// fetched from the right ref; record each slug's new hash with
    /// `markResolved` only once its bytes are actually handled.
    func adoptVersion(_ version: String) {
        lock.lock(); defer { lock.unlock() }
        guard version != localVersion else { return }
        localVersion = version
        persistLocked()
    }

    /// Records that a slug's local bytes now match `hash` (after its stale copy
    /// was invalidated / re-downloaded at the current version). Persisted so a
    /// later run doesn't re-flag it.
    func markResolved(slug: String, hash: String) {
        lock.lock(); defer { lock.unlock() }
        guard localHashes[slug] != hash else { return }
        localHashes[slug] = hash
        persistLocked()
    }

    /// The hash `incoming` records for a slug, if any — the value to pass to
    /// `markResolved` once the slug's bytes have been refreshed.
    func hash(forSlug slug: String, in manifest: PhotoManifest) -> String? {
        manifest.files[slug]
    }

    private func persistLocked() {
        guard let url = Self.localURL() else { return }
        let snapshot = PhotoManifestSnapshot(version: localVersion, files: localHashes)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Encodable mirror of `PhotoManifest` for persisting the local copy (the
/// decodable type is intentionally read-only from JSON).
private struct PhotoManifestSnapshot: Encodable {
    let version: String
    let files: [String: String]
}
