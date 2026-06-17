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
/// attribution. Loads the image from the remote store (memory → disk →
/// network); species with no remote photo show the placeholder.
///
/// Gestures (zoom, pan, swipe-to-dismiss) live here at the top level: the
/// dismiss drag moves the *entire* view — image, caption, and close button —
/// and fades the background to reveal the app behind, while pinch zoom anchors
/// on the midpoint between the fingers.
struct SpeciesPhotoFullScreen: View {
    let scientificName: String
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var loadFailed = false

    // Zoom + pan (applied to the image only).
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var zoomAnchor: UnitPoint = .center
    @State private var panOffset: CGSize = .zero
    @State private var lastPan: CGSize = .zero

    // Swipe-to-dismiss (applied to the whole content).
    @State private var dragOffset: CGSize = .zero

    /// Past this much downward travel, release dismisses.
    private let dismissThreshold: CGFloat = 120

    private var dismissProgress: CGFloat {
        min(max(dragOffset.height, 0) / 250, 1)
    }
    private var backgroundOpacity: Double {
        Double(1 - dismissProgress * 0.85)
    }

    private var commonName: String {
        SpeciesCatalog.shared.commonName(for: scientificName) ?? scientificName
    }
    private var info: SpeciesPhotoInfo? {
        SpeciesPhotoMetadata.shared.info(for: scientificName)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(backgroundOpacity).ignoresSafeArea()

            content
                .scaleEffect(1 - dismissProgress * 0.08)
                .offset(dragOffset)
        }
        // Clear presentation background so the fade reveals the app behind.
        .presentationBackground(.clear)
        .gesture(magnify.simultaneously(with: drag))
        .task(id: scientificName) { await load() }
    }

    private var content: some View {
        ZStack {
            imageLayer.ignoresSafeArea()

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
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale, anchor: zoomAnchor)
                .offset(panOffset)
                .onTapGesture(count: 2) { toggleZoom() }
        } else if loadFailed {
            Image(systemName: "bird")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.4))
        } else {
            ProgressView().tint(.white)
        }
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

    // MARK: - Gestures

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Anchor the zoom on the midpoint between the fingers rather
                // than always the view center.
                zoomAnchor = value.startAnchor
                scale = min(max(lastScale * value.magnification, 1), 4)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 {
                    withAnimation(.easeOut(duration: 0.2)) { panOffset = .zero }
                    lastPan = .zero
                }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 {
                    // Pan the zoomed image.
                    panOffset = CGSize(
                        width: lastPan.width + value.translation.width,
                        height: lastPan.height + value.translation.height
                    )
                } else {
                    // Move the whole view with the finger.
                    dragOffset = value.translation
                }
            }
            .onEnded { value in
                if scale > 1 {
                    lastPan = panOffset
                } else if value.translation.height > dismissThreshold {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if scale > 1 {
                scale = 1
                panOffset = .zero
            } else {
                zoomAnchor = .center
                scale = 2
            }
            lastScale = scale
            lastPan = panOffset
        }
    }

    // MARK: - Loading

    private func load() async {
        image = nil
        loadFailed = false
        let name = scientificName
        if let mem = RemoteSpeciesImageStore.shared.memoryImage(for: name) {
            image = mem
            return
        }
        let loaded = await RemoteSpeciesImageStore.shared.image(for: name)
        guard !Task.isCancelled else { return }
        image = loaded
        loadFailed = loaded == nil
    }
}
