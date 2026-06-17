import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager.shared

    /// Equal margin between the stop button and the bottom-left screen corner —
    /// large enough to clear the bezel curve.
    private static let buttonMargin: CGFloat = 16
    /// Fixed base size of the button; the morph is a uniform `scaleEffect` of
    /// this so the circle and glyph shrink together as one unit.
    private static let buttonBaseSize: CGFloat = 110
    private static let stopSize: CGFloat = 46

    var body: some View {
        let recording = session.isRecording
        // Visual size of the control: full while idle, small while recording.
        let side: CGFloat = recording ? Self.stopSize : Self.buttonBaseSize

        ZStack {
            backgroundColor.ignoresSafeArea()

            // Bird + name use the full screen (ignoring the safe area) so the
            // photo can sit at the very top rather than below the large top
            // (clock) inset.
            if recording {
                GeometryReader { geo in
                    nowHearing(in: geo.size)
                }
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
        // the session manager so audio bring-up/teardown can hang off the
        // animation's completion. Only the bird cross-fade is animated here.
        .animation(.easeInOut(duration: 0.3), value: session.lastBird)
        .task { WatchSessionManager.shared.activate() }
        // TEMP DIAGNOSTIC
        .onAppear { Self.ts("view onAppear") }
        .onChange(of: session.isRecording) { _, v in Self.ts("view sees isRecording=\(v)") }
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
            Self.ts("button TAP")  // TEMP DIAGNOSTIC
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
    /// a scrim for legibility) rather than given its own band beneath it.
    private func nowHearing(in size: CGSize) -> some View {
        let margin: CGFloat = 4
        return VStack(spacing: 0) {
            // Fixed top margin (matching the sides), then the photo, then a
            // flexible spacer — so the photo is pinned to the top rather than
            // centered in the available height.
            Color.clear.frame(height: margin)
            birdImage(maxWidth: size.width - margin * 2, maxHeight: size.height - margin * 2)
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    /// The whole photo (never cropped) sized to fill the full available width,
    /// its height following the photo's aspect. The placeholder uses the same
    /// full width (at the photos' usual 4:3) so it's never narrow. The name is
    /// overlaid across the bottom.
    @ViewBuilder
    private func birdImage(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        let fitted = Self.fittedSize(session.lastBirdImage?.size ?? CGSize(width: 4, height: 3),
                                     maxWidth: maxWidth, maxHeight: maxHeight)
        Group {
            if let image = session.lastBirdImage {
                // Frame matches the photo's aspect exactly → fills the width with
                // no crop and no letterbox.
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
            } else {
                // No image yet (still loading) or none available for this
                // species — a quiet placeholder keyed to the bird glyph.
                Color.white.opacity(0.12)
                    .overlay(
                        Image(systemName: "bird.fill")
                            .font(.system(size: min(fitted.width, fitted.height) * 0.28))
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
        }
        .frame(width: fitted.width, height: fitted.height)
        .overlay(alignment: .bottom) {
            nameLabel
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
                .padding(.top, 22)
                .padding(.bottom, 7)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.65)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .id(session.lastBird?.scientificName)
        .transition(.opacity)
    }

    /// Largest size with the given aspect that fits within `maxWidth × maxHeight`
    /// — width-limited (full width) for the common landscape/4:3 case, height-
    /// capped only for unusually tall photos.
    private static func fittedSize(_ imageSize: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let aspect = imageSize.width / max(imageSize.height, 1)
        var w = maxWidth
        var h = maxWidth / aspect
        if h > maxHeight {
            h = maxHeight
            w = maxHeight * aspect
        }
        return CGSize(width: w, height: h)
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
        } else {
            Text("Listening…")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

}

// TEMP DIAGNOSTIC: monotonic-clock timestamp logging to localize the start-tap
// delay. Remove once the slowdown is found.
extension ContentView {
    static func ts(_ msg: String) {
        print(String(format: "Kestrel⏱ %.3f  %@", ProcessInfo.processInfo.systemUptime, msg))
    }
}

#Preview {
    ContentView()
}
