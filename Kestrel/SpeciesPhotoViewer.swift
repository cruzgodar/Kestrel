import SwiftUI

/// Identifies the species whose photo is shown full-screen.
struct PresentedSpecies: Identifiable, Hashable {
    let scientificName: String
    var id: String { scientificName }
}

/// App-wide driver for the full-screen photo viewer. Injected into the
/// environment at the root; any `SpeciesPhoto` (or the map's annotation tap
/// handlers) calls `present(_:)` to open the viewer. Optional in the
/// environment so previews without it simply don't present.
@MainActor
@Observable
final class SpeciesPhotoPresenter {
    var presented: PresentedSpecies?

    func present(_ scientificName: String) {
        presented = PresentedSpecies(scientificName: scientificName)
    }
}

/// Full-screen, zoomable view of a single species photo with its Macaulay
/// attribution. Loads the image from whichever source is active (bundled cache
/// or the remote store), falling back to the bundled image for manual/exception
/// species that have no remote photo.
struct SpeciesPhotoFullScreen: View {
    let scientificName: String
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var loadFailed = false

    private var commonName: String {
        SpeciesCatalog.shared.commonName(for: scientificName) ?? scientificName
    }

    private var info: SpeciesPhotoInfo? {
        SpeciesPhotoMetadata.shared.info(for: scientificName)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Ignore the safe area so the image centers on the physical screen,
            // not the (asymmetric) safe-area rectangle.
            Group {
                if let image {
                    ZoomableImage(image: image, onDismiss: { dismiss() })
                } else if loadFailed {
                    Image(systemName: "bird")
                        .font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    ProgressView().tint(.white)
                }
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                }
                Spacer()
                caption
            }
        }
        .task(id: scientificName) { await load() }
    }

    @ViewBuilder
    private var caption: some View {
        // Only the institutional/photographer credit applies to Macaulay
        // photos; manual fallback species (no remote info) show just the name.
        VStack(spacing: 3) {
            Text(commonName)
                .font(.headline)
                .foregroundStyle(.white)
            if let info {
                Text(info.attribution)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                if let ebirdURL = info.ebirdURL {
                    Link("View on eBird", destination: ebirdURL)
                        .font(.caption2.weight(.semibold))
                        .tint(.white)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .background(.black.opacity(0.35))
    }

    private func load() async {
        image = nil
        loadFailed = false
        let name = scientificName
        switch AppSettings.shared.imageSource {
        case .bundled:
            image = await bundledImage(name)
            loadFailed = image == nil
        case .embed:
            if let mem = RemoteSpeciesImageStore.shared.memoryImage(for: name) {
                image = mem
                return
            }
            // Remote when we have metadata, else fall back to the bundled image
            // (manual/exception species). Bundled also covers a remote failure.
            var loaded: UIImage?
            if info != nil {
                loaded = await RemoteSpeciesImageStore.shared.image(for: name)
            }
            if loaded == nil {
                loaded = await bundledImage(name)
            }
            guard !Task.isCancelled else { return }
            image = loaded
            loadFailed = loaded == nil
        }
    }

    /// Decodes the bundled image off the main actor to avoid a hitch.
    private func bundledImage(_ name: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            SpeciesImageCache.shared.image(for: name)
        }.value
    }
}

/// Pinch-to-zoom + pan image; double-tap toggles fit/2×. At fit scale a
/// downward drag dismisses (swipe-to-close); past fit, drag pans. Zoom is
/// clamped to 1–4×.
private struct ZoomableImage: View {
    let image: UIImage
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    /// Past this much downward travel at fit scale, release dismisses.
    private let dismissThreshold: CGFloat = 120

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(magnify.simultaneously(with: drag))
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if scale > 1 { scale = 1; offset = .zero } else { scale = 2 }
                    lastScale = scale
                    lastOffset = offset
                }
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), 4)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 {
                    withAnimation(.easeOut(duration: 0.2)) { offset = .zero }
                    lastOffset = .zero
                }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 {
                    // Pan the zoomed image.
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                } else {
                    // Swipe-to-dismiss: follow the finger, mostly vertical.
                    offset = CGSize(
                        width: value.translation.width * 0.4,
                        height: value.translation.height
                    )
                }
            }
            .onEnded { value in
                if scale > 1 {
                    lastOffset = offset
                } else if value.translation.height > dismissThreshold {
                    onDismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        offset = .zero
                    }
                }
            }
    }
}
