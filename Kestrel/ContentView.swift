import Combine
import CoreLocation
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(RecordingManager.self) private var manager
    @Environment(LifeListStore.self) private var lifeListStore
    /// Drives the full-screen viewer for the row menu's View Image. Detection
    /// rows open it on the one bird, matching what tapping their hero image
    /// already does.
    @Environment(SpeciesPhotoPresenter.self) private var photoPresenter: SpeciesPhotoPresenter?

    /// Measured width of the record-button row, used to compute how far the
    /// stop button must slide left from center to reach the leading edge.
    @State private var bottomBarWidth: CGFloat = 0

    /// Clock re-sampled on a timer so detection rows visibly migrate below the
    /// "Over a minute ago" header as they age past one minute, even when no
    /// new detection arrives to re-sort the list.
    @State private var now = Date()
    private let ageTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    /// A detection older than this (since last heard) drops below the header.
    private static let agingThreshold: TimeInterval = 60

    /// The species partway through the add flow (pick a date, then a location).
    /// Identical wiring to the Life List tab's — see `observationFlow`.
    @State private var pendingObservation: ObservationDraft?

    /// Height of the trailing thumbnail on detection rows. Width follows at 4:3.
    private static let rowThumbnailHeight: CGFloat = 72

    /// Height of the spectrogram strip pinned above the results while recording.
    private static let spectrogramHeight: CGFloat = 80
    /// Height of the blank, non-swipeable spacer row that sits above every
    /// detection row (see `topSpacerRow`). Adjust to change how far the first
    /// real row sits from the top of the list.
    private static let topSpacerRowHeight: CGFloat = 24

    /// Diameter of the circular stop button.
    private static let stopButtonDiameter: CGFloat = 56
    /// How far the stop button is nudged right from the leading edge.
    private static let stopButtonRightInset: CGFloat = 4

    /// Horizontal offset that carries the centered stop button to the leading
    /// edge (plus `stopButtonRightInset`). Negative = leftward.
    private var stopButtonOffsetX: CGFloat {
        Self.stopButtonRightInset + Self.stopButtonDiameter / 2 - bottomBarWidth / 2
    }

    /// Top inset for the results list.
    ///
    /// Reserved only when the spectrogram is up *and* there are real rows to
    /// scroll — the empty filler renders through the overlay and shouldn't get
    /// shoved down.
    ///
    /// Short by `topSpacerRowHeight`, deliberately: the list leads with a blank
    /// spacer row (see `topSpacerRow`), and pulling the list up by exactly that
    /// much parks the spacer *behind* the spectrogram, which is opaque and drawn
    /// over it. The first detection row then sits flush against the strip's
    /// bottom edge while the spacer still does its job. Clamped so an oversized
    /// spacer can't push the list up past the strip and out from under it.
    private var listTopPadding: CGFloat {
        guard manager.isRecording, !manager.detections.isEmpty else { return 0 }
        return max(0, Self.spectrogramHeight - Self.topSpacerRowHeight)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Results fill the entire screen and scroll under both the floating
            // record button and the tab bar; `contentMargins` (see resultsView)
            // keeps the final rows reachable above the button.
            resultsView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, listTopPadding)
                .animation(.easeOut(duration: 0.15), value: manager.isRecording)
                .animation(.easeOut(duration: 0.15), value: manager.detections.isEmpty)

            if manager.isRecording {
                SpectrogramView(renderer: manager.spectrogram)
                    .frame(height: Self.spectrogramHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    // Small Apple Watch glyph in the top-left while the watch
                    // is the audio source — replaces the old text caption.
                    .overlay(alignment: .topLeading) {
                        if manager.watchRecording {
                            Image(systemName: "applewatch")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(.black.opacity(0.35), in: Circle())
                                .padding(8)
                                .transition(.opacity)
                                .accessibilityLabel("Listening on Apple Watch")
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: manager.watchRecording)
                    .transition(.opacity.animation(.smooth(duration: 0.16)))
            }
        }
        .overlay {
            if manager.detections.isEmpty {
                ContentUnavailableView {
                    Label("Identify Birds", systemImage: "magnifyingglass")
                } description: {
                    // The watch-installed state isn't known at launch, so the
                    // copy starts on the non-watch string and resolves a beat
                    // later. Both strings are stacked and crossfaded by opacity
                    // *in place* rather than swapped via `.id` + an insert/remove
                    // transition: an identity swap put two differently-sized
                    // descriptions in the same vertically-centering slot at once,
                    // and the reflow mid-transition rode the text up over the
                    // magnifying-glass icon. A ZStack sizes to the taller string
                    // and holds that slot steady, so the crossfade never reflows.
                    //
                    // Top-aligned, not centered: the watch copy wraps to one more
                    // line than the other, so centering the two in the same slot
                    // put every shared line half a line-height apart between them.
                    // The crossfade then read as the text sliding up into place
                    // instead of dissolving. Sharing a top edge pins the lines both
                    // strings have in common, so only the wording changes and the
                    // extra line fades in below.
                    ZStack(alignment: .top) {
                        HighlightedText(
                            segments: Self.placeholderSegments(watchInstalled: false),
                            textColor: .secondary,
                            alignment: .center
                        )
                        .opacity(manager.isWatchAppInstalled ? 0 : 1)
                        HighlightedText(
                            segments: Self.placeholderSegments(watchInstalled: true),
                            textColor: .secondary,
                            alignment: .center
                        )
                        .opacity(manager.isWatchAppInstalled ? 1 : 0)
                    }
                    .animation(.easeInOut(duration: 0.3), value: manager.isWatchAppInstalled)
                    // Widen the description out of ContentUnavailableView's
                    // narrower default reading column so its text sits at the
                    // same 16pt screen margin as the life-list rows.
                    .containerRelativeFrame(.horizontal) { width, _ in width - 32 }
                }
                .opacity(manager.isRecording ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: manager.isRecording)
                .allowsHitTesting(false)
            }
        }
        // Floating record button + error caption pinned to the bottom, over
        // the scrolling list. The button slides from centered (start) to the
        // leading edge (stop) via a GPU-composited `.offset` rather than an
        // animated layout (Spacer), so the move stays at full frame rate.
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if let message = manager.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                recordButton
                    // Base position: centered in the row. Only the button label
                    // (56pt square / wide pill) is hit-testable; the empty
                    // frame around it passes taps through to the list.
                    .frame(maxWidth: .infinity, alignment: .center)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { bottomBarWidth = $0 }
                    .offset(x: manager.isRecording ? stopButtonOffsetX : 0)
                    .animation(.easeOut(duration: 0.16), value: manager.isRecording)
            }
            .padding(.horizontal, 16)
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
        // No star mirroring here any more: `RecordingManager.starredNames` reads
        // the store itself. This tab pushing it in only worked while starring was
        // something you did on this tab, and it hasn't been for a while — the map
        // pin menu, the full-screen viewer and the life-list row menu all toggle
        // stars with Identify deselected.
        //
        // Re-sample the clock so rows slide below the "Over a minute ago"
        // header as they age, animating the migration.
        .onReceive(ageTimer) { date in
            withAnimation(.easeInOut(duration: 0.3)) { now = date }
        }
        // The add flow's date sheet → map picker → naming sheet, shared verbatim
        // with the Life List tab.
        .observationFlow($pendingObservation, store: lifeListStore)
        // Recording needs location access for the nearby-species filter; when a
        // start is refused for lack of it, offer a jump to Settings.
        .alert(
            "Location Access Needed",
            isPresented: Binding(
                get: { manager.showLocationPermissionAlert },
                set: { manager.showLocationPermissionAlert = $0 }
            )
        ) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("Kestrel cannot identify birds without location access, because it needs to filter birds to only those found near you. You can turn on location access for Kestrel in Settings.")
        }
        // Recording needs microphone access; when a start is refused for lack of
        // it, offer a jump to Settings (mirroring the location alert above).
        .alert(
            "Microphone Access Needed",
            isPresented: Binding(
                get: { manager.showMicPermissionAlert },
                set: { manager.showMicPermissionAlert = $0 }
            )
        ) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("Kestrel cannot identify birds without microphone access, because it listens for their songs and calls. You can turn on microphone access for Kestrel in Settings.")
        }
        // Stopping a watch-started session ends a birding walk the watch has been
        // recording as a workout. Ask here — the user is looking at the phone —
        // rather than leaving the question waiting on a wrist they've put down.
        // The answer rides along with the stop (see `resolveWatchWorkout`), so
        // the watch acts on it instead of prompting again. Cancel carries the
        // `.cancel` role so the alert doesn't synthesize a *second* cancel button
        // beneath ours — it only adds one when no action claims that role. The
        // order matches the watch's own prompt: cancel, discard, save.
        .alert(
            "Save This Birding Walk?",
            isPresented: Binding(
                get: { manager.showWatchWorkoutPrompt },
                set: { manager.showWatchWorkoutPrompt = $0 }
            )
        ) {
            Button("Cancel", role: .cancel) { manager.showWatchWorkoutPrompt = false }
            Button("Discard", role: .destructive) { manager.resolveWatchWorkout(.discard) }
            Button("Save Workout") { manager.resolveWatchWorkout(.save) }
        } message: {
            Text("Your Apple Watch has been recording this session as a walk. Saving logs it to Fitness and counts toward your rings.")
        }
    }

    // The single button morphs from a wide "Start Recording" pill to a 56pt
    // circular stop button (and back). It's a plain solid-fill capsule (not
    // Liquid Glass): morphing the glass shape re-sampled its backdrop blur every
    // frame and dropped the animation to ~30fps, whereas a solid capsule morphs
    // at full frame rate. The morph geometry itself is unchanged.
    private var recordButton: some View {
        Button {
            Task { await manager.toggle() }
        } label: {
            // One stable HStack so the capsule cleanly *morphs* rather than
            // crossfading: the icon swaps in place via a symbol replace, the
            // label drops out, and the frame animates from a wide pill to a 56pt
            // square — which a `Capsule` renders as a perfect circle.
            HStack(spacing: 0) {
                // Idle: a mic, or a lock when mic/location access is denied (the
                // button is grayed then and a tap opens the Settings alert rather
                // than recording). Recording: the stop glyph.
                Image(systemName: manager.isRecording
                    ? "stop.fill"
                    : (manager.recordingBlocked ? "lock.fill" : "mic.fill"))
                    .contentTransition(.symbolEffect(.replace, options: .speed(2.6)))
                if !manager.isRecording {
                    Text("Start Birding")
                        .padding(.leading, 8)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .font(.title3.weight(.semibold))
            .frame(
                width: manager.isRecording ? Self.stopButtonDiameter : nil,
                height: manager.isRecording ? Self.stopButtonDiameter : 58
            )
            .padding(.horizontal, manager.isRecording ? 0 : 28)
        }
        // Purple while idle, red once recording (matching the Delete All Entries
        // button), gray while location access is denied. The color interpolates
        // with the morph because the animation below scopes `isRecording`.
        .buttonStyle(RecordButtonStyle(tint: recordButtonTint))
        .animation(.easeOut(duration: 0.16), value: manager.isRecording)
        .animation(.easeInOut(duration: 0.2), value: manager.recordingBlocked)
    }

    /// Fill color for the record button: red while recording, gray when mic or
    /// location access is denied (a locked, tap-to-open-Settings state), else the
    /// idle purple.
    private var recordButtonTint: Color {
        if manager.isRecording { return Self.stopTint }
        return manager.recordingBlocked ? Self.lockedTint : Self.recordTint
    }

    private static let recordTint = Color.kestrelPurple
    /// Red for the stop state, matching the life-list Delete All Entries button.
    private static let stopTint = Color.red
    /// Gray for the locked (location-denied) idle state.
    private static let lockedTint = Color(white: 0.45)
    /// Flash for an ordinary bird — one already on the life list and not
    /// starred, whose row carries no standing tint for the flash to echo.
    private static let ordinaryFlash = Color(hue: 50.0 / 360.0, saturation: 0.6, brightness: 1.0)
    /// Highlight purple — soft tint blended into the row background of a bird
    /// not yet on the life list. The same value the empty-state copy pills that
    /// phrase with, so the sentence and the rows it describes can't drift apart;
    /// defined once over there rather than restated here.
    private static let recordHighlight = HighlightedText.addHighlight

    @ViewBuilder
    private var resultsView: some View {
        if !manager.detections.isEmpty {
            // `manager.detections` is already sorted by `lastSeen` descending, so
            // each partition keeps that order; we just split it at the one-minute
            // mark and slip a header between the two groups.
            let recent = manager.detections.filter {
                now.timeIntervalSince($0.lastSeen) <= Self.agingThreshold
            }
            let aged = manager.detections.filter {
                now.timeIntervalSince($0.lastSeen) > Self.agingThreshold
            }
            // The store's own membership set, so each row's "already added?"
            // check is O(1) instead of a linear scan of the whole life list per
            // row (which, across many rows × a large list × every merge-driven
            // re-render, added up). Read rather than rebuilt: `speciesNames` is
            // maintained for exactly this, and building a fresh set of a few
            // thousand strings on every render was paying the cost it exists to
            // avoid.
            let lifeListNames = lifeListStore.speciesNames
            List {
                topSpacerRow
                ForEach(recent) { detection in
                    detectionRow(for: detection, lifeListNames: lifeListNames)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                if !aged.isEmpty {
                    Text("Over a minute ago")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 2)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    ForEach(aged) { detection in
                        detectionRow(for: detection, lifeListNames: lifeListNames)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            // `topSpacerRow` is only as tall as `topSpacerRowHeight` says. Left
            // at SwiftUI's default minimum row height (44pt) it would hold a
            // wide blank band open even at height 0. Every detection row is far
            // taller than any minimum, so dropping the floor to 0 changes
            // nothing else in this list.
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            // Inset the scrollable content so the last rows can be scrolled
            // clear of the floating record button while still scrolling
            // *under* it (and the tab bar) for the translucent glass look.
            .contentMargins(.bottom, 84, for: .scrollContent)
        } else {
            // Filler is rendered via the body's .overlay so its position
            // isn't affected when the spectrogram appears above it.
            Color.clear
        }
    }

    /// Blank first row, `topSpacerRowHeight` tall. A row rather than padding on
    /// the list, so the separation is part of the scrolling content and travels
    /// with it. Carries no `swipeActions` and no hit testing, so it can't be
    /// swiped, tapped, or selected — it exists only to hold space.
    private var topSpacerRow: some View {
        Color.clear
            .frame(height: Self.topSpacerRowHeight)
            .allowsHitTesting(false)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    // Faint blue persistent tint for starred species (alert-me list) — the
    // starred half of the pair above, from the same single definition.
    private static let starredTint = HighlightedText.starHighlight

    /// The Identify empty-state description with "starred birds" on a blue pill
    /// and "those not on your life list" on a purple pill, matching the row
    /// backgrounds those two kinds of detection get.
    private static func placeholderSegments(watchInstalled: Bool) -> [HighlightedText.Segment] {
        let lead = watchInstalled
            ? "Start a birding session here or on Apple Watch to listen for birds in the background. You will be notified about "
            : "Start a birding session to listen for birds in the background. You will be notified about "
        return [
            .init(lead),
            .init("starred birds", highlight: HighlightedText.starHighlight),
            .init(" and "),
            .init("those not on your life list.", highlight: HighlightedText.addHighlight),
        ]
    }

    /// The row's persistent tint plus its flash, as one stack: purple for a
    /// bird not yet on the life list, blue for a starred one, and the flash
    /// pulse over whichever of those applies.
    @ViewBuilder
    private func rowTint(
        needsLifeListAdd: Bool,
        isStarred: Bool,
        flashing: Bool,
        flashColor: Color
    ) -> some View {
        ZStack {
            Self.recordHighlight
                .opacity(needsLifeListAdd ? 0.35 : 0)
            Self.starredTint
                .opacity(!needsLifeListAdd && isStarred ? 0.35 : 0)
            flashColor
                .opacity(flashing ? 0.25 : 0)
                .animation(
                    flashing ? nil : .easeOut(duration: 0.5),
                    value: flashing
                )
        }
    }

    private func detectionRow(for detection: Detection, lifeListNames: Set<String>) -> some View {
        let flashing = manager.flashIDs.contains(detection.id)
        // "Not in life list at session start" — frozen for the duration of
        // the recording, so the tint doesn't vanish the instant the user
        // taps the plus to add.
        let needsLifeListAdd = !manager.lifeListSnapshot.contains(detection.scientificName)
        // Once the user taps the plus, the species is in the live store
        // even though the session snapshot still says it wasn't. That flip
        // is how we know to swap plus → checkmark. O(1) against the set built
        // once per render in `resultsView`.
        let alreadyAdded = lifeListNames.contains(detection.scientificName)
        // `starredNames` is the store's source-of-truth Set, so this is an O(1)
        // lookup (and tracks the right @Observable dependency for star toggles).
        let isStarred = lifeListStore.starredNames.contains(detection.scientificName)
        // Flash color is literally the persistent tint, pulsed brighter — so it
        // reads as the same row lighting up rather than as a second color
        // arriving over it. Yellow is the one that has no standing tint behind
        // it: an ordinary known bird's row is plain, and the flash is all there
        // is to see.
        let flashColor: Color = needsLifeListAdd
            ? Self.recordHighlight
            : (isStarred ? Self.starredTint : Self.ordinaryFlash)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(detection.commonName)
                    .font(.headline)
                Spacer()
                if needsLifeListAdd {
                    // Once the bird is on the list the checkmark is a *status*,
                    // not a control: it reports that this session's detection has
                    // been filed and stops responding to taps (see
                    // `AddGlyphButton`). It used to undo the add, but "undo" had
                    // no way to know which sighting it meant — it removed the
                    // species' newest one, which after a backdated add is a
                    // different record than the one just written — and it did so
                    // on one unconfirmed tap, while every other delete in the app
                    // goes through a confirmation. Deleting a sighting belongs to
                    // the row's menu and swipe actions, which name what they act
                    // on and ask first.
                    AddGlyphButton(isAdded: alreadyAdded) {
                        // Runs the same when → where → what's-it-called flow the
                        // Life List tab uses. A live detection could be logged
                        // here and now from the device's own fix, but that made
                        // this the one add path that produced sightings with no
                        // place name; going through the flow keeps every manual
                        // add naming its location.
                        beginAdd(
                            scientificName: detection.scientificName,
                            commonName: detection.commonName
                        )
                    }
                    .accessibilityLabel(
                        alreadyAdded
                            ? "\(detection.commonName) is on your Life List"
                            : "Add \(detection.commonName) to Life List"
                    )
                } else {
                    // Already in life list — show the thumbnail at the row's
                    // trailing edge, same place the add button would occupy.
                    SpeciesThumbnail(
                        scientificName: detection.scientificName,
                        height: Self.rowThumbnailHeight
                    )
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
        //
        // No overhang past the leading edge. An earlier version extended the
        // tint 600pt to the left so a leading swipe never exposed the window
        // background in the strip the content view vacated — but the content
        // view draws *over* the swipe buttons, and that strip is exactly where
        // Add Observation is revealed, so the tint washed the button's purple
        // out to a blend of button and row. A matching `.listRowBackground`
        // was tried as a way to keep the strip tinted *under* the button and
        // does not paint there either, so the strip is simply the button's own
        // color now.
        .background(
            rowTint(
                needsLifeListAdd: needsLifeListAdd,
                isStarred: isStarred,
                flashing: flashing,
                flashColor: flashColor
            )
        )
        // Every row, not just the ones showing a plus: a bird already on the
        // life list still deserves today's sighting recorded. Matches the Life
        // List tab's leading swipe, full swipe included — running the whole
        // gesture only opens the flow, which backing out of undoes.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                beginAdd(
                    scientificName: detection.scientificName,
                    commonName: detection.commonName
                )
            } label: {
                Label("Add Observation", systemImage: "plus")
            }
            .tint(Self.recordTint)
        }
        // The same haptic-touch menu the Life List rows carry, minus Delete —
        // a detection isn't a life-list entry, and the bird being heard right
        // now is the last thing to offer to remove.
        //
        // Star only appears once the bird is actually on the life list
        // (`alreadyAdded`, the live store membership rather than the frozen
        // session snapshot): starring is "alert me about this bird again",
        // which belongs to a bird you've recorded, not to every stranger the
        // classifier turns up. Add it first and the item appears.
        .contextMenu {
            SpeciesRowMenu(
                onAddObservation: {
                    beginAdd(
                        scientificName: detection.scientificName,
                        commonName: detection.commonName
                    )
                },
                star: alreadyAdded ? (isStarred, {
                    // The same single short tap the life-list star gives.
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    lifeListStore.setStarred(
                        scientificName: detection.scientificName,
                        isStarred: !isStarred
                    )
                }) : nil,
                onViewImage: { photoPresenter?.present(detection.scientificName) }
            )
        }
    }

    // MARK: - Add flow

    /// Opens the shared date → map → name flow for a detected species. Nothing
    /// is written until the naming step is confirmed.
    private func beginAdd(scientificName: String, commonName: String) {
        pendingObservation = .adding(scientificName: scientificName, commonName: commonName)
    }
}

/// Full-width image for an unseen species. Pinned to a 16:9 aspect box and
/// cropped (`.scaledToFill`) so rows look uniform even though the source
/// photos have varying aspect ratios.
private struct SpeciesHeroImage: View {
    let scientificName: String

    var body: some View {
        // No attribution caption inline — it's shown in the full-screen viewer
        // instead (tap the image). Keeps the Identify rows uncluttered. Loads the
        // 320px thumbnail first, then upgrades to the 900px medium, so the hero
        // for a just-heard bird appears immediately.
        SpeciesPhoto(scientificName: scientificName, showsCredit: false, progressive: true) {
            Image(systemName: "bird")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(.fill.tertiary)
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

/// Custom record button style: a solid, purple-tinted capsule for both the
/// "Start Recording" pill and the circular stop button (the label's frame is
/// what morphs one shape into the other). A plain fill rather than Liquid Glass
/// so the morph animates at full frame rate. On press the button briefly grows
/// + dims, both with the same fast easeOut so they feel like one motion.
struct RecordButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(tint, in: .capsule)
            // Pin the tappable region to the capsule so the button reliably
            // consumes taps over a list image scrolling beneath it (otherwise
            // the tap can fall through to the image's open-full-screen gesture).
            .contentShape(.capsule)
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
