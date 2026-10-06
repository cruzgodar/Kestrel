import SwiftUI

/// The purple add affordance used on every row that can put a bird on the life
/// list — the Identify tab's detections and the Life List tab's catalog
/// suggestions.
///
/// Deliberately built to match the tinted Liquid Glass confirm button the add
/// flow's sheets carry in their top-right corner (`Button(role: .confirm)`), so
/// the control that *starts* the flow and the one that advances it read as the
/// same object. That button is a system toolbar role and can't be used outside a
/// toolbar, so its look is reproduced here: accent-tinted interactive glass in a
/// circle, white bold glyph.
///
/// Flips to a checkmark once the species is on the list, with the same
/// symbol-replace transition everywhere. The checkmark is a statement of state,
/// not a second control: it stops taking taps, so the button can never be the
/// thing that removes a sighting. Deleting one is the row menu's and the swipe
/// actions' job, where the sighting is named and the delete is confirmed.
///
/// With `hereAndNow` set, a tap first asks — in the system's own pop-out,
/// anchored to the button — whether the bird was seen here and now. Yes runs
/// `hereAndNow`, which can file the sighting without opening anything; no
/// runs `action`, the full when → where → name flow.
struct AddGlyphButton: View {
    /// True once the species is on the life list — swaps the plus for a
    /// checkmark and retires the button's tap.
    let isAdded: Bool
    /// Diameter of the glass circle. Row-sized by default; the glyph scales with
    /// it so a larger button stays proportioned.
    var size: CGFloat = 32
    /// The "yes" answer to "did you see this bird here and now?". `nil` skips
    /// the question and goes straight to `action`.
    var hereAndNow: (() async -> Void)? = nil
    let action: () -> Void

    @State private var isAsking = false
    /// True while `hereAndNow` runs. Finding where the device is can take a
    /// few seconds, and a button that did nothing for that long would read as
    /// a tap that missed.
    @State private var isFiling = false

    var body: some View {
        Button {
            if hereAndNow == nil { action() } else { isAsking = true }
        } label: {
            ZStack {
                if isFiling {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: isAdded ? "checkmark" : "plus")
                        .font(.system(size: size * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace, options: .speed(2.6)))
                }
            }
            .frame(width: size, height: size)
            .glassEffect(
                .regular.tint(Color.accentColor).interactive(),
                in: .circle
            )
            .contentShape(.circle)
        }
        .buttonStyle(NoDimButtonStyle())
        // The button is its own target, not part of whatever it is sitting on:
        // a row's haptic-touch menu should not open because a finger rested on
        // the plus. See `swallowsLongPress`.
        .swallowsLongPress()
        // Not `.disabled`, which would gray the glyph out — the checkmark should
        // read as an unambiguous "this one's filed", at full strength. This just
        // takes the touch away, which also stops the interactive glass lighting
        // up under a finger and promising something the tap won't do.
        .allowsHitTesting(!isAdded && !isFiling)
        .confirmationDialog(
            "Did you see this bird here and now?",
            isPresented: $isAsking,
            titleVisibility: .visible
        ) {
            Button("Yes") {
                guard let hereAndNow else { return }
                isFiling = true
                Task {
                    await hereAndNow()
                    isFiling = false
                }
            }
            Button("No") { action() }
            Button("Cancel", role: .cancel) { }
        }
    }
}
