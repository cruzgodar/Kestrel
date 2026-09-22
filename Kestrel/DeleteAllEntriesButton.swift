import SwiftUI

/// "Delete All Entries" — the one control that wipes the whole life list,
/// behind a confirmation that says exactly how much is about to go.
///
/// It lives at the bottom of the Settings tab rather than at the bottom of the
/// Life List, where it used to sit. A destructive control belongs where you go
/// looking for it, not at the end of a list you scroll through every day, and
/// the Life List's grid layout on a foldable's inner display left it floating
/// under the last row of photographs with nothing to anchor it.
///
/// The button draws itself nowhere there is nothing to delete: an empty life
/// list has no "all" to remove, and offering the action anyway invites a
/// confirmation that would read "all 0 observations of 0 species".
struct DeleteAllEntriesButton: View {
    @Environment(LifeListStore.self) private var store

    @State private var showConfirmation = false

    var body: some View {
        if !store.entries.isEmpty {
            button
                .alert(
                    "Delete your entire life list?",
                    isPresented: $showConfirmation
                ) {
                    Button("Delete All", role: .destructive) {
                        store.removeAll()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text(message)
                }
        }
    }

    /// Styled to match the record button but without the press scale/opacity
    /// feedback — this is a deliberate, confirmed-destructive action, not a
    /// tactile control.
    private var button: some View {
        Button {
            showConfirmation = true
        } label: {
            Text("Delete All Entries")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(height: 26)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .frame(minHeight: 50)
                .background { Capsule(style: .continuous).fill(Color.red) }
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(NoDimButtonStyle())
    }

    /// The wording behind "Delete All Entries". The observation count is
    /// pluralized — "all 1 observations" reads as a bug in the middle of a
    /// confirmation the user is being asked to trust. ("Species" is its own
    /// plural, so the second count needs nothing.)
    private var message: String {
        let observations = store.totalObservationCount
        let noun = observations == 1 ? "observation" : "observations"
        return "Are you sure you want to permanently remove all "
            + "\(observations) \(noun) of \(store.entries.count) species from your "
            + "life list? This cannot be undone. Your stars will be preserved if "
            + "you re-add the species later."
    }
}
