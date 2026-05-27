import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(RecordingManager.self) private var manager
    @Environment(LifeListStore.self) private var lifeListStore

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                resultsView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Reserve 80pt at the top for the spectrogram only when
                    // there are real rows to scroll; the empty filler renders
                    // through the overlay and shouldn't get shoved down.
                    .padding(.top, (manager.isRecording && !manager.detections.isEmpty) ? 80 : 0)
                    .animation(.easeOut(duration: 0.15), value: manager.isRecording)
                    .animation(.easeOut(duration: 0.15), value: manager.detections.isEmpty)

                if manager.isRecording {
                    SpectrogramView(renderer: manager.spectrogram)
                        .frame(height: 80)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .transition(.opacity.animation(.smooth(duration: 0.16)))
                }
            }
            .overlay {
                if manager.detections.isEmpty {
                    ContentUnavailableView {
                        Label("No detections yet", systemImage: "bird")
                    } description: {
                        Text("Tap Start Recording to begin identifying birds.")
                    }
                    .opacity(manager.isRecording ? 0 : 1)
                    .animation(.easeInOut(duration: 0.25), value: manager.isRecording)
                    .allowsHitTesting(false)
                }
            }

            // Watch-session caption. Always rendered (with a space as the
            // placeholder string) so the layout below doesn't jump when it
            // appears / disappears.
            Text(manager.watchRecording ? "Listening on Apple Watch" : " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal)
                .padding(.bottom, 2)
                .opacity(manager.watchRecording ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: manager.watchRecording)

            // Always render a single-line caption here so the record
            // button's vertical position is fixed from launch. While the
            // range filter is still loading, the text is an invisible
            // placeholder; it fades in once `locationStatus` resolves.
            Text(manager.locationStatus ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .opacity(manager.locationStatus == nil ? 0 : 1)
                .animation(.easeIn(duration: 0.25), value: manager.locationStatus)

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
        // Mirror starred status into the manager so notifications + the
        // spectrogram's blue band reflect mid-session star toggles.
        .onChange(of: lifeListStore.starredNames, initial: true) { _, new in
            manager.updateStarred(new)
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
    /// Highlight purple — soft tint blended into the row background.
    private static let recordHighlight = Color(hue: 252.0 / 360.0, saturation: 0.5, brightness: 1.0)

    @ViewBuilder
    private var resultsView: some View {
        if !manager.detections.isEmpty {
            List(manager.detections) { detection in
                detectionRow(for: detection)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        } else {
            // Filler is rendered via the body's .overlay so its position
            // isn't affected when the spectrogram appears above it.
            Color.clear
        }
    }

    // Faint blue persistent tint for starred species (alert-me list).
    private static let starredTint = Color(hue: 215.0 / 360.0, saturation: 0.5, brightness: 1.0)

    private func detectionRow(for detection: Detection) -> some View {
        let flashing = manager.flashIDs.contains(detection.id)
        // "Not in life list at session start" — frozen for the duration of
        // the recording, so the tint doesn't vanish the instant the user
        // taps the plus to add.
        let needsLifeListAdd = !manager.lifeListSnapshot.contains(detection.scientificName)
        // Once the user taps the plus, the species is in the live store
        // even though the session snapshot still says it wasn't. That flip
        // is how we know to swap plus → checkmark.
        let alreadyAdded = lifeListStore.entries.contains { $0.scientificName == detection.scientificName }
        let isStarred = lifeListStore.entries.first(where: { $0.scientificName == detection.scientificName })?.isStarred ?? false
        // Flash color picks the same hue family as the persistent tint:
        // purple for needs-add, blue for starred, yellow otherwise.
        let flashColor: Color = needsLifeListAdd
            ? Color(hue: 252.0/360.0, saturation: 0.5, brightness: 1.0)
            : (isStarred
               ? Color(hue: 215.0/360.0, saturation: 0.5, brightness: 1.0)
                : Color(hue: 50.0/360.0, saturation: 0.6, brightness: 1.0))

        return VStack(alignment: .leading, spacing: 8) {
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
                if needsLifeListAdd {
                    Button {
                        guard !alreadyAdded else { return }
                        let sci = detection.scientificName
                        let com = detection.commonName
                        // Tag the new entry with our current coordinate so
                        // it shows up on the Map tab. Cache lookup is sync
                        // when we already have a fix (the recording session
                        // has been running, so `refreshSpeciesFilter`
                        // populated it); falls back to an async fetch otherwise.
                        let cached = (LocationCache.shared.lastLatitude,
                                      LocationCache.shared.lastLongitude)
                        if let lat = cached.0, let lon = cached.1 {
                            lifeListStore.add(
                                scientificName: sci,
                                commonName: com,
                                latitude: lat,
                                longitude: lon
                            )
                        } else {
                            lifeListStore.add(scientificName: sci, commonName: com)
                            Task {
                                guard let coord = await LocationCache.shared.current() else { return }
                                lifeListStore.updateFirstLocation(
                                    scientificName: sci,
                                    latitude: coord.latitude,
                                    longitude: coord.longitude
                                )
                            }
                        }
                    } label: {
                        Image(systemName: alreadyAdded ? "checkmark" : "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 32, height: 32)
                            .background(Self.recordTint, in: Circle())
                    }
                    .buttonStyle(NoDimButtonStyle())
                    .accessibilityLabel(
                        alreadyAdded
                            ? "\(detection.commonName) added to Life List"
                            : "Add \(detection.commonName) to Life List"
                    )
                } else {
                    // Already in life list — show the thumbnail at the row's
                    // trailing edge, same place the add button would occupy.
                    SpeciesThumbnail(scientificName: detection.scientificName)
                }
            }

            // Full-width hero image for unseen species. Starred / already-in-
            // list rows skip this and keep the compact thumbnail above.
            if needsLifeListAdd {
                SpeciesHeroImage(scientificName: detection.scientificName)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // .background lives *inside* the row's content view, so it stays
        // glued to the row through any scroll rubberband. Using
        // .listRowBackground would let the rubberband expose a sliver of
        // the system background when swiping diagonally.
        .background(
            ZStack {
                Self.recordHighlight
                    .opacity(needsLifeListAdd ? 0.25 : 0)
                Self.starredTint
                    .opacity(!needsLifeListAdd && isStarred ? 0.25 : 0)
                flashColor
                    .opacity(flashing ? 0.25 : 0)
                    .animation(
                        flashing ? nil : .easeOut(duration: 0.5),
                        value: flashing
                    )
            }
        )
    }
}

/// Full-width image for an unseen species. Pinned to a 16:9 aspect box and
/// cropped (`.scaledToFill`) so rows look uniform even though the bundled
/// `SpeciesImagesLarge` files have varying aspect ratios.
private struct SpeciesHeroImage: View {
    let scientificName: String

    var body: some View {
        Group {
            if let img = SpeciesImageCache.shared.image(for: scientificName) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "bird")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .background(.fill.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            // Clip to the capsule so the "Start Recording" label can't spill
            // out the right edge while the button is mid-shrink toward its
            // mic-only width.
            .clipShape(Capsule(style: .continuous))
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
        // Capped at 60 Hz on purpose: at 120 Hz the FFT + 700KB pixel
        // snapshot per frame burns enough main-thread time to stutter
        // List scrolling. Visually the spectrogram is already smooth at 60.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
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
    /// Background queue that runs `pumpColumns` + `snapshot` off the main
    /// thread. Critical for scroll smoothness — these two calls together do
    /// the FFT, ~700 KB pixel memcpy, and CGImage construction on every
    /// frame, which used to compete with `UICollectionView` scroll work.
    /// Renderer state is protected by its own lock, so concurrent access
    /// from the audio thread + this queue is safe.
    private static let renderQueue = DispatchQueue(
        label: "kestrel.spectrogram.render",
        qos: .userInteractive
    )
    /// Skip-frame guard: if the previous frame's background render is still
    /// running when the next display tick fires, we drop the new tick instead
    /// of piling up. Accessed only from main.
    private var renderInFlight: Bool = false

    @objc private func tick(_ link: CADisplayLink) {
        guard let renderer else { return }
        if renderInFlight { return }
        renderInFlight = true
        let target = link.targetTimestamp
        let invertNow = invert
        Self.renderQueue.async { [weak self] in
            renderer.pumpColumns(at: target)
            let image = renderer.snapshot(inverted: invertNow)
            DispatchQueue.main.async {
                guard let self else { return }
                self.renderInFlight = false
                guard let image else { return }
                if image === self.lastSetImage { return }
                self.lastSetImage = image
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.layer.contents = image
                CATransaction.commit()
            }
        }
    }
}
