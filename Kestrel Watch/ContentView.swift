import Combine
import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager.shared
    @Environment(\.scenePhase) private var scenePhase
    /// True while the always-on display is dimmed (wrist down). We suppress the
    /// detection flash then — a full-screen pulse on the dimmed screen is jarring
    /// and burns battery for something the user isn't looking at.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    /// Opacity of the full-screen detection flash overlay. Snapped to 1 when a
    /// bird is heard, then eased back to 0.
    @State private var flashOpacity: Double = 0

    /// Fixed base size of the record control; the morph is a uniform
    /// `scaleEffect` of this so the circle and glyph shrink together as one unit.
    private static let buttonBaseSize: CGFloat = 110
    /// Diameter of the stop and add buttons — the small buttons shown while
    /// recording. Set this directly; the margin between the buttons and the
    /// species name below them follows from this and the screen size.
    private static let cornerButtonSize: CGFloat = 42
    /// Horizontal gap between the stop button and the add button beside it.
    private static let interButtonGap: CGFloat = 8
    private static let sqrt2: CGFloat = 1.414213562373095
    /// Inset between the bird image/placeholder and the screen edges. Paired
    /// with `ContainerRelativeShape` so the corner radius stays concentric with
    /// the watch bezel as this changes. Tunable per watch size in `WatchMetrics`.
    private static var imageMargin: CGFloat { WatchMetrics.current.imageMargin }
    /// Vertical gap between the species name and the photo below it. Tunable per
    /// watch size in `WatchMetrics`.
    private static var nameImageGap: CGFloat { WatchMetrics.current.nameImageGap }
    /// Approximate corner radius of the watch's physical screen. watchOS exposes
    /// no public API for this, so we set it as the root container shape; the
    /// image's `ContainerRelativeShape` then insets it by `imageMargin` to stay
    /// concentric. Resolved per device by `WatchMetrics` — add measured sizes
    /// there to tune the bezel match on new watches.
    private static var screenCornerRadius: CGFloat { WatchMetrics.current.screenCornerRadius }

    /// True only when the *watch's own* microphone and/or location permission is
    /// explicitly denied. The watch now records with its own mic and supplies its
    /// own coordinate, so its own permissions gate recording: the button becomes a
    /// gray lock and tapping it explains how to fix it in the watch's Settings.
    /// Permissions that are merely undetermined do NOT block — the first start
    /// prompts for them — so a brand-new watch-first user just sees a normal
    /// record button.
    private var blockedForPermissions: Bool {
        session.permissionDenied && !session.isRecording
    }

    /// Drives the explanatory modal shown when the user taps the gray lock button.
    @State private var showPermissionInfo = false

    /// The birding walk waiting on a save/discard decision, if any. Observed from
    /// the workout manager so the prompt appears however the session ended —
    /// including the unattended endings that used to log a workout (and notify
    /// the user's activity-sharing friends) with no one watching.
    @State private var workout = WatchWorkoutManager.shared

    /// Gray fill for the locked (permission-denied) record button, matching the
    /// phone's locked state.
    private static let lockedTint = Color(white: 0.45)

    var body: some View {
        let recording = session.isRecording

        ZStack {
            // Standing background for the current bird's kind (black / blue /
            // purple), with a deeper flash of the same hue pulsed over it when a
            // starred or new bird is heard, then fading back to the dim standing
            // color — mirroring the phone Identify tab's per-detection row flash
            // (see `flash()`). A normal bird updates the screen without a flash.
            backgroundColor.ignoresSafeArea()
            flashColor
                .ignoresSafeArea()
                .opacity(flashOpacity)

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
            // photo can sit at the very bottom in the true corner. Always in
            // the tree and driven by opacity (not an `if` + `.transition`) so
            // it fades symmetrically: in when recording starts, out when it
            // stops — both under the manager's `withAnimation(isRecording)`.
            nowHearing
                .ignoresSafeArea()
                .opacity(recording ? 1 : 0)

            // The record/stop control morphs from the centered mic into the
            // top-left stop button; the add-to-life-list button sits just to
            // its right (a `gap` apart) and is shown only for a new species.
            // Both are sized + placed against the *full* screen (ignoring the
            // safe area): shrunk so their bottom clears the species name by a
            // `gap`, and positioned so the stop button sits a `gap` diagonally
            // off the rounded bezel corner. `.position` interpolates linearly
            // and the button scales uniformly (see `recordButton`), so the
            // record control travels in a straight line between the centered
            // mic and the corner stop button — identically in both directions.
            GeometryReader { geo in
                let r = Self.cornerButtonSize / 2
                let cornerC = Self.cornerCenter(radius: r)
                let side: CGFloat = recording ? Self.cornerButtonSize : Self.buttonBaseSize

                recordButton(scale: side / Self.buttonBaseSize)
                    .position(
                        x: recording ? cornerC : geo.size.width / 2,
                        y: recording ? cornerC : geo.size.height / 2
                    )

                // Idle-screen caption sitting just below the centered play
                // button. Fades out (with the button's morph to the corner) as
                // recording starts, so the now-hearing screen has the space.
                // Reads "Permissions Needed" under the gray lock so the caption
                // matches the button's locked state rather than inviting a tap to
                // record.
                Text(blockedForPermissions ? "Permissions Needed" : "Start Birding")
                    .font(.system(size: 16, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .frame(width: geo.size.width - 24)
                    // Keep the caption on one line and scale it down to fit a
                    // narrow screen rather than wrapping to a second line.
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .position(
                        x: geo.size.width / 2,
                        y: geo.size.height / 2 + Self.buttonBaseSize / 2 + 24
                    )
                    .opacity(recording ? 0 : 1)
                    .allowsHitTesting(false)

                addButton(size: Self.cornerButtonSize)
                    // `interButtonGap` to the right of the stop button, same row.
                    .position(x: cornerC + 2 * r + Self.interButtonGap, y: cornerC)
                    // Visible only while recording a bird that was new to the
                    // life list at session start; fades with the rest of the
                    // content.
                    .opacity(showAddButton ? 1 : 0)
                    .allowsHitTesting(showAddButton)
            }
            .ignoresSafeArea()

            // A denied watch permission is surfaced entirely through the gray lock
            // button (see `blockedForPermissions` / `recordButton`) — tapping it
            // opens the explanatory sheet. No full-screen error overlay: the gray
            // button already communicates the blocked state from the outset.
        }
        .animation(.easeInOut(duration: 0.25), value: blockedForPermissions)
        // Explains why the record button is locked (the watch's own mic / location
        // is denied). The watch can't deep-link to Settings, so it tells the user
        // where to go.
        .sheet(isPresented: $showPermissionInfo) {
            permissionInfo
        }
        // Nothing has been written to HealthKit at this point — the walk is only
        // logged if the user taps Save here.
        .sheet(item: Binding(
            get: { workout.pendingSave },
            // Dismissal is driven entirely by the buttons, each of which clears
            // `pendingSave` itself. The setter deliberately does nothing: mapping
            // a swipe-away onto Discard would throw the walk out on an ambiguous
            // gesture, and onto Finish would log one the user never asked for.
            set: { _ in }
        )) { pending in
            saveWorkoutPrompt(pending)
                .interactiveDismissDisabled()
        }
        // The record/stop morph is animated explicitly via `withAnimation` in
        // the session manager (so the audio bring-up/teardown can be deferred
        // until after it). Only the bird cross-fade is animated here.
        .animation(.easeInOut(duration: 0.3), value: session.lastBird)
        .task {
            WatchSessionManager.shared.activate()
            Self.prewarmText()
            // HealthKit access is no longer requested here at launch — it's
            // deferred to the first time the user actually starts a session (see
            // `WatchWorkoutManager.start`), so a brand-new user isn't met with a
            // health-permission sheet before they've done anything.

            // If watchOS killed us mid-session, the workout session outlived the
            // app and is still running with nothing driving it — reclaim and end
            // it, or the next start would be refused and the orphan would keep
            // draining battery. It routes through the same confirm-before-save
            // prompt, so a terminated session still never logs a walk silently.
            await WatchWorkoutManager.shared.recoverOrphanedSession()
        }
        // Start Recording complication: drain a pending request when the app
        // becomes active (cold/background launch) and immediately when it fires
        // while already active. `handleRemoteStart()` is idempotent — a no-op if
        // a session is already running.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                startRecordingIfRequested()
                // The user may have flipped mic/location in the watch's Settings
                // while away; re-read so the lock clears (or appears) on return.
                session.refreshPermissionState()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingIntentRequest.notification)) { _ in
            startRecordingIfRequested()
        }
        // Flash the background each time a bird is heard.
        .onChange(of: session.heardTick) { _, _ in flash() }
        // Surfaced only when the phone link is lost for good (no heartbeat for a
        // full minute) and the session was stopped — not for transient dips.
        .alert(
            "iPhone Connection",
            isPresented: Binding(
                get: { session.connectionAlert != nil },
                set: { if !$0 { session.connectionAlert = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(session.connectionAlert ?? "")
        }
    }

    private func startRecordingIfRequested() {
        guard RecordingIntentRequest.consume() else { return }
        session.handleRemoteStart()
    }

    // MARK: - Background

    /// Standing (solid-state) background for the current bird's kind — black for
    /// a normal/known bird, dark blue for a starred one, dark purple for a new
    /// lifer (red for a debug injection). Unchanged from the original design; the
    /// flash pulses over this and fades back to it.
    private var backgroundColor: Color {
        guard session.isRecording, let bird = session.lastBird else { return Self.idleBackground }
        switch bird.highlight {
        case .newSpecies: return Self.newSpeciesBackground
        case .starred:    return Self.starredBackground
        case .normal:     return .black
        }
    }

    /// Standing background before any bird has been heard (idle, or recording but
    /// nothing identified yet).
    private static let idleBackground: Color = .black

    /// The color flashed over the standing background when a bird is heard — a
    /// deeper beat of the same purple/blue hue that fades back to the dimmer
    /// standing tint, mirroring the phone Identify tab's per-detection row flash.
    /// A normal bird never flashes (see `flash()`), so it has no flash color.
    private var flashColor: Color {
        switch session.lastBird?.highlight {
        case .newSpecies:    return Self.newSpeciesFlash
        case .starred:       return Self.starredFlash
        case .normal, .none: return .clear
        }
    }

    /// Snap the flash overlay to full, then ease it back to transparent so the
    /// standing background shows through again. Suppressed while the always-on
    /// display is dimmed, and when not recording.
    private func flash() {
        guard session.isRecording, !isLuminanceReduced else { return }
        // Only the highlighted birds pulse — a plain/normal bird updates the
        // screen without any flash. New species + starred flash a deeper
        // purple/blue that resolves back to their dimmer standing tint.
        switch session.lastBird?.highlight {
        case .newSpecies, .starred:
            break
        default:
            return
        }
        flashOpacity = 1
        withAnimation(.easeOut(duration: 0.6)) {
            flashOpacity = 0
        }
    }

    // Standing background tints the flash resolves back to — dim purple (hue
    // 252°) for a new species, dim blue (hue 215°) for a starred one. A normal
    // bird has no tint (black).
    private static let newSpeciesBackground =
        Color(hue: 252.0 / 360.0, saturation: 0.60, brightness: 0.34)
    private static let starredBackground =
        Color(hue: 215.0 / 360.0, saturation: 0.60, brightness: 0.34)

    // Flash pulse — a deeper beat of the same hue than the dim standing tint, so
    // the pulse reads, then fades back to the standing color. Only new species
    // and starred birds flash (matching the phone); a normal bird never does.
    private static let newSpeciesFlash =
        Color(hue: 252.0 / 360.0, saturation: 0.68, brightness: 0.55)
    private static let starredFlash =
        Color(hue: 215.0 / 360.0, saturation: 0.68, brightness: 0.55)

    private static let recordTint = Color(hue: 252.0 / 360.0, saturation: 0.65, brightness: 1.0)

    // MARK: - Record / stop button

    /// The single control the user taps. Rendered at a fixed base size and
    /// scaled as one unit, so the circle and glyph shrink together — no
    /// independent icon frame to drift or slide during the swap. Position +
    /// scale animate solely under the body's `isRecording` animation, so the
    /// morph is a straight, uniform shrink in both directions.
    private func recordButton(scale: CGFloat) -> some View {
        let recording = session.isRecording
        let blocked = blockedForPermissions
        return Button {
            // A denied permission turns the button into a tap-for-explanation
            // lock rather than a recording control (matching the phone).
            if blocked {
                showPermissionInfo = true
            } else {
                session.toggle()
            }
        } label: {
            // All three glyphs are always present and cross-faded by opacity, so
            // the transition is symmetric and each lands at the correct end
            // opacity (0 or 1) — a single swapped `Image` left the outgoing glyph
            // partially visible and snapped at the end.
            ZStack {
                Image(systemName: "play.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .opacity(recording || blocked ? 0 : 1)
                Image(systemName: "stop.fill")
                    .font(.system(size: 40, weight: .bold))
                    .opacity(recording ? 1 : 0)
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .bold))
                    .opacity(blocked && !recording ? 1 : 0)
            }
            .foregroundStyle(.white)
            .frame(width: Self.buttonBaseSize, height: Self.buttonBaseSize)
            // Purple while idle, red once recording (matching the phone's stop
            // button), gray when locked by a denied permission. The fill
            // interpolates with the morph, which runs under the session
            // manager's `withAnimation(isRecording)`.
            .background(Circle().fill(recording ? .red : (blocked ? Self.lockedTint : Self.recordTint)))
            .scaleEffect(scale)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            blocked
                ? "Recording unavailable — permissions needed"
                : (recording ? "Stop recording" : "Start recording")
        )
    }

    /// Explanatory modal shown when the user taps the locked record button —
    /// recording needs the watch's own microphone and location access, which was
    /// denied and must be re-enabled in the watch's Settings. Tap Done to close.
    private var permissionInfo: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Self.recordTint)
                Text("Permissions Needed")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Kestrel needs microphone and location access to identify birds. Grant access for Kestrel in the watch's Settings app.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Done") { showPermissionInfo = false }
                    .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// Asks whether to log the birding walk to the Fitness app. Deliberately a
    /// question rather than an automatic save: writing the workout is what makes
    /// Apple announce it to the user's activity-sharing friends, and a session
    /// can end without the user ever asking it to (a dropped phone link, an
    /// OS-side termination and relaunch).
    private func saveWorkoutPrompt(_ pending: WatchWorkoutManager.PendingWorkout) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 28))
                    .foregroundStyle(Self.recordTint)
                Text(pending.canResume ? "Done Birding?" : "Save This Walk?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("\(Self.durationText(pending.duration)) so far. Finishing logs it to Fitness and counts toward your rings.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Finish") { Task { await workout.save() } }
                    .padding(.top, 4)
                // Only offered while the workout is merely paused, where resuming
                // continues the same walk. Once the session is truly over there's
                // nothing to resume into, and the button would be a lie.
                if pending.canResume {
                    Button("Resume") { session.resumeBirding() }
                        .tint(Self.recordTint)
                }
                Button("Discard") { Task { await workout.discard() } }
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// "1h 12m" / "43m" — enough for the user to recognize which walk this was.
    private static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds) / 60)
        let (h, m) = (minutes / 60, minutes % 60)
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    // MARK: - Add to life list button

    /// Whether the add-to-life-list button is shown: only while recording and
    /// only for a bird that was *not* on the life list at the start of this
    /// listening session. The phone freezes its life-list snapshot per session,
    /// so a bird's `.newSpecies` highlight (and thus this button) stays constant
    /// for the whole session even after the user adds it — the button just
    /// flips to its checkmark state.
    private var showAddButton: Bool {
        session.isRecording && session.lastBird?.highlight == .newSpecies
    }

    /// A circle matching the stop button in size and color, carrying the same
    /// plus → checkmark add-to-life-list affordance as the phone's Identify and
    /// life-list rows (`symbolEffect(.replace)`), including tap-to-undo. The
    /// checkmark state is remembered for the whole session, so re-hearing an
    /// already-added bird shows the checkmark without re-adding. `size` matches
    /// the (shrunk) stop button.
    private func addButton(size: CGFloat) -> some View {
        let added = session.isCurrentBirdAdded
        return Button {
            session.toggleCurrentBirdLifeList()
        } label: {
            Image(systemName: added ? "checkmark" : "plus")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace, options: .speed(2.6)))
                .frame(width: size, height: size)
                .background(Circle().fill(Self.recordTint))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(added ? "Remove from life list" : "Add to life list")
    }

    // MARK: - Corner button geometry

    /// Center coordinate (x == y, on the diagonal) for a corner button of
    /// radius `r` so its nearest edge sits `gap` points off the rounded bezel,
    /// measured along the diagonal. Derived from the bezel's corner radius: the
    /// bezel surface in the diagonal direction is `screenCornerRadius` from the
    /// corner's center of curvature at `(R, R)`.
    private static func cornerCenter(radius r: CGFloat) -> CGFloat {
        cornerConst + r / sqrt2
    }

    /// Distance from the screen corner to a zero-radius button's center that
    /// already accounts for the bezel curve + the diagonal corner gap.
    /// `cornerCenter` just adds the button's own `r / √2`. The diagonal
    /// clearance reuses `imageMargin`, so the stop button sits the same distance
    /// off the bezel as the bird image's inset — both track the per-watch margin.
    private static var cornerConst: CGFloat {
        screenCornerRadius * (1 - 1 / sqrt2) + imageMargin / sqrt2
    }

    // MARK: - Recording ("now hearing")

    /// The species name centered above the photo, both anchored to the bottom
    /// of the screen (bottom margin matching the side margins). No
    /// `GeometryReader` — its first-time layout pass was the render stall; the
    /// image sizes itself with `aspectRatio` instead.
    private var nowHearing: some View {
        VStack(spacing: 0) {
            // A flexible spacer pushes the name + photo to the bottom; the name
            // sits `nameImageGap` above the photo, which keeps a fixed bottom
            // margin (matching the sides).
            Spacer(minLength: 0)
            nameLabel
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
            Color.clear.frame(height: Self.nameImageGap)
            birdImage
            Color.clear.frame(height: Self.imageMargin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
    /// same full width at the photos' usual 4:3 so it's never narrow.
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
        .id(session.lastBird?.scientificName)
        .transition(.opacity)
    }

    /// The full single-line height of the `.headline` font. The name label is
    /// pinned to this height so that, as a long name (or the "Listening…"
    /// caption) scales down via `minimumScaleFactor`, the text stays vertically
    /// centered within the same fixed box — its midline holds steady between the
    /// photo below and the controls above rather than drifting with the scale.
    private static var nameLineHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .headline).lineHeight
    }

    private var nameLabel: some View {
        Group {
            if let bird = session.lastBird {
                Text(bird.commonName)
                    .foregroundStyle(.white)
            } else {
                // While the phone is the audio source the watch is only mirroring
                // its now-hearing screen, so make the placeholder say so rather
                // than implying the watch itself is listening.
                Text(session.mirroringPhone ? "Listening on iPhone…" : "Listening…")
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .font(.headline)
        .multilineTextAlignment(.center)
        // Keep every caption on one line and shrink it to fit rather than
        // wrapping — a long species name (or "Listening on iPhone…") scales down
        // instead of stealing a second line from the photo below. No text on the
        // watch should ever wrap.
        .lineLimit(1)
        .minimumScaleFactor(0.3)
        // Fix the box to the full-scale line height and center within it, so the
        // shrunk text keeps its midline instead of shifting the layout.
        .frame(height: Self.nameLineHeight)
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
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: 180)
        )
        renderer.scale = 2
        _ = renderer.uiImage
    }
}

#Preview {
    ContentView()
}
