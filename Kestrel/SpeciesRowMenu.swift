import SwiftUI

/// The haptic-touch menu a species row raises, shared by every list that has
/// one — Identify detections, life-list entries, search suggestions, map
/// thumbnails, and the full-screen viewer — so they can never drift apart in
/// wording, symbol, or order.
///
/// Which actions a row offers is decided by what it can act on, not by which
/// tab it lives in:
///
/// - **Edit Observation** needs a recorded sighting to rewrite, so it's on the
///   rows that stand for one (life list, map) and off the ones that don't (a
///   live detection, a catalog suggestion). `onEdit` is `nil` there.
/// - **Add Observation** is on every row. Even a bird already on the life list
///   deserves today's sighting recorded, and a search suggestion is added by
///   filing its first one.
/// - **Star / Unstar Species** needs a bird to alert on, which a row backed by
///   nothing but a catalog entry doesn't have yet — `star` is `nil` there.
/// - **View Image** is on every row but the full-screen viewer's own, where the
///   image is already what you're looking at. `onViewImage` is `nil` there.
/// - **Delete Observation** removes one recorded sighting — never the species'
///   whole history, which only "Delete All Entries" does. It belongs where the
///   row stands for a sighting; `onDelete: nil` leaves it off.
struct SpeciesRowMenu: View {
    /// Re-opens the date → map → name flow on an existing sighting. `nil` on
    /// rows with no sighting to edit.
    var onEdit: (() -> Void)?
    /// Opens the date → map → name flow. Nothing is written until it's
    /// confirmed, which is why the destructive-looking full swipe is safe.
    let onAddObservation: () -> Void
    /// Current star state and the toggle for it. `nil` on rows with nothing to
    /// star.
    var star: (isStarred: Bool, toggle: () -> Void)?
    /// `nil` when the image is already on screen.
    var onViewImage: (() -> Void)?
    /// `nil` on rows where deleting doesn't apply.
    var onDelete: (() -> Void)?

    var body: some View {
        if let onEdit {
            Button {
                onEdit()
            } label: {
                Label("Edit Observation", systemImage: "pencil")
            }
        }
        Button {
            onAddObservation()
        } label: {
            Label("Add Observation", systemImage: "plus")
        }
        if let star {
            Button {
                star.toggle()
            } label: {
                // Mirrors the life-list row's own star button, which is a toggle.
                Label(
                    star.isStarred ? "Unstar Species" : "Star Species",
                    systemImage: star.isStarred ? "star.slash" : "star"
                )
            }
        }
        if let onViewImage {
            Button {
                onViewImage()
            } label: {
                Label("View Image", systemImage: "photo")
            }
        }
        if let onDelete {
            // Routed through the caller's confirmation alert rather than
            // deleting outright.
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Observation", systemImage: "trash")
            }
        }
    }
}
