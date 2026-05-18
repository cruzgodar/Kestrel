import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(RecordingManager.self) private var manager

    var body: some View {
        VStack(spacing: 0) {
            if manager.isRecording {
                SpectrogramView(
                    renderer: manager.spectrogram,
                    fpsCounter: manager.fpsCounter
                )
                .frame(height: 80)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    Text("\(Int(manager.fpsCounter.fps.rounded())) fps")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .padding(6)
                }
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

private struct SpectrogramView: UIViewRepresentable {
    let renderer: SpectrogramRenderer
    let fpsCounter: FPSCounter
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> SpectrogramHostView {
        let v = SpectrogramHostView()
        v.renderer = renderer
        v.fpsCounter = fpsCounter
        v.invert = colorScheme == .light
        v.start()
        return v
    }

    func updateUIView(_ uiView: SpectrogramHostView, context: Context) {
        uiView.renderer = renderer
        uiView.fpsCounter = fpsCounter
        uiView.invert = colorScheme == .light
    }

    static func dismantleUIView(_ uiView: SpectrogramHostView, coordinator: ()) {
        uiView.stop()
    }
}

/// Backing `UIView` whose `layer.contents` is refreshed every display frame by
/// a `CADisplayLink`. Driven directly at display refresh — 60 Hz on standard
/// displays, up to 120 Hz on ProMotion when the app opts in via
/// `CADisableMinimumFrameDurationOnPhone`.
final class SpectrogramHostView: UIView {
    var renderer: SpectrogramRenderer?
    var fpsCounter: FPSCounter?
    var invert: Bool = false {
        didSet { backgroundColor = invert ? .white : .black }
    }

    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // Stretch the CGImage to fill the layer bounds; bilinear filtering.
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.isOpaque = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        stop()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        fpsCounter?.tick(link.timestamp)
        renderer?.pumpColumns(at: link.targetTimestamp)
        guard let image = renderer?.snapshot(inverted: invert) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }
}
