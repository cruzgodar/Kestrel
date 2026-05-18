import SwiftUI

struct ContentView: View {
    @Environment(RecordingManager.self) private var manager

    var body: some View {
        VStack(spacing: 0) {
            if manager.isRecording {
                SpectrogramView(renderer: manager.spectrogram)
                    .frame(height: 80)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            resultsView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let status = manager.locationStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }

            if let message = manager.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            Button {
                Task { await manager.toggle() }
            } label: {
                Label(
                    manager.isRecording ? "Stop Recording" : "Start Recording",
                    systemImage: manager.isRecording ? "stop.fill" : "mic.fill"
                )
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .tint(manager.isRecording ? .red : .accentColor)
            .animation(.snappy, value: manager.isRecording)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var resultsView: some View {
        if manager.detections.isEmpty {
            ContentUnavailableView {
                Label(
                    manager.isRecording ? "Listening…" : "No detections yet",
                    systemImage: manager.isRecording ? "waveform" : "bird"
                )
            } description: {
                Text(manager.isRecording
                     ? "Analyzing 3-second windows of audio."
                     : "Tap Start Recording to begin identifying birds.")
            }
        } else {
            List(manager.detections) { detection in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(detection.commonName)
                            .font(.headline)
                        Text(detection.scientificName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                    Spacer()
                    Text(String(format: "%.0f%%", detection.confidence * 100))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
        }
    }
}

#Preview {
    ContentView()
        .environment(RecordingManager())
}

private struct SpectrogramView: View {
    let renderer: SpectrogramRenderer
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: false)) { _ in
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let inverted = colorScheme == .light
        ZStack {
            (inverted ? Color.white : Color.black)
            if let image = renderer.snapshot() {
                Image(decorative: image, scale: 1.0, orientation: .up)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
                    .colorInvert(when: inverted)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func colorInvert(when condition: Bool) -> some View {
        if condition { self.colorInvert() } else { self }
    }
}
