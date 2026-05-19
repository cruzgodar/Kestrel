import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(RecordingManager.self) private var manager

    var body: some View {
        VStack(spacing: 0) {
            if manager.isRecording {
                SpectrogramView(renderer: manager.spectrogram)
                    .frame(height: 80)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .transition(.opacity.animation(.smooth(duration: 0.16)))

            }

            resultsView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeOut(duration: 0.15), value: manager.isRecording)
                .animation(.easeOut(duration: 0.15), value: manager.detections.isEmpty)

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

            recordButton
                .padding(.bottom, 8)
        }
        .onChange(of: manager.isRecording) { _, new in
            PerfLog.log("SwiftUI .onChange sees isRecording=\(new)")
        }
    }

    private var recordButton: some View {
        Button {
            PerfLog.reset()
            PerfLog.log("button tap action fired")
            Task {
                PerfLog.log("button Task running")
                await manager.toggle()
            }
        } label: {
            HStack(spacing: 0) {
                Image(systemName: manager.isRecording ? "stop.fill" : "mic.fill")
                    .contentTransition(.opacity)
                if !manager.isRecording {
                    Text("Start Recording")
                        .padding(.leading, 8)
                        .transition(.opacity)
                }
            }
            .font(.title3.weight(.semibold))
            .frame(height: 26)
        }
        .buttonStyle(RecordButtonStyle(tint: Self.recordTint))
        .animation(.easeOut(duration: 0.16), value: manager.isRecording)
    }

    private static let recordTint = Color(hue: 252.0 / 360.0, saturation: 0.65, brightness: 1.0)

    @ViewBuilder
    private var resultsView: some View {
        if !manager.detections.isEmpty {
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
        } else if !manager.isRecording {
            ContentUnavailableView {
                Label("No detections yet", systemImage: "bird")
            } description: {
                Text("Tap Start Recording to begin identifying birds.")
            }
            .transition(.opacity)
        } else {
            Color.clear
        }
    }
}

#Preview {
    ContentView()
        .environment(RecordingManager())
}

/// Custom record button style that replaces `.borderedProminent` so we have
/// full control over the press animation. No spring overshoots, no Liquid
/// Glass settling — just a tinted capsule whose only state change on press
/// is a quick opacity dip.
private struct RecordButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(minHeight: 50)
            .background {
                Capsule(style: .continuous).fill(tint)
            }
            .opacity(configuration.isPressed ? 0.78 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct SpectrogramView: UIViewRepresentable {
    let renderer: SpectrogramRenderer
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> SpectrogramHostView {
        let v = SpectrogramHostView()
        v.renderer = renderer
        v.invert = colorScheme == .light
        v.start()
        return v
    }

    func updateUIView(_ uiView: SpectrogramHostView, context: Context) {
        uiView.renderer = renderer
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
    var invert: Bool = false {
        didSet { backgroundColor = invert ? .white : .black }
    }

    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
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

    private var lastSetImage: CGImage?

    @objc private func tick(_ link: CADisplayLink) {
        renderer?.pumpColumns(at: link.targetTimestamp)
        guard let image = renderer?.snapshot(inverted: invert) else { return }
        // Skip the layer.contents write when the renderer returns the same
        // cached image — saves a CoreAnimation transaction per idle frame.
        if image === lastSetImage { return }
        lastSetImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }
}
