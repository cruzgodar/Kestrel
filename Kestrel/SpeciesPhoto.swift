import SwiftUI

/// Single source of truth for rendering a species photo, honoring the current
/// `AppSettings.imageSource`. Renders the photo `.scaledToFill` inside whatever
/// frame the caller imposes (callers own framing, clipping, and borders); shows
/// the caller-supplied `placeholder` when no image is available.
///
/// - `.bundled` → the decoded JPEG from `SpeciesImageCache`.
/// - `.embed`   → the Macaulay photo from `RemoteSpeciesImageStore` (memory →
///   persistent disk → network), with an attribution caption when `showsCredit`
///   is set (large contexts only — it's unreadable behind a 60pt thumbnail).
///
/// When `tappable` and an image is available, tapping opens the full-screen
/// viewer via the `SpeciesPhotoPresenter` in the environment. Callers that need
/// their own tap handling (the map annotations) pass `tappable: false`.
struct SpeciesPhoto<Placeholder: View>: View {
    @Environment(SpeciesPhotoPresenter.self) private var presenter: SpeciesPhotoPresenter?

    let scientificName: String
    var showsCredit: Bool = false
    var tappable: Bool = true
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        content
            .modifier(PresentPhotoOnTap(
                scientificName: scientificName,
                enabled: tappable && hasImage,
                presenter: presenter
            ))
    }

    /// Whether an image exists (or is expected, for embed) — gates tappability
    /// so a bare placeholder doesn't open an empty viewer.
    private var hasImage: Bool {
        switch AppSettings.shared.imageSource {
        case .bundled: return SpeciesImageCache.shared.image(for: scientificName) != nil
        case .embed:   return SpeciesPhotoMetadata.shared.info(for: scientificName) != nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch AppSettings.shared.imageSource {
        case .bundled:
            if let img = SpeciesImageCache.shared.image(for: scientificName) {
                speciesPhotoFill(Image(uiImage: img))
            } else {
                placeholder()
            }
        case .embed:
            RemoteSpeciesImage(scientificName: scientificName, showsCredit: showsCredit) {
                placeholder()
            }
        }
    }
}

/// Embed-source image backed by `RemoteSpeciesImageStore`. Synchronous memory
/// hits render with no flash; everything else loads off the main actor.
private struct RemoteSpeciesImage<Placeholder: View>: View {
    let scientificName: String
    var showsCredit: Bool
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let image {
                speciesPhotoFill(Image(uiImage: image))
                    .overlay(alignment: .bottomLeading) {
                        if showsCredit,
                           let attr = SpeciesPhotoMetadata.shared.info(for: scientificName)?.attribution {
                            speciesPhotoCredit(attr)
                        }
                    }
            } else if loaded {
                placeholder()
            } else {
                placeholder().redacted(reason: .placeholder)
            }
        }
        .task(id: scientificName) {
            if let mem = RemoteSpeciesImageStore.shared.memoryImage(for: scientificName) {
                image = mem
                loaded = true
                return
            }
            let img = await RemoteSpeciesImageStore.shared.image(for: scientificName)
            guard !Task.isCancelled else { return }
            image = img
            loaded = true
        }
    }
}

/// Adds tap-to-open-full-screen when enabled and a presenter is available.
private struct PresentPhotoOnTap: ViewModifier {
    let scientificName: String
    let enabled: Bool
    let presenter: SpeciesPhotoPresenter?

    func body(content: Content) -> some View {
        if enabled, let presenter {
            content
                .contentShape(Rectangle())
                .onTapGesture { presenter.present(scientificName) }
        } else {
            content
        }
    }
}

// MARK: - Shared rendering helpers (used by both sources)

func speciesPhotoFill(_ image: Image) -> some View {
    image
        .resizable()
        .interpolation(.medium)
        .aspectRatio(contentMode: .fill)
}

func speciesPhotoCredit(_ text: String) -> some View {
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
