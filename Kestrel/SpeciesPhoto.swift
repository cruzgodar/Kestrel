import SwiftUI

/// Single source of truth for rendering a species photo. Renders the photo
/// `.scaledToFill` inside whatever frame the caller imposes (callers own
/// framing, clipping, and borders); shows the caller-supplied `placeholder`
/// when no image is available.
///
/// The photo is the CC-licensed image from `RemoteSpeciesImageStore` (memory →
/// persistent disk → network), with an attribution caption when `showsCredit`
/// is set (large contexts only — it's unreadable behind a 60pt thumbnail).
///
/// When `tappable` and an image is available, tapping opens the full-screen
/// viewer via the `SpeciesPhotoPresenter` in the environment. Callers that need
/// their own tap handling (the map annotations) pass `tappable: false`.
struct SpeciesPhoto<Placeholder: View>: View {
    @Environment(SpeciesPhotoPresenter.self) private var presenter: SpeciesPhotoPresenter?

    let scientificName: String
    var showsCredit: Bool = false
    var tappable: Bool = true
    /// Load the small cached thumbnail rather than the full-resolution image. Set
    /// by the small contexts that show many photos at once (life-list rows, map
    /// pins, cluster grids) so scrolling them doesn't decode full ~900px images.
    var usesThumbnail: Bool = false
    /// Paint the 320px thumbnail first, then upgrade to the 900px medium image.
    /// Set by the Identify hero so a freshly-heard bird's large photo appears
    /// instantly (from the thumbnail already headed to the watch) instead of
    /// waiting on the medium download. Ignored when `usesThumbnail` is set.
    var progressive: Bool = false
    /// Overrides the default tap action (which opens a singleton viewer). The
    /// Life List passes one that opens the viewer over the whole ordered list so
    /// the user can swipe between birds.
    var onTap: (() -> Void)? = nil
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        content
            .modifier(PresentPhotoOnTap(
                scientificName: scientificName,
                enabled: tappable && hasImage,
                presenter: presenter,
                onTap: onTap
            ))
    }

    /// Whether an image is expected — gates tappability so a bare placeholder
    /// doesn't open an empty viewer. Depends only on remote metadata; species
    /// without it (e.g. Indonesian Honeyeater) show the placeholder.
    private var hasImage: Bool {
        SpeciesPhotoMetadata.shared.info(for: scientificName) != nil
    }

    @ViewBuilder
    private var content: some View {
        RemoteSpeciesImage(
            scientificName: scientificName,
            showsCredit: showsCredit,
            usesThumbnail: usesThumbnail,
            progressive: progressive
        ) {
            placeholder()
        }
    }
}

/// Embed-source image backed by `RemoteSpeciesImageStore`. Synchronous memory
/// hits render with no flash; everything else loads off the main actor.
private struct RemoteSpeciesImage<Placeholder: View>: View {
    let scientificName: String
    var showsCredit: Bool
    /// Use the small thumbnail tier instead of the full image (see `SpeciesPhoto`).
    var usesThumbnail: Bool = false
    /// Thumbnail-first, then upgrade to medium (see `SpeciesPhoto`).
    var progressive: Bool = false
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
            let store = RemoteSpeciesImageStore.shared

            if progressive {
                // Already have the medium image resident — show it straight away,
                // no thumbnail flash.
                if let mem = store.memoryImage(for: scientificName) {
                    image = mem
                    loaded = true
                    return
                }
                // Paint the 320px thumbnail first (instant if it's the one just
                // sent to the watch), then upgrade to the 900px medium.
                var thumb = store.memoryThumbnail(for: scientificName)
                if thumb == nil {
                    thumb = await store.thumbnailImage(for: scientificName)
                }
                if let thumb {
                    guard !Task.isCancelled else { return }
                    image = thumb
                    loaded = true
                }
                let medium = await store.image(for: scientificName)
                guard !Task.isCancelled else { return }
                // Keep the thumbnail showing if the medium failed to load.
                if let medium { image = medium }
                loaded = true
                return
            }

            // Synchronous memory hit first (no placeholder flash) from whichever
            // tier this context uses.
            if let mem = usesThumbnail
                ? store.memoryThumbnail(for: scientificName)
                : store.memoryImage(for: scientificName) {
                image = mem
                loaded = true
                return
            }
            // Remote only — no bundled fallback. Species without remote metadata
            // (e.g. Indonesian Honeyeater) show the placeholder.
            let img = usesThumbnail
                ? await store.thumbnailImage(for: scientificName)
                : await store.image(for: scientificName)
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
    let onTap: (() -> Void)?

    func body(content: Content) -> some View {
        if enabled, presenter != nil || onTap != nil {
            content
                .contentShape(Rectangle())
                .onTapGesture {
                    if let onTap {
                        onTap()
                    } else {
                        presenter?.present(scientificName)
                    }
                }
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
