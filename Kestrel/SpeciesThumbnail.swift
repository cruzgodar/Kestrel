import SwiftUI

/// Trailing thumbnail used by both the detection list (Identify tab) and the
/// Life List. Pinned to a constant height with `aspectRatio(.fit)` so rows
/// stay vertically aligned even though individual images have varying widths.
/// Falls back to a `bird` SF Symbol when the species has no bundled image
/// (e.g. BirdNET's non-bird event classes like "Human whistle").
struct SpeciesThumbnail: View {
    let scientificName: String
    var height: CGFloat = 44

    var body: some View {
        Group {
            if let img = SpeciesImageCache.shared.image(for: scientificName) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: height)
            } else {
                Image(systemName: "bird")
                    .foregroundStyle(.secondary)
                    .frame(width: height, height: height)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
