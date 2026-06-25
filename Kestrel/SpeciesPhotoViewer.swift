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

    @State private var image: UIImage?
    @State private var loadFailed = false

    // Zoom + pan. The image is scaled about its center and translated by
    // `panOffset` (screen points); each pinch compensates `panOffset` so the
    // point between the fingers stays put, instead of the scale-anchor jumping
    // between gestures.
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    /// Center-relative focal point of the in-progress pinch, kept so the
    /// bounce-back at max zoom can compensate `panOffset` around the same point.
    @State private var lastFocal: CGSize = .zero

    // Swipe-to-dismiss (applied to the whole content).
    @State private var dragOffset: CGSize = .zero
    /// Measured size of the viewer, used to turn the pinch's unit-point anchor
    /// into a center-relative focal point for the zoom compensation.
    @State private var viewSize: CGSize = CGSize(width: 400, height: 800)
    /// Faded to 0 as the viewer is dismissed, so the stock cover slide is
    /// accompanied by a cross-fade to the app behind it.
    @State private var contentOpacity: Double = 1

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
        .opacity(contentOpacity)
        // Clear presentation background so the fade reveals the app behind.
        .presentationBackground(.clear)
        .gesture(magnify.simultaneously(with: drag))
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { viewSize = $0 }
        .task(id: scientificName) { await load() }
    }

    private var content: some View {
        ZStack {
            imageLayer.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    // Liquid-glass close button, matching the life-list search
                    // field's cancel button.
                    Button { dismissViewer() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(.primary)
                            .frame(width: 22, height: 22)
                            .padding(13)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .contentShape(Circle())
                    }
                    .buttonStyle(NoDimButtonStyle())
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                }
                Spacer()
                // The species caption (name / attribution / eBird) plus the
                // sighting's place + date, in the frosted text panel pinned to
                // the bottom edge. Tapping the place name shows it on the map.
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
                .scaleEffect(scale)
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
            // no sighting, so the whole block is omitted. The place name is the
            // tap target that shows / pinpoints the bird on the map.
            if let dateFound {
                VStack(spacing: 4) {
                    if let placeName, !placeName.isEmpty {
                        let label = Label(placeName, systemImage: "mappin")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        if let onShowOnMap {
                            Button(action: onShowOnMap) { label }
                                .buttonStyle(NoDimButtonStyle())
                                .accessibilityLabel(mapButtonTitle ?? "Show on Map")
                        } else {
                            label
                        }
                    }
                    Text(dateFound, format: .dateTime.year().month(.abbreviated).day())
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        // The frosted panel bleeds to the very bottom of the screen (its fill
        // ignores the bottom safe area) while the text stays above the home
        // indicator.
        .background {
            Color.black.opacity(0.75).ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Gestures

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let raw = lastScale * value.magnification
                let newScale: CGFloat
                if raw > maxScale {
                    // Past the max, apply diminishing rubberband resistance so
                    // the image keeps tracking the fingers but increasingly
                    // resists — the standard iOS overscroll feel.
                    newScale = maxScale + (raw - maxScale) * 0.3
                } else {
                    newScale = max(raw, 1)
                }
                // Compensate the translation so the point between the fingers
                // stays fixed as the scale changes — this is what stops the
                // image from snapping around when a new pinch starts somewhere
                // different from the last one. Focal point is measured relative
                // to the view center (the scale's anchor).
                let focal = CGSize(
                    width: (value.startAnchor.x - 0.5) * viewSize.width,
                    height: (value.startAnchor.y - 0.5) * viewSize.height
                )
                lastFocal = focal
                let ratio = newScale / lastScale
                panOffset = CGSize(
                    width: focal.width * (1 - ratio) + lastPan.width * ratio,
                    height: focal.height * (1 - ratio) + lastPan.height * ratio
                )
                scale = newScale
            }
            .onEnded { _ in
                if scale > maxScale {
                    // Snap back to the limit with a spring and a crisp tap, the
                    // way a scroll view bounces off its content edge — keeping
                    // the same focal point fixed through the bounce.
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    let ratio = maxScale / scale
                    let targetPan = CGSize(
                        width: lastFocal.width * (1 - ratio) + panOffset.width * ratio,
                        height: lastFocal.height * (1 - ratio) + panOffset.height * ratio
                    )
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        scale = maxScale
                        panOffset = targetPan
                    }
                    lastScale = maxScale
                    lastPan = targetPan
                } else if scale <= 1 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scale = 1
                        panOffset = .zero
                    }
                    lastScale = 1
                    lastPan = .zero
                } else {
                    lastScale = scale
                    lastPan = panOffset
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
                    dismissViewer()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    /// Closes the viewer with the stock cover slide, fading the content to 0 at
    /// the same time so it cross-dissolves into the app behind rather than just
    /// dropping away.
    private func dismissViewer() {
        withAnimation(.easeOut(duration: 0.3)) {
            contentOpacity = 0
        }
        dismiss()
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if scale > 1 {
                scale = 1
                panOffset = .zero
            } else {
                scale = 2
                panOffset = .zero
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
