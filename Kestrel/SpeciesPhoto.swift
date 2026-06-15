import SwiftUI

/// Single source of truth for rendering a species photo, honoring the current
/// `AppSettings.imageSource`. Renders the photo `.scaledToFill` inside whatever
/// frame the caller imposes (callers own framing, clipping, and borders); shows
/// the caller-supplied `placeholder` when no image is available.
///
/// - `.bundled` → the decoded JPEG from `SpeciesImageCache`.
/// - `.embed`   → the Macaulay CDN photo loaded remotely via `AsyncImage`,
///   with an attribution caption when `showsCredit` is set (large contexts
///   only — it's unreadable behind a 60pt row thumbnail).
struct SpeciesPhoto<Placeholder: View>: View {
    let scientificName: String
    var showsCredit: Bool = false
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        switch AppSettings.shared.imageSource {
        case .bundled:
            bundled
        case .embed:
            embedded
        }
    }

    @ViewBuilder
    private var bundled: some View {
        if let img = SpeciesImageCache.shared.image(for: scientificName) {
            fill(Image(uiImage: img))
        } else {
            placeholder()
        }
    }

    @ViewBuilder
    private var embedded: some View {
        if let info = SpeciesPhotoMetadata.shared.info(for: scientificName),
           let url = URL(string: info.url) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    fill(image)
                        .overlay(alignment: .bottomLeading) {
                            if showsCredit { creditCaption(info.attribution) }
                        }
                case .failure:
                    placeholder()
                case .empty:
                    placeholder().redacted(reason: .placeholder)
                @unknown default:
                    placeholder()
                }
            }
        } else {
            placeholder()
        }
    }

    private func fill(_ image: Image) -> some View {
        image
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fill)
    }

    private func creditCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(5)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel("Photo credit: \(text)")
    }
}
