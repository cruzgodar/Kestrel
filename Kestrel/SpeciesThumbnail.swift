import SwiftUI

/// Trailing thumbnail used by both the detection list (Identify tab) and the
/// Life List. Pinned to a constant 4:3 box (matching the dominant aspect
/// ratio of the bundled species photos) so every row's trailing edge — and
/// thus the row's star button — lines up cleanly regardless of whether an
/// image is present. Non-4:3 photos are `.scaledToFill`-clipped into the
/// box; rows with no bundled image render an SF-symbol placeholder of the
/// same dimensions.
struct SpeciesThumbnail: View {
    let scientificName: String
    var height: CGFloat = 60

    /// 4:3 — matches the bundled `SpeciesImages` aspect ratio.
    private var width: CGFloat { height * 4.0 / 3.0 }

    var body: some View {
        Group {
            if let img = SpeciesImageCache.shared.image(for: scientificName) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
            } else {
                Image(systemName: "bird")
                    .foregroundStyle(.secondary)
                    .frame(width: width, height: height)
                    .background(.fill.tertiary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
