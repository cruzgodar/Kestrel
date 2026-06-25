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
    /// Title for the optional map button at the bottom ("Show on Map" from the
    /// Life List / Identify tabs, "Pinpoint on Map" from a map cluster card).
    /// When `nil` — or when `onShowOnMap` is `nil` — no button is shown.
    var mapButtonTitle: String? = nil
    /// Action for the map button: switch to / focus the Map tab on this bird.
    var onShowOnMap: (() -> Void)? = nil
    /// Place name of the sighting this photo was opened from — the Life List
    /// location (earliest sighting) or the tapped map point's location. `nil`
    /// for non-lifers (no recorded sighting) or when no location was logged.
    var placeName: String? = nil
    /// Date of the sighting this photo was opened from. `nil` for non-lifers,
    /// which suppresses the whole observation section.
    var dateFound: Date? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

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
    /// Full height of the viewer, measured so a programmatic dismiss can slide
    /// the whole card clear off the bottom regardless of device size.
    @State private var viewHeight: CGFloat = 1000

    /// Past this much downward travel, release dismisses.
    private let dismissThreshold: CGFloat = 120
    /// Maximum pinch-zoom. Zooming past this rubberbands with resistance and
    /// snaps back (with a haptic) on release.
    private let maxScale: CGFloat = 4

    private var commonName: String {
        SpeciesCatalog.shared.commonName(for: scientificName) ?? scientificName
    }
    private var info: SpeciesPhotoInfo? {
        SpeciesPhotoMetadata.shared.info(for: scientificName)
    }

    var body: some View {
        ZStack {
            // The viewer behaves like a card: the black backdrop and the photo
            // move together with the finger, so dragging down slides the whole
            // thing off and reveals the app behind it in real time (rather than
            // waiting for the touch to release). The viewer is presented over a
            // clear background, so the gap above the card shows what's beneath.
            //
            // The backdrop ignores the safe area *before* it's offset (rather
            // than offsetting a parent of the safe-area-ignoring color) so its
            // status-bar and home-indicator extensions slide with the card
            // instead of snapping to the revealed app the moment the drag starts.
            Color.black
                .ignoresSafeArea()
                .offset(dragOffset)
            content
                .offset(dragOffset)
        }
        // Clear presentation background so the fade reveals the app behind.
        .presentationBackground(.clear)
        .gesture(magnify.simultaneously(with: drag))
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { viewHeight = $0 }
        .task(id: scientificName) { await load() }
    }

    private var content: some View {
        ZStack {
            imageLayer.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { slideOffAndDismiss() } label: {
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
                // Bottom stack: the species caption (name / attribution / eBird)
                // and the sighting's place + date sit together in the frosted
                // text panel, with the map button below it.
                caption
                if let mapButtonTitle, let onShowOnMap {
                    Button(action: onShowOnMap) {
                        Label(mapButtonTitle, systemImage: "mappin.and.ellipse")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.vertical, 13)
                            .padding(.horizontal, 26)
                            // Gray rather than translucent black so the button
                            // reads clearly against a dark photo; at half
                            // opacity it stays legible without dominating.
                            .background(Color(.systemGray2).opacity(0.5), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                }
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
        VStack(spacing: 10) {
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

            // Sighting section: where/when this bird was found. Only present
            // for lifers (a date is always recorded for them); non-lifers have
            // no sighting, so the whole block is omitted.
            if let dateFound {
                VStack(spacing: 2) {
                    if let placeName, !placeName.isEmpty {
                        Label(placeName, systemImage: "mappin")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    Text(dateFound, format: .dateTime.year().month(.abbreviated).day())
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        // The frosted text panel reads darker in dark mode (50%) than light
        // (35%) so the white text stays legible against a light photo. The ID
        // rows in the Identify tab keep their own 35% tint regardless of mode.
        .background(.black.opacity(colorScheme == .dark ? 0.5 : 0.35))
    }

    // MARK: - Gestures

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Anchor the zoom on the midpoint between the fingers rather
                // than always the view center.
                zoomAnchor = value.startAnchor
                let raw = lastScale * value.magnification
                if raw > maxScale {
                    // Past the max, apply diminishing rubberband resistance so
                    // the image keeps tracking the fingers but increasingly
                    // resists — the standard iOS overscroll feel.
                    scale = maxScale + (raw - maxScale) * 0.3
                } else {
                    scale = max(raw, 1)
                }
            }
            .onEnded { _ in
                if scale > maxScale {
                    // Snap back to the limit with a spring and a crisp tap, the
                    // way a scroll view bounces off its content edge.
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        scale = maxScale
                    }
                    lastScale = maxScale
                } else {
                    lastScale = scale
                }
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
                    // Move the whole card with the finger, vertically only —
                    // horizontal drift is locked out so the dismiss reads as a
                    // clean downward card slide.
                    dragOffset = CGSize(width: 0, height: value.translation.height)
                }
            }
            .onEnded { value in
                if scale > 1 {
                    lastPan = panOffset
                } else if value.translation.height > dismissThreshold {
                    slideOffAndDismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    /// Drives the dismissal ourselves so the card visibly slides clear off the
    /// bottom before the cover is removed. The system's own `fullScreenCover`
    /// dismissal cut the slide short — most visible when closing while zoomed in,
    /// where the card appeared to vanish partway down. Instead we animate the
    /// whole card (resetting any zoom so it travels as one piece) past the bottom
    /// edge, then remove the cover *without* animation, so the only motion the
    /// user sees is the smooth slide.
    private func slideOffAndDismiss() {
        withAnimation(.easeIn(duration: 0.3)) {
            scale = 1
            panOffset = .zero
            // Travel a full view height plus slack so even a tall image clears.
            dragOffset = CGSize(width: 0, height: viewHeight + 200)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
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
