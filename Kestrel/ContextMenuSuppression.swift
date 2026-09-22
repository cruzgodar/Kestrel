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
    /// the point is only that the ancestor's menu does not. The duration sits
    /// under the system's own menu delay so it wins the race, and a tap is far
    /// shorter than either, so the button's own action is untouched.
    func swallowsLongPress() -> some View {
        highPriorityGesture(LongPressGesture(minimumDuration: 0.2).onEnded { _ in })
    }
}
