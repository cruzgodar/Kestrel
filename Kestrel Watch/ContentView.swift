import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager.shared

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            if session.isRecording {
                nowHearing
            } else {
                idleButton
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.isRecording)
        .animation(.easeInOut(duration: 0.3), value: session.lastBird)
        .task { WatchSessionManager.shared.activate() }
    }

    // MARK: - Background

    /// Black until a bird is heard, then the dark-mode highlight color for its
    /// kind. Outside a recording session it's always black (the idle button).
    private var backgroundColor: Color {
        guard session.isRecording, let bird = session.lastBird else { return .black }
        switch bird.highlight {
        case .newSpecies: return Self.newSpeciesBackground
        case .starred:    return Self.starredBackground
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

    // MARK: - Idle / starting (big button)

    private var idleButton: some View {
        Button {
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
                    Image(systemName: "mic.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace, options: .speed(2.6)))
                }
            }
            .frame(width: 110, height: 110)
            .background(Circle().fill(Self.recordTint.opacity(session.isStarting ? 0.6 : 1.0)))
            .animation(.easeOut(duration: 0.15), value: session.isStarting)
        }
        .buttonStyle(.plain)
        // Taps are ignored while spinning up so a double-tap can't kick off
        // a second start or stop a half-started session.
        .disabled(session.isStarting)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    // MARK: - Recording ("now hearing")

    private var nowHearing: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geo in
                // Square image sized to the available width, capped so the
                // name always has room beneath it on the shortest watches.
                let side = min(geo.size.width - 16, geo.size.height * 0.62)
                VStack(spacing: 8) {
                    birdImage(side: max(side, 64))
                    nameLabel
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .padding(.bottom, 4)
            }

            stopButton
                .padding(.leading, 6)
                .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func birdImage(side: CGFloat) -> some View {
        Group {
            if let image = session.lastBirdImage {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                // No image yet (still loading) or none available for this
                // species — a quiet placeholder keyed to the bird glyph.
                Color.white.opacity(0.12)
                    .overlay(
                        Image(systemName: "bird.fill")
                            .font(.system(size: side * 0.3))
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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

    /// The shrunk record button — a small stop control tucked into the corner.
    private var stopButton: some View {
        Button {
            session.toggle()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.black.opacity(0.35)))
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

#Preview {
    ContentView()
}
