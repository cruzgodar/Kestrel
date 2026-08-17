import Foundation

/// The photo manifest: `files` maps each photographed species' slug to a content
/// hash plus its crediting/licensing metadata. `build_species_photos.py` (in the
/// Bird Image Selector repo) publishes it to the photo repo's default branch
/// alongside the rendered images, and the app fetches it at runtime. Nothing
/// about the photo set is bundled — this manifest is the app's only knowledge of
/// which species have photos and who took them, which is what lets the set (and
/// its attribution) be corrected or extended without an App Store submission.
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
///   • **hashes** — recorded as published manifests are applied. Diffing an
///     incoming manifest's hashes against these is how new (unseen slug) and
///     changed (different hash) photos are found.
///   • **metadata** — the credit/license/page/code for every species a fetched
///     manifest has told us about. This is the *only* source of photo metadata
///     in the app (`SpeciesPhotoMetadata` reads nothing else), so a slug missing
///     here has no photo as far as the rest of the app is concerned.
///
/// A fresh install therefore knows about no photos until its first successful
/// fetch. That's the intended trade: the images are remote anyway, so an install
/// that can't reach the network has nothing to show regardless, and in exchange
/// no photo, credit, or license is frozen into the app binary.
///
/// `@unchecked Sendable` + an internal lock: read from view / prefetch /
/// background paths, mutated as manifests are applied.
nonisolated final class PhotoManifestStore: @unchecked Sendable {
    static let shared = PhotoManifestStore()

    private let lock = NSLock()
    /// slug → content hash of the photo the app believes is current, advanced as
    /// manifests are applied.
    private var hashes: [String: String]
    /// slug → attribution, for every species a fetched manifest has described.
    /// Empty until the first successful fetch.
    private var metadata: [String: SpeciesPhotoInfo]

    private static func localURL() -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("photos_manifest_local.json")
    }

    private init() {
        // Persisted state from past applies, if any. There is no bundled seed:
        // everything the app knows about the photo set was fetched.
        var localHashes: [String: String] = [:]
        var localMetadata: [String: SpeciesPhotoInfo] = [:]
        if let url = Self.localURL(), let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder().decode(LocalSnapshot.self, from: data) {
            localHashes = snapshot.hashes
            localMetadata = snapshot.metadata.mapValues(\.info)
        }

        hashes = localHashes
        metadata = localMetadata
    }

    // MARK: - Reads

    /// The attribution a fetched manifest supplied for a slug, if any. Nil means
    /// the app has no photo for that species — either none is published or no
    /// manifest has been fetched yet — and every image read path treats it that
    /// way (see `RemoteSpeciesImageStore.isAttributed`).
    func info(forSlug slug: String) -> SpeciesPhotoInfo? {
        lock.lock(); defer { lock.unlock() }
        return metadata[slug]
    }

    /// Whether any slug's hash is on record without its metadata — the state an
    /// install left in by upgrading from a build that bundled `species_photos.json`
    /// and seeded hashes from `photos_manifest.json`. Those species would show no
    /// photo until the next manifest fetch, so the foreground check skips its
    /// throttle while this is true and the gap closes on the first launch of the
    /// new build.
    var needsMetadataBackfill: Bool {
        lock.lock(); defer { lock.unlock() }
        return hashes.keys.contains { metadata[$0] == nil }
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
