import SwiftUI

/// Trailing thumbnail used by both the detection list (Identify tab) and the
/// Life List. Pinned to a constant 4:3 box (matching the dominant aspect
/// ratio of the species photos) so every row's trailing edge — and thus the
/// row's star button — lines up cleanly regardless of whether an image is
/// present. Non-4:3 photos are `.scaledToFill`-clipped into the box; rows with
/// no image render an SF-symbol placeholder of the same dimensions.
struct SpeciesThumbnail: View {
    let scientificName: String
    var height: CGFloat = 60
    /// How round the photograph's corners are. The rows' own value by default,
    /// so nothing that doesn't ask changes; the Life List's grid asks for a
    /// rounder one, its pictures being both bigger and the whole of the tile.
    var cornerRadius: CGFloat = 6
    /// Optional override for the photo tap (see `SpeciesPhoto.onTap`).
    var onTap: (() -> Void)? = nil

    @Environment(\.displayScale) private var displayScale

    /// 4:3 — matches the dominant species-photo aspect ratio.
    private var width: CGFloat { height * 4.0 / 3.0 }

    /// How tall the thumbnail asset is, in pixels — see `build_species_photos.py`,
    /// which renders every species at 400×300.
    private static let thumbnailPixelHeight: CGFloat = 300

    /// Whether the small asset is enough, or the full-size photograph has to be
    /// loaded instead.
    ///
    /// Asked of the box rather than set by the caller, because the answer only
    /// depends on the box: a thumbnail drawn larger than the asset is an
    /// upscale, and at the size the large detection rows ask for it is a
    /// visible one. Callers get the cheap asset wherever it is enough without
    /// having to know what "enough" is.
    private var usesThumbnail: Bool {
        height * displayScale <= Self.thumbnailPixelHeight
    }

    var body: some View {
        // Credit caption omitted at this size — it's unreadable behind a 60pt
        // box. The hero image and map card carry the attribution instead.
        SpeciesPhoto(scientificName: scientificName, usesThumbnail: usesThumbnail, onTap: onTap) {
            Image(systemName: "bird")
                .foregroundStyle(.secondary)
                .frame(width: width, height: height)
                .background(.fill.tertiary)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
