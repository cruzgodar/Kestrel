import Foundation

/// Per-species photo metadata for the CC-licensed image set. Sourced entirely
/// from the published photo manifest the app fetches at runtime (see
/// `PhotoManifestStore`) — nothing about the photo set ships in the app bundle,
/// so photos and attribution can be corrected or extended without an app
/// update. The image bytes themselves are *not* referenced here —
/// `RemoteSpeciesImageStore` derives each size's URL from the slug and a
/// jsDelivr base — so this holds only the crediting/licensing info an entry
/// needs: photographer, license, and the source page for verification.
/// `nonisolated` for the same reason `SpeciesPhotoMetadata` is: it is read and
/// persisted from the off-main manifest paths, and the project's default
/// isolation would otherwise pin this plain value type to the main actor.
nonisolated struct SpeciesPhotoInfo: Decodable {
    /// Photographer / contributor name, when the source page exposed one.
    let credit: String?
    /// License string as published at the source (e.g. "CC BY-SA 4.0", "CC0").
    let license: String?
    /// Source page (Wikimedia Commons / iNaturalist), where the license and
    /// attribution can be verified.
    let pageURL: String?
    /// eBird species code (e.g. "rufwar1"), as the manifest publishes it.
    /// Carried through and persisted, but nothing in the app reads it yet — the
    /// accessor that built an eBird species link from it had no callers and is
    /// gone. Kept because it costs a nullable string and is the manifest's to
    /// give, not ours to re-derive.
    let code: String?

    init(credit: String?, license: String?, pageURL: String?, code: String?) {
        self.credit = credit
        self.license = license
        self.pageURL = pageURL
        self.code = code
    }

    /// Attribution line for the CC-licensed photo: just the photographer's name.
    ///
    /// The license is deliberately left out — it's carried by the separate
    /// `license` field and verifiable on the source page the caption links to,
    /// so repeating it here only crowds the line. Source credits arrive in a
    /// boilerplate form ("(c) Name, some rights reserved (CC BY-NC)") that
    /// smuggles the same license back in, so `displayCredit` strips it (along
    /// with the copyright mark and the rights-reserved phrase) rather than
    /// letting it through the back door.
    ///
    /// Falls back to the license — and then to "Public domain" — only when
    /// there's no photographer to name at all, where an empty caption would be
    /// worse than a bare license.
    var attribution: String {
        // Cleaning can empty a credit that was nothing but boilerplate, so the
        // fallbacks are checked against the cleaned result rather than the raw.
        if let name = credit?.nilIfEmpty.map(Self.displayCredit)?.nilIfEmpty {
            return name
        }
        return license?.nilIfEmpty ?? "Public domain"
    }

    /// The full-screen viewer's caption: the photographer marked with a
    /// copyright sign, then the license the photo is used under —
    /// `"© Miguel A Mejias, PhD. • CC BY-NC"`. The inline credit overlay stays on
    /// the bare `attribution`, where a corner of the image is all the room there
    /// is for a name.
    ///
    /// Either half can be missing at the source. No license on record leaves just
    /// `"© Name"`; no photographer falls back to `attribution` untouched, since
    /// "© CC BY-SA 4.0" would credit the license as though it were a person and
    /// "© Public domain" contradicts itself.
    var attributionWithLicense: String {
        guard let name = credit?.nilIfEmpty.map(Self.displayCredit)?.nilIfEmpty else {
            return attribution
        }
        guard let license = license?.nilIfEmpty else { return "© \(name)" }
        return "© \(name) • \(license)"
    }

    /// Strips the syndicated-credit boilerplate down to the photographer's name:
    /// `"(c) Miguel A Mejias, PhD., some rights reserved (CC BY-NC)"` becomes
    /// `"Miguel A Mejias, PhD."`.
    ///
    /// The trailing-parenthetical rule requires a license-ish token inside the
    /// parentheses, so a name that legitimately ends in one — "Alvaro Rivera
    /// Rojas (brújula de aves)" — survives intact.
    /// `nonisolated` because `attribution` is read off the main actor (see
    /// `SpeciesPhotoMetadata`, itself nonisolated), and this module defaults to
    /// MainActor isolation.
    nonisolated static func displayCredit(_ raw: String) -> String {
        var text = raw
        // Leading copyright mark: "(c) ", "(C) ", "© ".
        text = text.replacingOccurrences(
            of: #"^\s*(?:\(c\)|©)\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // "…, some rights reserved" / "…, all rights reserved", comma included.
        text = text.replacingOccurrences(
            of: #",?\s*(?:some|all)\s+rights\s+reserved"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Trailing license parenthetical: "(CC BY-NC)", "(CC0 1.0)", "(GFDL)".
        text = text.replacingOccurrences(
            of: #"\s*\([^)]*(?:CC|Creative Commons|public domain|GFDL|BY-|SA)[^)]*\)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Trailing separators left behind by the removals above. A trailing
        // period is kept — "PhD." needs it.
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;·-"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Link to the photo's source page, so a tap can verify the license and
    /// attribution.
    var sourceURL: URL? {
        guard let pageURL, !pageURL.isEmpty else { return nil }
        return URL(string: pageURL)
    }
}

/// `nonisolated` so the attribution strings above — built off the main actor
/// while a manifest is applied — can use it.
private nonisolated extension String {
    /// The string, or `nil` when it has nothing to show — which includes a value
    /// that is only whitespace.
    ///
    /// Manifest fields come from a photo set assembled by hand, so a credit of
    /// `" "` is a thing that reaches this. Testing `isEmpty` alone let it past,
    /// and the viewer rendered a blank credit line instead of falling back to the
    /// license — the fallback exists precisely for a photo with no named author.
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Metadata lookup for the photo set, backed solely by `PhotoManifestStore` —
/// i.e. by the manifest fetched from the photo repo and persisted locally.
///
/// There is deliberately no bundled copy to fall back on. A bundled base would
/// pin every shipped species' credit and license to the app binary, so fixing an
/// attribution or swapping a photo would mean an App Store submission; with the
/// manifest as the only source, publishing to the photo repo is the whole
/// update. The cost is that a fresh install knows about no photos until its
/// first manifest fetch (see `KestrelApp.refreshPhotosOnForeground`), which
/// costs nothing in practice: the images are remote too, so an install that
/// can't reach the network has no photos to attribute either way.
///
/// This gate is load-bearing for licensing, not just display:
/// `RemoteSpeciesImageStore` refuses to download or show any photo whose
/// `info(for:)` is nil, so an image can never appear without the credit and
/// license that came with it in the same manifest.
nonisolated final class SpeciesPhotoMetadata: @unchecked Sendable {
    nonisolated static let shared = SpeciesPhotoMetadata()

    private init() {}

    func info(for scientificName: String) -> SpeciesPhotoInfo? {
        let slug = SpeciesImage.slug(for: scientificName)
        guard !slug.isEmpty else { return nil }
        return PhotoManifestStore.shared.info(forSlug: slug)
    }
}
