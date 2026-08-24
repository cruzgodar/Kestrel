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
struct AddGlyphButton: View {
    /// True once the species is on the life list — swaps the plus for a
    /// checkmark and retires the button's tap.
    let isAdded: Bool
    /// Diameter of the glass circle. Row-sized by default; the glyph scales with
    /// it so a larger button stays proportioned.
    var size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isAdded ? "checkmark" : "plus")
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace, options: .speed(2.6)))
                .frame(width: size, height: size)
                .glassEffect(
                    .regular.tint(Color.accentColor).interactive(),
                    in: .circle
                )
                .contentShape(.circle)
        }
        .buttonStyle(NoDimButtonStyle())
        // Not `.disabled`, which would gray the glyph out — the checkmark should
        // read as an unambiguous "this one's filed", at full strength. This just
        // takes the touch away, which also stops the interactive glass lighting
        // up under a finger and promising something the tap won't do.
        .allowsHitTesting(!isAdded)
    }
}
