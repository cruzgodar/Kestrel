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
    /// pins, cluster grids) so scrolling them doesn't decode the `hero` tier.
    var usesThumbnail: Bool = false
    /// Paint the `thumb` tier first, then upgrade to the `hero` (medium) one.
    /// Set by the Identify hero so a freshly-heard bird's large photo appears
    /// instantly (from the thumbnail already headed to the watch) instead of
    /// waiting on the medium download. Ignored when `usesThumbnail` is set.
    ///
    /// Tiers are named by their CDN folder rather than by a pixel height, for
    /// the reason `MoreView.countGroup` gives: the rendered sizes are the photo
    /// build script's to choose, so a number restated here is a copy that goes
    /// stale silently. `RemoteSpeciesImageStore` documents the current heights
    /// once, where the CDN contract lives.
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
                enabled: tappable,
                presenter: presenter,
                onTap: onTap
            ))
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
    /// Thumbnail-first, then upgrade to the medium tier (see `SpeciesPhoto`).
    var progressive: Bool = false
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    /// Whether the species has no published photo, so the placeholder shows
    /// the bird rather than the download indicator.
    @State private var unpublished = false
    /// The species `image` was loaded for. `.task(id:)` re-runs when the name
    /// changes without the view's identity changing — that is the whole point of
    /// the `id:` — but `@State` survives that, so without this the previous
    /// bird's photo stays on screen while the new one loads. Every call site's
    /// `ForEach` id currently carries the species, so nothing hits this today;
    /// it costs one comparison to make sure nothing ever does.
    @State private var loadedName: String?

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
            } else {
                placeholder()
                    .environment(
                        \.speciesPhotoIsDownloading,
                        !unpublished && RemoteSpeciesImageStore.shared.isPhotographed(scientificName)
                    )
            }
        }
        // The tier is part of the id: a box that changes size can move from
        // the thumbnail to the medium image (see `SpeciesThumbnail`).
        .task(id: LoadID(name: scientificName, usesThumbnail: usesThumbnail, progressive: progressive)) {
            let store = RemoteSpeciesImageStore.shared
            // A different bird than the one on screen: drop the old photo before
            // loading, so the wrong species is never shown under the right name.
            if loadedName != scientificName {
                loadedName = scientificName
                image = nil
                unpublished = false
            }

            // Every load below goes on until it lands — see
            // `SpeciesPhotoLoading`. A photo the manifest lists is never
            // given up on while it is on screen.
            let setPhase: (SpeciesPhotoLoading.Phase) -> Void = { phase in
                unpublished = phase == .unpublished
                if unpublished { image = nil }
            }

            if progressive {
                // Already have the medium image resident — show it straight away,
                // no thumbnail flash.
                if let mem = store.memoryImage(for: scientificName) {
                    image = mem
                    return
                }
                // Paint the thumbnail first (instant if it's the one just sent
                // to the watch), then upgrade to the medium image. The thumbnail
                // is a stopgap, so it gets one try: the medium image is the one
                // that is retried until it arrives, and it replaces the
                // thumbnail whenever it does.
                if let thumb = store.memoryThumbnail(for: scientificName) {
                    image = thumb
                } else if store.isPhotographed(scientificName),
                          let thumb = await store.thumbnailImage(for: scientificName) {
                    guard !Task.isCancelled else { return }
                    image = thumb
                }
                let medium = await SpeciesPhotoLoading.load(scientificName, phase: { phase in
                    // The thumbnail stays up while the medium image is retried.
                    if phase == .unpublished || image == nil { setPhase(phase) }
                }) {
                    await store.image(for: scientificName)
                }
                guard !Task.isCancelled, let medium else { return }
                image = medium
                return
            }

            // Synchronous memory hit first (no placeholder flash) from whichever
            // tier this context uses.
            if let mem = usesThumbnail
                ? store.memoryThumbnail(for: scientificName)
                : store.memoryImage(for: scientificName) {
                image = mem
                return
            }
            let loaded = await SpeciesPhotoLoading.load(scientificName, phase: setPhase) {
                usesThumbnail
                    ? await store.thumbnailImage(for: scientificName)
                    : await store.image(for: scientificName)
            }
            guard !Task.isCancelled, let loaded else { return }
            unpublished = false
            image = loaded
        }
    }

    private struct LoadID: Hashable {
        let name: String
        let usesThumbnail: Bool
        let progressive: Bool
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
