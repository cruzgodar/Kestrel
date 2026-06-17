import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager.shared

    /// Equal margin between the stop button and the bottom-left screen corner —
    /// large enough to clear the bezel curve.
    private static let buttonMargin: CGFloat = 16
    /// Fixed base size of the button; the morph is a uniform `scaleEffect` of
    /// this so the circle and glyph shrink together as one unit.
    private static let buttonBaseSize: CGFloat = 110
    private static let stopSize: CGFloat = 36

    var body: some View {
        let recording = session.isRecording
        // Visual size of the control: full while idle, small while recording.
        let side: CGFloat = recording ? Self.stopSize : Self.buttonBaseSize

        ZStack {
            backgroundColor.ignoresSafeArea()

            // Bird + name respect the safe area so the photo sits just under the
            // clock, as high as the OS allows.
            if recording {
                GeometryReader { geo in
                    nowHearing(in: geo.size)
                }
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
        .animation(.easeInOut(duration: 0.3), value: session.isRecording)
        .animation(.easeInOut(duration: 0.3), value: session.lastBird)
        .task { WatchSessionManager.shared.activate() }
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
        Button {
            session.toggle()
        } label: {
            Image(systemName: session.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.buttonBaseSize, height: Self.buttonBaseSize)
                .background(Circle().fill(Self.recordTint))
                .scaleEffect(scale)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.isRecording ? "Stop recording" : "Start recording")
    }

    // MARK: - Recording ("now hearing")

    /// The species photo in a fixed, nearly-full-width box anchored at the very
    /// top (top margin matching the side margins). The name sits directly
    /// beneath; a trailing spacer pushes both up so the bottom-left stop button
    /// keeps clear room.
    private func nowHearing(in size: CGSize) -> some View {
        let margin: CGFloat = 4
        let imageWidth = size.width - margin * 2
        // Landscape-ish box so typical (wider-than-tall) bird photos fill the
        // width; capped so the name keeps its room on short watches, floored so
        // it can't collapse if the safe area is unexpectedly short.
        let imageHeight = max(min(imageWidth * 0.72, size.height - 88), 64)
        return VStack(spacing: 6) {
            birdImage(width: imageWidth, height: imageHeight)
            nameLabel
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .padding(.top, margin)
    }

    /// Both the photo and its placeholder render into the *same* fixed frame, so
    /// the layout never shifts when an image arrives. `scaledToFit` shows the
    /// whole photo — never cropped.
    @ViewBuilder
    private func birdImage(width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let image = session.lastBirdImage {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            } else {
                // No image yet (still loading) or none available for this
                // species — a quiet placeholder keyed to the bird glyph.
                Color.white.opacity(0.12)
                    .overlay(
                        Image(systemName: "bird.fill")
                            .font(.system(size: min(width, height) * 0.3))
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                .padding(.horizontal, 6)
                .id(bird.scientificName)
                .transition(.opacity)
        } else {
            Text("Listening…")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.65))
        }
    }

}

#Preview {
    ContentView()
}
