import SwiftUI

extension View {
    /// Stops a long press on this control from reaching a context menu further
    /// up the view tree.
    ///
    /// A row (or a grid tile) carries its actions on a haptic touch anywhere in
    /// it, which is right for the row and wrong for the small buttons riding on
    /// it: resting a finger on the star to see what it does made the whole row
    /// lift and the menu open, so the one control with an unambiguous meaning
    /// was the one place the menu could be triggered by accident.
    ///
    /// A long press of its own, attached with higher priority than anything
    /// above it, is what claims the gesture. It does nothing when it fires —
    /// the point is only that the ancestor's menu does not. A tap is far
    /// shorter than the threshold, so the button's own action is untouched.
    ///
    /// **This is a last resort, and it shows.** The interaction it is
    /// cancelling has already begun by the time the press is claimed, so the
    /// control swells under the finger and snaps back. Everywhere the control
    /// can simply be placed *outside* the menu's subtree instead, it is — see
    /// the Life List's grid tiles. This is for the places it cannot: a `List`
    /// hoists a row's context menu to the whole cell, so no arrangement of
    /// views inside the row escapes it.
    ///
    /// Three things that do not work, tried in this order: an empty
    /// `contextMenu` on the control (a nested empty menu does not disable the
    /// ancestor's); drawing the control in an `overlay` applied *after* the
    /// menu (SwiftUI draws both into one host view, and the interaction is
    /// geometric); and punching the control's square out of the row's
    /// `contentShape` with an even-odd fill (the menu does not consult it).
    func swallowsLongPress() -> some View {
        highPriorityGesture(LongPressGesture(minimumDuration: 0.2).onEnded { _ in })
    }
}
