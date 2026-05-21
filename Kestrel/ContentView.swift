import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(RecordingManager.self) private var manager
    @Environment(LifeListStore.self) private var lifeListStore

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
        .onChange(of: manager.isRecording) { wasRecording, isNowRecording in
            if !wasRecording && isNowRecording {
                // New session — push the current life-list IDs into the
                // manager so both the rows and the spectrogram know which
                // detections still need to be added.
                manager.snapshotLifeList(
                    Set(lifeListStore.entries.map(\.scientificName))
                )
            }
        }
    }

    private var recordButton: some View {
        Button {
            Task { await manager.toggle() }
        } label: {
            HStack(spacing: 0) {
                Image(systemName: manager.isRecording ? "stop.fill" : "mic.fill")
                    .contentTransition(.opacity)
                if !manager.isRecording {
                    Text("Start Recording")
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
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
                let flashing = manager.flashIDs.contains(detection.id)
                // "Not in life list at session start" — frozen for the
                // duration of the recording, so the tint doesn't vanish the
                // instant the user swipes to add.
                let needsLifeListAdd = !manager.lifeListSnapshot.contains(detection.scientificName)
                // Rows in the life list flash pastel yellow; rows that need
                // to be added flash a mildly-deeper shade of the persistent
                // purple — subtler than a saturated dark purple.
                let flashColor: Color = needsLifeListAdd
                    ? Color(hue: 252.0/360.0, saturation: 0.72, brightness: 0.85)
                    : Color(hue: 50.0/360.0, saturation: 0.45, brightness: 1.0)
                HStack(spacing: 12) {
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
                    if needsLifeListAdd {
                        Button {
                            lifeListStore.add(
                                scientificName: detection.scientificName,
                                commonName: detection.commonName
                            )
                        } label: {
                            Image(systemName: "plus")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Self.recordTint, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add \(detection.commonName) to Life List")
                    }
                    SpeciesThumbnail(scientificName: detection.scientificName)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                // .background lives *inside* the row's content view, so it
                // stays glued to the row through any scroll rubberband.
                // Using .listRowBackground would let the rubberband expose a
                // sliver of the system background when swiping diagonally.
                .background(
                    ZStack {
                        Self.recordTint
                            .opacity(needsLifeListAdd ? 0.4 : 0)
                        flashColor
                            .opacity(flashing ? 0.4 : 0)
                            .animation(
                                flashing ? nil : .easeOut(duration: 0.5),
                                value: flashing
                            )
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
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
/// Glass settling — just a tinted capsule. On press the button briefly
/// grows + dims, both with the same fast easeOut so they feel like one motion.
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
            .scaleEffect(configuration.isPressed ? 1.1 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
    /// True while the app's scene is active (foreground + not locked).
    private var isAppActive: Bool = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.isOpaque = true

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleResignActive),
                       name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleBecomeActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        stop()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        updatePauseState()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // SwiftUI removes the view from its window when the Identify tab is
        // not visible; pause the link so we do zero render work.
        updatePauseState()
    }

    @objc private func handleResignActive() {
        isAppActive = false
        updatePauseState()
    }

    @objc private func handleBecomeActive() {
        isAppActive = true
        updatePauseState()
    }

    private func updatePauseState() {
        // No work when: app inactive (backgrounded / screen off), or the view
        // isn't currently attached to a window (e.g. user is on Life List).
        let shouldPause = !isAppActive || window == nil
        displayLink?.isPaused = shouldPause
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
