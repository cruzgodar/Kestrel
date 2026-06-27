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
    /// Optional override for the photo tap (see `SpeciesPhoto.onTap`).
    var onTap: (() -> Void)? = nil

    /// 4:3 — matches the dominant species-photo aspect ratio.
    private var width: CGFloat { height * 4.0 / 3.0 }

    var body: some View {
        // Credit caption omitted at this size — it's unreadable behind a 60pt
        // box. The hero image and map card carry the attribution instead.
        SpeciesPhoto(scientificName: scientificName, usesThumbnail: true, onTap: onTap) {
            Image(systemName: "bird")
                .foregroundStyle(.secondary)
                .frame(width: width, height: height)
                .background(.fill.tertiary)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
