import Foundation

/// The photo manifest: `files` maps each photographed species' slug to a content
/// hash plus (in the *published* copy) its crediting/licensing metadata.
/// `scripts/build_species_photos.py` emits two forms: a hashes-only baseline
/// bundled with the app (`Models/photos_manifest.json`) and the full
/// metadata-carrying copy published to the photo repo's default branch (the copy
/// the app fetches to discover new and changed photos at runtime).
struct PhotoManifest: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let hash: String
        let credit: String?
        let license: String?
        let pageURL: String?
        let code: String?
    }

    let files: [String: Entry]

    init?(data: Data) {
        guard let decoded = try? JSONDecoder().decode(PhotoManifest.self, from: data) else {
            return nil
        }
        self = decoded
    }
}

/// Runtime source of truth for the *growable* photo set: which species have a
/// published photo, each one's content hash (the change signal), and — for
/// species added after the app shipped — their attribution metadata. This is
/// what lets photos be added to the CDN over time and picked up **without an app
/// update**.
///
/// It holds two things, both persisted so they survive relaunch:
///   • **hashes** — seeded from the bundled baseline, then updated as published
///     manifests are applied. Diffing an incoming manifest's hashes against these
///     is how new (unseen slug) and changed (different hash) photos are found.
///   • **metadata overlay** — the credit/license/page/code for every species a
///     fetched manifest has told us about. `SpeciesPhotoMetadata` prefers this
///     over its bundled `species_photos.json`, so a species that didn't exist in
///     the shipped build still renders with correct attribution.
///
/// `@unchecked Sendable` + an internal lock: read from view / prefetch /
/// background paths, mutated as manifests are applied.
nonisolated final class PhotoManifestStore: @unchecked Sendable {
    static let shared = PhotoManifestStore()

    private let lock = NSLock()
    /// slug → content hash of the photo the app believes is current. Seeded from
    /// the bundle, advanced as manifests are applied.
    private var hashes: [String: String]
    /// slug → attribution, for every species a fetched manifest has described.
    /// Empty until the first successful fetch; the bundled baseline carries no
    /// metadata (shipped species get theirs from `species_photos.json`).
    private var metadata: [String: SpeciesPhotoInfo]

    private static func localURL() -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("photos_manifest_local.json")
    }

    private init() {
        // Bundled baseline: hashes only.
        var bundledHashes: [String: String] = [:]
        if let url = Bundle.main.url(forResource: "photos_manifest", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let bundled = PhotoManifest(data: data) {
            bundledHashes = bundled.files.mapValues(\.hash)
        }

        // Persisted local state (hashes advanced by past applies + metadata
        // overlay), if any.
        var localHashes: [String: String] = [:]
        var localMetadata: [String: SpeciesPhotoInfo] = [:]
        if let url = Self.localURL(), let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder().decode(LocalSnapshot.self, from: data) {
            localHashes = snapshot.hashes
            localMetadata = snapshot.metadata.mapValues(\.info)
        }

        // Seed any slug the bundle knows but the local copy hasn't recorded yet —
        // e.g. species whose photos shipped in this app version. Never override a
        // locally-recorded hash (it may reflect a newer fetched manifest).
        for (slug, hash) in bundledHashes where localHashes[slug] == nil {
            localHashes[slug] = hash
        }

        hashes = localHashes
        metadata = localMetadata
    }

    // MARK: - Reads

    /// The attribution a fetched manifest supplied for a slug, if any. Nil for
    /// species only known from the bundle (they use `species_photos.json`).
    func overlayInfo(forSlug slug: String) -> SpeciesPhotoInfo? {
        lock.lock(); defer { lock.unlock() }
        return metadata[slug]
    }

    // MARK: - Apply

    struct ApplyResult: Sendable {
        var newSlugs: [String] = []
        var changedSlugs: [String] = []
    }

    /// Diffs a freshly-fetched published manifest against local state and records
    /// what it found.
    ///
    /// **New** species (a slug we've never seen) always have their hash + metadata
    /// recorded, so they become downloadable and attributable immediately. This is
    /// the "photos added over time" path and is safe to run anywhere (it only adds
    /// knowledge; nothing on disk to disturb).
    ///
    /// **Changed** species (known slug, different hash) are only *committed* when
    /// `includeChanged` is set — the caller (the high-power refresh) then drops and
    /// re-pulls their bytes. When it isn't (the cellular/foreground path), changed
    /// slugs are reported but left un-recorded, so a later high-power pass still
    /// sees them as changed and does the heavier re-download on Wi-Fi + power.
    func apply(_ remote: PhotoManifest, includeChanged: Bool) -> ApplyResult {
        lock.lock(); defer { lock.unlock() }
        var result = ApplyResult()
        for (slug, entry) in remote.files {
            let known = hashes[slug]
            if known == nil {
                hashes[slug] = entry.hash
                metadata[slug] = entry.info
                result.newSlugs.append(slug)
            } else if known != entry.hash {
                result.changedSlugs.append(slug)
                if includeChanged {
                    hashes[slug] = entry.hash
                    metadata[slug] = entry.info
                }
            } else {
                // Same hash: refresh the overlay metadata anyway so a credit fix
                // that didn't touch the image still propagates once fetched.
                metadata[slug] = entry.info
            }
        }
        persistLocked()
        return result
    }

    private func persistLocked() {
        guard let url = Self.localURL() else { return }
        let snapshot = LocalSnapshot(
            hashes: hashes,
            metadata: metadata.mapValues(CodableInfo.init)
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// On-disk shape for the persisted local manifest state.
private struct LocalSnapshot: Codable {
    let hashes: [String: String]
    let metadata: [String: CodableInfo]
}

/// Codable mirror of `SpeciesPhotoInfo` (which is decode-only from JSON) so the
/// metadata overlay can round-trip through the persisted snapshot.
private struct CodableInfo: Codable {
    let credit: String?
    let license: String?
    let pageURL: String?
    let code: String?

    init(_ info: SpeciesPhotoInfo) {
        credit = info.credit
        license = info.license
        pageURL = info.pageURL
        code = info.code
    }

    var info: SpeciesPhotoInfo {
        SpeciesPhotoInfo(credit: credit, license: license, pageURL: pageURL, code: code)
    }
}

private extension PhotoManifest.Entry {
    var info: SpeciesPhotoInfo {
        SpeciesPhotoInfo(credit: credit, license: license, pageURL: pageURL, code: code)
    }
}
