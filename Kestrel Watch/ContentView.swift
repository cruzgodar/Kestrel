import Combine
import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Fixed base size of the record control; the morph is a uniform
    /// `scaleEffect` of this so the circle and glyph shrink together as one unit.
    private static let buttonBaseSize: CGFloat = 110
    /// Diameter of the corner stop button, and of the prompt's Discard / Save
    /// buttons. Set this directly; the margin between a button and the species
    /// name below it follows from this and the screen size.
    private static let cornerButtonSize: CGFloat = 42
    /// Gap between the resume/discard/save buttons and their captions, so the
    /// prompt's text lines up off the same column the buttons sit in.
    private static let interButtonGap: CGFloat = 8
    /// Glyph diameter inside a corner button, as a fraction of the button. The
    /// single knob for every small button's icon size — the record control's
    /// stop/lock/play glyphs and the prompt buttons' trash/check are all
    /// pre-scaled to match it once shrunk.
    private static let cornerGlyphRatio: CGFloat = 0.46
    /// Point size a corner glyph must be drawn at *inside the full-size record
    /// button* to land at `cornerGlyphRatio` once scaled down to the corner.
    private static var cornerGlyphBaseSize: CGFloat {
        cornerButtonSize * cornerGlyphRatio * (buttonBaseSize / cornerButtonSize)
    }
    /// Checkmarks carry less ink than a filled square at the same point size, so
    /// the save glyph is drawn a touch larger to read as the same weight as the
    /// stop glyph it replaces.
    private static var checkGlyphBaseSize: CGFloat { cornerGlyphBaseSize * 1.1 }
    private static let sqrt2: CGFloat = 1.414213562373095
    /// Clearance the corner buttons keep off the rounded bezel (measured along
    /// the diagonal), and the trailing margin the prompt captions stop at. The
    /// bird image itself is no longer inset — it runs to the left, right and
    /// bottom edges. Tunable per watch size in `WatchMetrics`.
    private static var edgeMargin: CGFloat { WatchMetrics.current.edgeMargin }
    /// Radius of the bird photo's *top* corners. Its bottom corners are square
    /// and simply cut off by the bezel, whose radius this matches so all four
    /// corners read the same. Tunable per watch size in `WatchMetrics`.
    private static var imageTopCornerRadius: CGFloat { WatchMetrics.current.imageTopCornerRadius }
    /// Vertical gap between the species name and the photo below it. Tunable per
    /// watch size in `WatchMetrics`.
    private static var nameImageGap: CGFloat { WatchMetrics.current.nameImageGap }
    /// Approximate corner radius of the watch's physical screen. watchOS exposes
    /// no public API for this, so the corner-button geometry derives its diagonal
    /// clearance from this value. Resolved per device by `WatchMetrics` — add
    /// measured sizes there to tune the bezel match on new watches.
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
    /// Green for the save button at the bottom of the prompt; red for the discard
    /// button above it, matching the phone's destructive actions.
    private static let saveTint = Color.green
    private static let discardTint = Color.red

    /// True while a finished birding walk is waiting on a resume/discard/save
    /// answer. The prompt is drawn in place of the recording controls rather
    /// than in a sheet (see the prompt buttons in `body`), so it shares the
    /// record button's morph geometry.
    private var prompting: Bool { workout.pendingSave != nil }

    /// The prompt's three answers, top to bottom. Resume is the record control
    /// itself — the stop button slides down into it and back up out of it — while
    /// Discard and Save are their own buttons, each of which morphs into the
    /// centered record button when it's the one the user taps.
    private enum PromptRole {
        case resume, discard, save
    }

    /// The answer currently animating back into the record button, if any. Set on
    /// the tap and cleared once the morph has played, at which point the real
    /// save/discard work runs (see `answerPrompt`).
    @State private var morphing: PromptRole?

    /// True while the prompt is up *and* settled — not mid-morph. Everything the
    /// prompt draws except the button the user actually hit (the other buttons,
    /// all three captions) is keyed off this, so the rest clears away as the
    /// answer animates.
    private var promptVisible: Bool { prompting && morphing == nil }

    /// Clearance between two prompt circles: a quarter of their radius.
    private static var promptSlotGap: CGFloat { cornerButtonSize * 0.25 }
    /// Vertical distance between the prompt buttons' centers — a diameter plus
    /// that gap. Doubles as the height of each row's tap target, so the rows tile
    /// the stack with no dead band between them.
    private static var promptSlotSpacing: CGFloat { cornerButtonSize + promptSlotGap }

    /// Center y of a prompt button. The stack is centered on the screen — which
    /// pulls the buttons and their captions in from the corners the prompt used
    /// to be spread across — and Resume drops out when the walk can't be resumed,
    /// leaving the other two re-centered rather than a hole at the top.
    ///
    /// A prompt that isn't up yet is laid out as though it has all three answers,
    /// which is what a user-initiated stop is about to produce. Otherwise the
    /// slots would reflow from two rows to three in the very transaction that
    /// fades the prompt in, and Discard and Save would drift into place instead
    /// of simply appearing there.
    private func promptSlotY(_ role: PromptRole, in height: CGFloat) -> CGFloat {
        let hasResume = !prompting || showResumeButton
        let roles: [PromptRole] = hasResume ? [.resume, .discard, .save] : [.discard, .save]
        let index = roles.firstIndex(of: role) ?? 0
        let middle = CGFloat(roles.count - 1) / 2
        return height / 2 + (CGFloat(index) - middle) * Self.promptSlotSpacing
    }

    var body: some View {
        let recording = session.isRecording
        let prompting = self.prompting
        // The record control doubles as the prompt's Resume button whenever
        // there's a walk to resume: tapping stop slides it out of the corner and
        // down into the top slot, and tapping it there sends it back up.
        let asResume = prompting && showResumeButton
        // Both states hold the record control at `cornerButtonSize`: recording
        // (as the stop button, in the corner) and prompting-with-resume (as the
        // Resume button, a slot above center). Everything keyed off the morph
        // reads this rather than `recording` alone, so stopping flows straight
        // into the prompt without the button flying back to center in between.
        let shrunk = recording || asResume
        // The idle screen — the big centered record button and its caption — is
        // also what a tapped Save/Discard is animating back toward, so it comes
        // out from behind the prompt as that morph plays.
        let idling = !recording && (!prompting || morphing != nil)

        ZStack {
            // The screen stays black whatever is heard. A starred or new bird is
            // marked by tinting the species name instead (see `nameColor`) — a
            // full-screen wash and flash on the wrist was more alarm than
            // information.
            Color.black.ignoresSafeArea()

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
            // top-left stop button. It is sized + placed against the *full*
            // screen (ignoring the safe area): shrunk so its bottom clears the
            // species name by a `gap`, and positioned so it sits a `gap`
            // diagonally off the rounded bezel corner. `.position` interpolates
            // linearly and the button scales uniformly (see `recordButton`), so the
            // record control travels in a straight line between the centered
            // mic and the corner stop button — identically in both directions,
            // and on down to the prompt's Resume slot and back when the user
            // stops a walk. The prompt's other two answers are built the same
            // way so whichever one is tapped can travel back to the center.
            GeometryReader { geo in
                let r = Self.cornerButtonSize / 2
                let cornerC = Self.cornerCenter(radius: r)
                let side: CGFloat = shrunk ? Self.cornerButtonSize : Self.buttonBaseSize
                // Leading edge of the prompt's captions — a gap to the right of
                // the corner buttons, which all share the stop button's column.
                let labelX = cornerC + r + Self.interButtonGap
                let labelW = max(0, geo.size.width - labelX - Self.edgeMargin)
                // Where the record control parks: the corner while recording, the
                // Resume slot while the prompt offers one, dead center
                // otherwise — including while faded out behind a save/discard
                // morph, so the hand-off at the end of that morph lands it exactly
                // where the growing button finished.
                let recordY = asResume
                    ? promptSlotY(.resume, in: geo.size.height)
                    : (recording ? cornerC : geo.size.height / 2)
                // The record control is Resume while the prompt is up, so it's
                // gone when there's nothing to resume back into, and it clears
                // away while a save/discard answer morphs into its place.
                let showRecordControl = !prompting || (promptVisible && showResumeButton)

                recordButton(scale: side / Self.buttonBaseSize)
                    .position(x: shrunk ? cornerC : geo.size.width / 2, y: recordY)
                    .opacity(showRecordControl ? 1 : 0)
                    .allowsHitTesting(showRecordControl)

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
                    .opacity(idling ? 1 : 0)
                    .allowsHitTesting(false)

                // Resume / Discard / Save, drawn directly on the screen rather
                // than in a sheet so the buttons can morph into and out of the
                // record control instead of sliding a modal over it. All three
                // share the stop button's left-hand column, stacked around the
                // middle of the screen; Resume is the record control above, and
                // these two morph back into it when tapped.
                promptButton(.discard, in: geo.size)
                promptButton(.save, in: geo.size)

                // Resume's caption tracks the record control's own y, so it
                // travels down from the stop button's row and back up again in
                // lockstep with the button it names, fading as it goes.
                promptLabel("Resume", x: labelX, width: labelW, y: recordY)
                    .opacity(promptVisible && showResumeButton ? 1 : 0)

                // Discard and Save name buttons that don't move, so their
                // captions don't either — see `promptButton` for the transaction.
                promptLabel("Discard", x: labelX, width: labelW,
                            y: promptSlotY(.discard, in: geo.size.height))
                    .transaction { if morphing == nil { $0.animation = nil } }
                    .opacity(promptVisible ? 1 : 0)

                promptLabel("Save Workout", x: labelX, width: labelW,
                            y: promptSlotY(.save, in: geo.size.height))
                    .transaction { if morphing == nil { $0.animation = nil } }
                    .opacity(promptVisible ? 1 : 0)

                // Row-wide tap targets, last so they sit above the buttons they
                // cover. Answering shouldn't demand a 42pt bullseye on a wrist:
                // the whole row — circle, caption and the space between them —
                // takes the tap.
                promptRowTarget(.resume, in: geo.size)
                promptRowTarget(.discard, in: geo.size)
                promptRowTarget(.save, in: geo.size)
            }
            .ignoresSafeArea()

            // A denied watch permission is surfaced entirely through the gray lock
            // button (see `blockedForPermissions` / `recordButton`) — tapping it
            // opens the explanatory sheet. No full-screen error overlay: the gray
            // button already communicates the blocked state from the outset.
        }
        .animation(.easeInOut(duration: 0.25), value: blockedForPermissions)
        // Deliberately *no* implicit animation on `prompting`. Every button here
        // animates first and acts second, which only works if the hand-off at the
        // end of a morph — the tapped button vanishing and the record button
        // reappearing in the exact spot it grew into — happens in one unanimated
        // frame. So the prompt's transitions are driven from explicit
        // `withAnimation` transactions in `answerPrompt`, `WatchSessionManager`
        // and `WatchWorkoutManager` instead.
        // Explains why the record button is locked (the watch's own mic / location
        // is denied). The watch can't deep-link to Settings, so it tells the user
        // where to go.
        .sheet(isPresented: $showPermissionInfo) {
            permissionInfo
        }
        // The resume/discard/save prompt is not a sheet — it's drawn in the
        // main view (see `body`'s prompt buttons) so the stop button morphs
        // down into it and whichever answer is tapped morphs back out into the
        // record button. There's deliberately no swipe-away:
        // mapping an ambiguous gesture onto Discard would throw the walk out,
        // and onto Save would log one the user never asked for. Nothing is
        // written to HealthKit until Save is tapped.
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

    // MARK: - Tints

    /// Purple: the record button's fill. The watch target's own
    /// `Color.kestrelPurple` (see `WatchWelcomeView`), which carries the same
    /// value as the phone's — restating the literal here made two copies inside
    /// one target, which is exactly the drift that constant exists to prevent.
    private static let recordTint = Color.kestrelPurple

    // The two species-name tints, kept as their own constants rather than
    // borrowed from the button and star colors above. They do a different job:
    // those fill a solid shape, these are *text on black*, where a color has to
    // be light enough to read at a glance from arm's length on a dimmed
    // always-on display. Tune the `brightness` of each here — nothing else on
    // the watch uses them, so neither the record button nor anything on the
    // phone moves with them.

    /// Purple the species name is drawn in for a bird not yet on the life list.
    private static let newSpeciesNameTint =
        Color(hue: 252.0 / 360.0, saturation: 0.5, brightness: 1.0)
    /// Blue the species name is drawn in for a starred ("alert me") bird.
    ///
    /// The *hue* follows the phone's star glyph (`LifeListView.starButtonTint`,
    /// hue 220) so the same bird reads as the same color in both places. The
    /// saturation deliberately does not: that glyph is a small solid shape and
    /// needs 0.7 to register at its size, whereas this is text on black, where
    /// 0.5 is what stays legible at arm's length on a dimmed always-on display.
    /// Same job as the phone's row wash (`HighlightedText.starHighlight`), and
    /// the same saturation as it.
    private static let starredNameTint =
        Color(hue: 220.0 / 360.0, saturation: 0.5, brightness: 1.0)

    /// Color the species name is drawn in — purple for a bird that isn't on the
    /// life list yet, blue for a starred ("alert me") one, plain white for an
    /// ordinary bird. This replaces the old full-screen purple/blue wash and
    /// per-detection flash: the same information, confined to the one word it's
    /// actually about.
    private var nameColor: Color {
        switch session.lastBird?.highlight {
        case .newSpecies:    return Self.newSpeciesNameTint
        case .starred:       return Self.starredNameTint
        case .normal, .none: return .white
        }
    }

    // MARK: - Record / stop button

    /// The single control the user taps. Rendered at a fixed base size and
    /// scaled as one unit, so the circle and glyph shrink together — no
    /// independent icon frame to drift or slide during the swap. Position +
    /// scale animate solely under the body's `isRecording` animation, so the
    /// morph is a straight, uniform shrink in both directions.
    private func recordButton(scale: CGFloat) -> some View {
        let recording = session.isRecording
        let prompting = self.prompting
        // The prompt owns the button while it's up, so a denied permission can't
        // also claim it — otherwise the walk-ending Resume button would render as
        // a lock (the prompt runs with `isRecording` already false).
        let blocked = blockedForPermissions && !prompting
        return Button {
            if prompting {
                // Same button, one slot down and purple again: this is Resume,
                // and tapping it sends it straight back up into the stop button.
                session.resumeBirding()
            } else if blocked {
                // A denied permission turns the button into a tap-for-explanation
                // lock rather than a recording control (matching the phone).
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
                    .opacity(recording || blocked || prompting ? 0 : 1)
                Image(systemName: "stop.fill")
                    .font(.system(size: Self.cornerGlyphBaseSize, weight: .bold))
                    .opacity(recording && !prompting ? 1 : 0)
                Image(systemName: "lock.fill")
                    .font(.system(size: Self.cornerGlyphBaseSize, weight: .bold))
                    .opacity(blocked && !recording ? 1 : 0)
                // Resume — the small play glyph the stop button crosses into as
                // it slides down into the prompt. Drawn separately from the idle
                // play above so each lands at its own size: this one is pre-scaled
                // to `cornerGlyphRatio` once shrunk, that one fills the big button.
                Image(systemName: "play.fill")
                    .font(.system(size: Self.cornerGlyphBaseSize, weight: .bold))
                    .opacity(prompting ? 1 : 0)
            }
            .foregroundStyle(.white)
            .frame(width: Self.buttonBaseSize, height: Self.buttonBaseSize)
            // Purple while idle, red once recording (matching the phone's stop
            // button), purple again as the prompt's Resume button once a walk is
            // awaiting a decision, gray when locked by a denied permission. The
            // fill interpolates with the morph, which runs under the session
            // manager's `withAnimation(isRecording)`.
            .background(Circle().fill(recordButtonTint(recording: recording, blocked: blocked, prompting: prompting)))
            .scaleEffect(scale)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recordButtonLabel(recording: recording, blocked: blocked, prompting: prompting))
    }

    private func recordButtonTint(recording: Bool, blocked: Bool, prompting: Bool) -> Color {
        if prompting { return Self.recordTint }
        if recording { return .red }
        return blocked ? Self.lockedTint : Self.recordTint
    }

    private func recordButtonLabel(recording: Bool, blocked: Bool, prompting: Bool) -> String {
        if prompting { return "Resume — keep birding" }
        if blocked { return "Recording unavailable — permissions needed" }
        return recording ? "Stop recording" : "Start recording"
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
                Text("Kestrel needs microphone and location access to identify birds. Grant access for Kestrel in the watch\u{2019}s Settings app.")
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

    // MARK: - Save / resume / discard prompt

    /// Resume is offered only while the workout is merely *paused*, where
    /// resuming continues the same walk. Once the session is truly over — the
    /// system ended it, a watchdog gave up, an orphan was reclaimed — there's
    /// nothing to resume into and the button would be a lie, so it's dropped
    /// (along with the record control it's drawn by) and only Discard and Save
    /// remain, re-centered.
    private var showResumeButton: Bool {
        workout.pendingSave?.canResume == true
    }

    /// Caption sitting to the right of a prompt button, its leading edge fixed at
    /// `x` so all three captions share one left margin regardless of length.
    /// `.position` centers, hence the half-width shift.
    private func promptLabel(_ text: String, x: CGFloat, width: CGFloat, y: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white)
            // No text on the watch should wrap: a caption too wide for a small
            // screen scales down rather than stealing a second line.
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: width, alignment: .leading)
            .position(x: x + width / 2, y: y)
            .allowsHitTesting(false)
    }

    /// Discard or Save — the two answers that aren't the record control itself.
    /// Built on the record button's geometry (drawn at the full base size and
    /// uniformly scaled down into its slot) rather than as a fixed small circle,
    /// because the button the user taps is the one that grows back into the
    /// centered Start Birding button: same shape, same travel, tint and glyph
    /// crossing over on the way.
    private func promptButton(_ role: PromptRole, in size: CGSize) -> some View {
        let morphed = morphing == role
        let saving = role == .save
        // Visible while the prompt is settled, and afterwards only if this is the
        // button that was tapped — the other one clears away with the captions.
        let visible = promptVisible || morphed
        let side: CGFloat = morphed ? Self.buttonBaseSize : Self.cornerButtonSize
        return Button {
            answerPrompt(role)
        } label: {
            ZStack {
                // The trash/checkmark and the record button's play glyph are both
                // always present and cross-faded, as in `recordButton` — a single
                // swapped `Image` leaves the outgoing glyph half-visible at the end.
                // The checkmark is drawn a touch larger so it reads as the same
                // weight (its ink sits well inside its em box).
                Image(systemName: saving ? "checkmark" : "trash.fill")
                    .font(.system(
                        size: saving ? Self.checkGlyphBaseSize : Self.cornerGlyphBaseSize,
                        weight: .bold
                    ))
                    .opacity(morphed ? 0 : 1)
                Image(systemName: "play.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .opacity(morphed ? 1 : 0)
            }
            .foregroundStyle(.white)
            .frame(width: Self.buttonBaseSize, height: Self.buttonBaseSize)
            .background(Circle().fill(morphed
                ? Self.recordTint
                : (saving ? Self.saveTint : Self.discardTint)))
            .scaleEffect(side / Self.buttonBaseSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saving ? "Save workout" : "Discard workout")
        .position(
            x: morphed ? size.width / 2 : Self.cornerCenter(radius: Self.cornerButtonSize / 2),
            y: morphed ? size.height / 2 : promptSlotY(role, in: size.height)
        )
        // Only a morph is allowed to move these two. The prompt coming or going
        // is a pure cross-fade — they belong at their final slots the instant
        // they exist, not drifting into them under the fade. `.transaction`
        // applies to everything below it in the chain, so the position is pinned
        // while the opacity outside it still animates.
        .transaction { if morphing == nil { $0.animation = nil } }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }

    /// The invisible rectangle that actually takes a row's tap — the circle, its
    /// caption, and the space between them, from the button's leading edge out to
    /// the captions' trailing margin. Nothing here is ever drawn: it's
    /// `Color.clear` with a `contentShape`, so the row reads as a button and a
    /// label while behaving like one target. Stacked above the visible buttons,
    /// which keep their own (identical) actions so VoiceOver still has a labelled
    /// control to activate — hence `accessibilityHidden` here, to avoid offering
    /// the same answer twice.
    private func promptRowTarget(_ role: PromptRole, in size: CGSize) -> some View {
        let leading = Self.cornerCenter(radius: Self.cornerButtonSize / 2) - Self.cornerButtonSize / 2
        let width = max(0, size.width - Self.edgeMargin - leading)
        // Resume is only offered while the walk can still be resumed, and no row
        // takes a tap while an answer is already morphing away.
        let active = promptVisible && (role != .resume || showResumeButton)
        return Button {
            if role == .resume {
                session.resumeBirding()
            } else {
                answerPrompt(role)
            }
        } label: {
            Color.clear
                .frame(width: width, height: Self.promptSlotSpacing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
        .position(x: leading + width / 2, y: promptSlotY(role, in: size.height))
        // As with the buttons themselves: the rows belong at their final slots
        // the instant the prompt exists, never sliding into them.
        .transaction { if morphing == nil { $0.animation = nil } }
        .allowsHitTesting(active)
    }

    /// Answers the prompt. Animate first, act second: the tapped button grows
    /// back into the centered record button, and only once that has played does
    /// the HealthKit work run — finishing or discarding a workout builder is slow
    /// enough to visibly hitch an animation sharing its frame.
    private func answerPrompt(_ role: PromptRole) {
        guard morphing == nil else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            morphing = role
        }
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            // Hand off in a single unanimated turn: the prompt drops and the
            // record button reappears at dead center — exactly where the morphed
            // button just landed, same size, same tint, same glyph — so the swap
            // is invisible. Dismissing here rather than waiting on `save()` keeps
            // the prompt from flashing back up behind the finished animation.
            workout.dismissPrompt()
            morphing = nil
            switch role {
            case .save:    await workout.save()
            case .discard: await workout.discard()
            case .resume:  break  // Resume is the record control (`resumeBirding`)
            }
        }
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
    /// clearance is `edgeMargin`, so every corner button tracks the per-watch
    /// margin. (It used to be shared with the bird image's inset, which is why
    /// one knob covered both; the photo now runs flush to the left, right and
    /// bottom edges and is bounded by `imageTopCornerRadius` instead — see
    /// `WatchMetrics`.)
    private static var cornerConst: CGFloat {
        screenCornerRadius * (1 - 1 / sqrt2) + edgeMargin / sqrt2
    }

    // MARK: - Recording ("now hearing")

    /// The species name centered above the photo, which runs flush to the left,
    /// right and bottom edges of the screen. No `GeometryReader` — its first-time
    /// layout pass was the render stall; the image sizes itself with
    /// `aspectRatio` instead.
    private var nowHearing: some View {
        VStack(spacing: 0) {
            // A flexible spacer pushes the name + photo to the bottom; the name
            // sits `nameImageGap` above the photo, which itself has no bottom
            // margin — the bezel is its bottom edge.
            Spacer(minLength: 0)
            nameLabel
                .frame(maxWidth: .infinity)
                // The name is the only thing here that's inset. `edgeMargin` is
                // the corner buttons' clearance; the extra few points keep a long
                // name off the bezel curve.
                .padding(.horizontal, Self.edgeMargin + 6)
            Color.clear.frame(height: Self.nameImageGap)
            birdImage
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// The whole photo (never cropped) filling the full screen width, its height
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
        // Only the top corners are rounded. The photo sits in the screen's own
        // bottom corners, so its bottom edge is clipped by the bezel rather than
        // by us — a radius here would just cut a second, smaller curve inside the
        // hardware's. `imageTopCornerRadius` matches the bezel radius so all four
        // corners read the same.
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: Self.imageTopCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Self.imageTopCornerRadius,
                style: .continuous
            )
        )
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
                // Purple for a lifer, blue for a starred bird, white for an
                // ordinary one — the replacement for the old full-screen tint.
                // Cross-fades with the name itself under the body's
                // `value: session.lastBird` animation.
                Text(bird.commonName)
                    .foregroundStyle(nameColor)
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
