import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager.shared

    /// Equal margin between the stop button and the bottom-left screen corner.
    private static let buttonMargin: CGFloat = 10

    var body: some View {
        let recording = session.isRecording
        let side: CGFloat = recording ? 36 : 110

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
            // corner. `.position` interpolates linearly — a straight path —
            // and anchors the circle by its center, so it scales in place and
            // travels in a straight line between the centered mic and the
            // corner stop button, identically in both directions.
            GeometryReader { geo in
                recordButton(side: side)
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

    /// The single control the user taps. A large centered mic while idle that
    /// shrinks down into a small corner stop button once recording — size,
    /// position, and glyph all animate together (driven solely by the body's
    /// `isRecording` animation, so both directions match) and it reads as one
    /// element morphing rather than two views swapping. Both states share the
    /// same solid purple fill.
    private func recordButton(side: CGFloat) -> some View {
        let recording = session.isRecording
        return Button {
            session.toggle()
        } label: {
            ZStack {
                if session.isStarting {
                    // Loading state — capture is spinning up (permission
                    // prompt + extended runtime session + audio engine).
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.4)
                } else {
                    // Resizable + centered so the glyph scales with the circle
                    // and stays put — no drift toward a corner when the symbol
                    // swaps mid-morph.
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: side * 0.4, height: side * 0.4)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: side, height: side)
            .background(Circle().fill(Self.recordTint.opacity(session.isStarting ? 0.6 : 1.0)))
        }
        .buttonStyle(.plain)
        // Taps are ignored while spinning up so a double-tap can't kick off
        // a second start or stop a half-started session.
        .disabled(session.isStarting)
        .accessibilityLabel(recording ? "Stop recording" : "Start recording")
    }

    // MARK: - Recording ("now hearing")

    /// The species photo shown whole (never cropped), as wide as the screen
    /// allows and anchored at the very top with a margin matching the side
    /// margins. The name sits directly beneath it; a trailing spacer pushes
    /// both up so the bottom-left stop button keeps clear room.
    private func nowHearing(in size: CGSize) -> some View {
        let margin: CGFloat = 4
        return VStack(spacing: 6) {
            birdImage(maxWidth: size.width - margin * 2, maxHeight: size.height - 92)
            nameLabel
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .padding(.top, margin)
    }

    @ViewBuilder
    private func birdImage(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        if let image = session.lastBirdImage {
            // `scaledToFit` shows the whole photo — no cropping.
            Image(uiImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFit()
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .id(session.lastBird?.scientificName)
                .transition(.opacity)
        } else {
            // No image yet (still loading) or none available for this species —
            // a quiet placeholder keyed to the bird glyph.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .frame(width: maxWidth, height: min(maxWidth * 0.66, maxHeight))
                .overlay(
                    Image(systemName: "bird.fill")
                        .font(.system(size: maxWidth * 0.2))
                        .foregroundStyle(.white.opacity(0.5))
                )
                .transition(.opacity)
        }
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
