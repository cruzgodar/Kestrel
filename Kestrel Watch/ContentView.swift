import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager.shared

    /// Equal margin between the stop button and the bottom-left screen corner —
    /// large enough to clear the bezel curve.
    private static let buttonMargin: CGFloat = 16
    /// Fixed base size of the button; the morph is a uniform `scaleEffect` of
    /// this so the circle and glyph shrink together as one unit.
    private static let buttonBaseSize: CGFloat = 110
    private static let stopSize: CGFloat = 50
    /// Inset between the bird image/placeholder and the screen edges. Paired
    /// with `ContainerRelativeShape` so the corner radius stays concentric with
    /// the watch bezel as this changes.
    private static let imageMargin: CGFloat = 12
    /// Approximate corner radius of the watch's physical screen. watchOS exposes
    /// no public API for this, so we set it as the root container shape; the
    /// image's `ContainerRelativeShape` then insets it by `imageMargin` to stay
    /// concentric. Tune this to match the bezel on the target watch size.
    private static let screenCornerRadius: CGFloat = 48

    var body: some View {
        let recording = session.isRecording
        // Visual size of the control: full while idle, small while recording.
        let side: CGFloat = recording ? Self.stopSize : Self.buttonBaseSize

        ZStack {
            backgroundColor.ignoresSafeArea()

            // Pre-warm the text-rendering pipeline during launch. The idle
            // screen is all SF Symbols, so the bird name would otherwise be the
            // first `Text` in the app and pay ~0.8s of CoreText first-use init
            // on the record tap. Rendered black-on-black behind the button —
            // invisible, but it warms the pipeline as part of launch.
            if !recording {
                Text(verbatim: "Listening…")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }

            // Bird + name use the full screen (ignoring the safe area) so the
            // photo can sit at the very top rather than below the large top
            // (clock) inset.
            if recording {
                nowHearing
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // The record/stop control is positioned against the *full* screen
            // (ignoring the safe area) so it reaches the true bottom-left
            // corner. `.position` interpolates linearly (a straight path) and
            // the button scales uniformly (see `recordButton`), so it travels
            // in a straight line between the centered mic and the corner stop
            // button — identically in both directions.
            GeometryReader { geo in
                recordButton(scale: side / Self.buttonBaseSize)
                    .position(
                        x: recording ? Self.buttonMargin + side / 2 : geo.size.width / 2,
                        y: recording ? geo.size.height - Self.buttonMargin - side / 2 : geo.size.height / 2
                    )
            }
            .ignoresSafeArea()
        }
        // The record/stop morph is animated explicitly via `withAnimation` in
        // the session manager (so the audio bring-up/teardown can be deferred
        // until after it). Only the bird cross-fade is animated here.
        .animation(.easeInOut(duration: 0.3), value: session.lastBird)
        .task {
            WatchSessionManager.shared.activate()
            Self.prewarmText()
        }
    }

    // MARK: - Background

    /// Black until a bird is heard, then the dark-mode highlight color for its
    /// kind. A heard-but-unremarkable bird (already on the life list, not
    /// starred) stays black; only new/starred ones tint the screen.
    private var backgroundColor: Color {
        guard session.isRecording, let bird = session.lastBird else { return .black }
        switch bird.highlight {
        case .newSpecies: return Self.newSpeciesBackground
        case .starred:    return Self.starredBackground
        case .normal:     return .black
        }
    }

    // Dark-mode highlight colors mirroring the iOS app's row tints — purple
    // (recordHighlight, hue 252°) for a new species, blue (starredTint, hue
    // 215°) for a starred one — darkened for use as a full-screen background.
    private static let newSpeciesBackground =
        Color(hue: 252.0 / 360.0, saturation: 0.55, brightness: 0.42)
    private static let starredBackground =
        Color(hue: 215.0 / 360.0, saturation: 0.55, brightness: 0.42)

    private static let recordTint = Color(hue: 252.0 / 360.0, saturation: 0.65, brightness: 1.0)

    // MARK: - Record / stop button

    /// The single control the user taps. Rendered at a fixed base size and
    /// scaled as one unit, so the circle and glyph shrink together — no
    /// independent icon frame to drift or slide during the swap. Position +
    /// scale animate solely under the body's `isRecording` animation, so the
    /// morph is a straight, uniform shrink in both directions.
    private func recordButton(scale: CGFloat) -> some View {
        let recording = session.isRecording
        return Button {
            session.toggle()
        } label: {
            // Both glyphs are always present and cross-faded by opacity, so the
            // transition is symmetric and each lands at the correct end opacity
            // (0 or 1) — a single swapped `Image` left the outgoing glyph
            // partially visible and snapped at the end.
            ZStack {
                Image(systemName: "mic.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .opacity(recording ? 0 : 1)
                Image(systemName: "stop.fill")
                    .font(.system(size: 40, weight: .bold))
                    .opacity(recording ? 1 : 0)
            }
            .foregroundStyle(.white)
            .frame(width: Self.buttonBaseSize, height: Self.buttonBaseSize)
            .background(Circle().fill(Self.recordTint))
            .scaleEffect(scale)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording ? "Stop recording" : "Start recording")
    }

    // MARK: - Recording ("now hearing")

    /// The species photo filling the full width, anchored at the very top (top
    /// margin matching the side margins). A full-width 4:3 photo is nearly as
    /// tall as the whole screen, so the name is overlaid across its bottom (with
    /// a scrim for legibility) rather than given its own band beneath it. No
    /// `GeometryReader` — its first-time layout pass was the render stall; the
    /// image sizes itself with `aspectRatio` instead.
    private var nowHearing: some View {
        VStack(spacing: 0) {
            // Fixed top margin (matching the sides), then the photo, then a
            // flexible spacer — so the photo is pinned to the top rather than
            // centered in the available height.
            Color.clear.frame(height: Self.imageMargin)
            birdImage
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, Self.imageMargin)
        // Define the container shape for this full-screen region so the image's
        // `ContainerRelativeShape` has the bezel's rounded rect to inset from.
        // Without this, a standalone watchOS app has no container shape and
        // `ContainerRelativeShape` degrades to a sharp-cornered rectangle.
        .containerShape(
            RoundedRectangle(cornerRadius: Self.screenCornerRadius, style: .continuous)
        )
    }

    /// The whole photo (never cropped) filling the full width, its height
    /// following the photo's aspect (`aspectRatio`). The placeholder uses the
    /// same full width at the photos' usual 4:3 so it's never narrow. The photo
    /// is clipped to the rounded rect *before* the name scrim is overlaid, so
    /// the clip only ever processes the single image layer (no offscreen pass).
    @ViewBuilder
    private var birdImage: some View {
        Group {
            if let image = session.lastBirdImage {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(image.size, contentMode: .fit)
            } else {
                // No image yet (still loading) or none available for this
                // species — a quiet placeholder keyed to the bird glyph.
                Color.white.opacity(0.12)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay(
                        Image(systemName: "bird.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
        }
        .frame(maxWidth: .infinity)
        // `ContainerRelativeShape` inherits the watch screen's rounded-rect
        // corner and insets its radius by however far this view sits from the
        // screen edge (`imageMargin`), keeping the photo's corners concentric
        // with the bezel automatically.
        .clipShape(ContainerRelativeShape())
        .overlay(alignment: .bottom) {
            nameLabel
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
                .padding(.top, 10)
                .padding(.bottom, 7)
        }
        .id(session.lastBird?.scientificName)
        .transition(.opacity)
    }

    @ViewBuilder
    private var nameLabel: some View {
        if let bird = session.lastBird {
            Text(bird.commonName)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
        } else {
            Text("Listening…")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
        }
    }

}

extension ContentView {
    /// Fully renders a representative name `Text` off-screen at launch so the
    /// first on-screen bird name doesn't pay CoreText/text-pipeline first-use
    /// init (~0.8s) on the record tap. `ImageRenderer` forces the complete
    /// pipeline (layout + rasterization), unlike an invisible in-tree view which
    /// only warms layout.
    @MainActor
    static func prewarmText() {
        let renderer = ImageRenderer(content:
            Text("Northern Cardinal")
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(width: 180)
        )
        renderer.scale = 2
        _ = renderer.uiImage
    }
}

#Preview {
    ContentView()
}
