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
/// or the remote store).
struct SpeciesPhotoFullScreen: View {
    let scientificName: String
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var loadFailed = false

    private var commonName: String {
        SpeciesCatalog.shared.commonName(for: scientificName) ?? scientificName
    }

    private var attribution: String? {
        SpeciesPhotoMetadata.shared.info(for: scientificName)?.attribution
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                ZoomableImage(image: image)
            } else if loadFailed {
                Image(systemName: "bird")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ProgressView()
                    .tint(.white)
            }

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

    private var caption: some View {
        VStack(spacing: 2) {
            Text(commonName)
                .font(.headline)
                .foregroundStyle(.white)
            if let attribution {
                Text(attribution)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
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
            // Decode off the main actor to avoid a hitch on large JPEGs.
            let img = await Task.detached(priority: .userInitiated) {
                SpeciesImageCache.shared.image(for: name)
            }.value
            image = img
            loadFailed = img == nil
        case .embed:
            if let mem = RemoteSpeciesImageStore.shared.memoryImage(for: name) {
                image = mem
                return
            }
            let img = await RemoteSpeciesImageStore.shared.image(for: name)
            guard !Task.isCancelled else { return }
            image = img
            loadFailed = img == nil
        }
    }
}

/// Pinch-to-zoom + pan image, double-tap to toggle fit/2×. Clamped to 1–4×;
/// snaps back to fit when zoomed out past 1×.
private struct ZoomableImage: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(magnify.simultaneously(with: pan))
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if scale > 1 {
                        scale = 1; offset = .zero
                    } else {
                        scale = 2
                    }
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

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                // Panning only applies while zoomed in; at fit scale the image
                // stays centered.
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in lastOffset = offset }
    }
}
