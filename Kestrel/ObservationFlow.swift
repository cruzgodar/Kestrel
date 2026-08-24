import CoreLocation
import MapKit
import SwiftUI

extension Color {
    /// Green used by the Edit swipe action on a life-list row and in the
    /// full-screen viewer's observation list. Deliberately the star blue's
    /// saturation and brightness at a different hue, so the two swipe colors
    /// read as siblings rather than as two unrelated tints. The hue sits at the
    /// darker-reading end of green for that reason — green is the lightest hue
    /// family there is, so at the blue's brightness it can only go so deep.
    static let kestrelEditGreen = Color(hue: 140.0 / 360.0, saturation: 0.7, brightness: 0.62)
}

/// A sighting on its way into the life list, carried through the flow's three
/// steps — when, where, what the place is called — and written only when the
/// last one is confirmed. Abandoning any step leaves the list untouched.
///
/// The same draft covers both directions the flow runs in. `editing` is `nil`
/// when a *new* sighting is being filed, and carries the identity of an existing
/// one when the flow was entered from an Edit action — in which case every step
/// opens on that sighting's current value (`date`, `coordinate`, `placeName`)
/// and confirming rewrites it in place rather than adding a second record.
struct ObservationDraft: Identifiable {
    let id = UUID()
    let scientificName: String
    let commonName: String
    var date: Date
    /// The observation being rewritten, or `nil` when filing a new one.
    var editing: LifeListEntry.Observation.Identity?
    /// Where the map picker opens with its pin already down. `nil` falls back to
    /// the current location, which is what a new sighting wants.
    var coordinate: CLLocationCoordinate2D?
    /// What the naming step's field starts out holding. `nil` lets that step
    /// work out its own suggestion (a nearby place you've already named, else
    /// the town).
    var placeName: String?

    /// A new sighting of `scientificName`, opening on today with no location
    /// chosen yet.
    static func adding(scientificName: String, commonName: String) -> ObservationDraft {
        ObservationDraft(
            scientificName: scientificName,
            commonName: commonName,
            date: Date()
        )
    }

    /// An edit of `observation`, opening on everything it currently holds.
    static func editing(
        scientificName: String,
        commonName: String,
        observation: LifeListEntry.Observation
    ) -> ObservationDraft {
        var coordinate: CLLocationCoordinate2D?
        if let latitude = observation.latitude, let longitude = observation.longitude {
            coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        return ObservationDraft(
            scientificName: scientificName,
            commonName: commonName,
            date: observation.date,
            editing: observation.identity,
            coordinate: coordinate,
            placeName: observation.location
        )
    }
}

extension View {
    /// Hosts the date → map → name flow for whatever `draft` currently holds.
    /// Attach it wherever a sighting can be added or edited from; setting
    /// `draft` starts the flow and it clears itself when the flow ends,
    /// whichever way it ended.
    /// `onCommit` fires only when a sighting was actually written, so a caller
    /// that raised the flow from a chooser can put that chooser away — while
    /// cancelling out of the flow leaves it standing.
    func observationFlow(
        _ draft: Binding<ObservationDraft?>,
        store: LifeListStore,
        onCommit: (() -> Void)? = nil
    ) -> some View {
        modifier(ObservationFlowModifier(draft: draft, store: store, onCommit: onCommit))
    }
}

/// The flow's presentations, as a single modifier. Only *one* presentation hangs
/// off the host: the date sheet. The map picker is presented from inside that
/// sheet (see `ObservationDateSheet`), so it slides up over a sheet that stays
/// put — the checkmark shows the map immediately instead of waiting out a sheet
/// dismissal, and Back reveals the date sheet already sitting there rather than
/// re-animating it in.
private struct ObservationFlowModifier: ViewModifier {
    @Binding var draft: ObservationDraft?
    /// Threaded rather than taken from the environment: `@Observable`
    /// environment objects don't cross a presentation boundary, and every step
    /// of the flow lives inside one.
    let store: LifeListStore
    let onCommit: (() -> Void)?

    func body(content: Content) -> some View {
        // `item`, not `isPresented`: SwiftUI keeps the presented content alive
        // through the dismissal animation, so clearing the draft on save doesn't
        // blank the sheet out mid-slide.
        content.sheet(item: $draft) { presented in
            ObservationDateSheet(
                // Reads and writes the *live* draft so the wheel's value
                // survives the detour out to the map and back.
                date: Binding(
                    get: { draft?.date ?? presented.date },
                    set: { draft?.date = $0 }
                ),
                store: store,
                initialCoordinate: presented.coordinate,
                initialName: presented.placeName,
                onCancel: { draft = nil },
                onSave: { coordinate, name in
                    commit(coordinate: coordinate, name: name)
                    onCommit?()
                    // Dismissing the date sheet takes its presented cover (and
                    // the naming sheet above that) with it, so the whole stack
                    // leaves in one animation rather than unwinding a step at a
                    // time.
                    draft = nil
                }
            )
        }
    }

    /// Writes the finished draft. An edit rewrites the sighting it started from;
    /// anything else is filed as a new one, creating the species' life-list entry
    /// if this is the first time it's been seen.
    private func commit(coordinate: CLLocationCoordinate2D, name: String) {
        guard let draft else { return }
        if let editing = draft.editing {
            store.replaceObservation(
                scientificName: draft.scientificName,
                original: editing,
                date: draft.date,
                location: name,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        } else {
            store.recordObservation(
                scientificName: draft.scientificName,
                commonName: draft.commonName,
                date: draft.date,
                location: name,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
    }
}

/// Step one of the add/edit flow: when did you see this bird? Defaults to today
/// (or, for an edit, to the date already recorded) and can't be set into the
/// future. Dismissible by swipe or by the leading Cancel button; the trailing
/// checkmark raises the map picker *over* this sheet, which stays mounted
/// underneath for the whole detour.
struct ObservationDateSheet: View {
    @Binding var date: Date
    let store: LifeListStore
    /// Where the map opens with its pin already down — the sighting's current
    /// location on an edit, `nil` for a new one.
    var initialCoordinate: CLLocationCoordinate2D? = nil
    /// What the naming step starts out holding, used only while the pin is still
    /// on `initialCoordinate` — move it somewhere else and the old name stops
    /// describing the place, so the suggestion is worked out afresh.
    var initialName: String? = nil
    let onCancel: () -> Void
    let onSave: (CLLocationCoordinate2D, String) -> Void

    /// Raises step two. Owned here rather than by the caller so the map can
    /// never outlive the sheet it was presented from.
    @State private var showLocationPicker = false
    /// The pin the user dropped on the map, held while step three asks what to
    /// call the place. Nothing is written until that sheet is confirmed.
    @State private var pickedCoordinate: CLLocationCoordinate2D?
    @State private var showNamePrompt = false

    /// How far the pin can sit from where the edit opened and still count as the
    /// same place — a few meters, i.e. it wasn't deliberately moved.
    private static let sameSpotTolerance: CLLocationDistance = 10

    /// The name to pre-fill step three with: the recorded one while the pin is
    /// still where the edit found it, and nothing once it's been moved.
    private var nameSuggestion: String? {
        guard let initialName, let initialCoordinate, let picked = pickedCoordinate else {
            return nil
        }
        let a = CLLocation(latitude: initialCoordinate.latitude, longitude: initialCoordinate.longitude)
        let b = CLLocation(latitude: picked.latitude, longitude: picked.longitude)
        return a.distance(from: b) <= Self.sameSpotTolerance ? initialName : nil
    }

    var body: some View {
        NavigationStack {
            // A wheel rather than the graphical calendar: the calendar's month
            // grid doesn't fit a medium detent alongside the title bar.
            DatePicker(
                "Observation date",
                selection: $date,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("When did you see this bird?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .cancel) { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // The system confirm role — a checkmark, tinted with the
                    // app's accent color.
                    Button(role: .confirm) { showLocationPicker = true }
                }
            }
        }
        .presentationDetents([.medium])
        // Hidden grab handle, matching the import sheet and the map's cards.
        .presentationDragIndicator(.hidden)
        // Step two, layered on top of this sheet rather than replacing it.
        .fullScreenCover(isPresented: $showLocationPicker) {
            MapView(picker: MapView.LocationPicker(
                initialCoordinate: initialCoordinate,
                onBack: { showLocationPicker = false },
                onConfirm: { coordinate in
                    pickedCoordinate = coordinate
                    showNamePrompt = true
                }
            ))
            .environment(store)
            // Step three sits on top of the map the same way the map sits on
            // top of the date sheet: dismissing it reveals the pin already
            // dropped, so backing out of the name doesn't restart the flow.
            .sheet(isPresented: $showNamePrompt) {
                ObservationNameSheet(
                    coordinate: pickedCoordinate ?? CLLocationCoordinate2D(),
                    // Threaded down for the same reason the map gets it:
                    // `@Observable` environment objects don't cross a sheet.
                    store: store,
                    initialName: nameSuggestion,
                    onCancel: { showNamePrompt = false },
                    onSave: { name in
                        guard let coordinate = pickedCoordinate else { return }
                        onSave(coordinate, name)
                    }
                )
            }
        }
    }
}

/// Step three of the flow: what do you call this place? Opens with the keyboard
/// already up and the field pre-filled — see `defaultName`. The suggestion is
/// only a starting point and the user is free to type over it, but it can't be
/// left blank: confirm stays disabled until the field holds something. Every
/// sighting Kestrel records therefore carries a place name, which is what the
/// eBird export needs to place it.
struct ObservationNameSheet: View {
    let coordinate: CLLocationCoordinate2D
    let store: LifeListStore
    /// The name this place already has, when the flow is editing a sighting
    /// whose pin hasn't moved. Wins over every other suggestion — it's the
    /// user's own wording for the very spot being re-saved.
    var initialName: String? = nil
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var name = ""
    /// True while the reverse lookup is in flight, so the field can show it's
    /// still working rather than looking like it came back empty.
    @State private var isLookingUp = true
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Place name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        Color.primary.opacity(0.06),
                        in: .rect(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(alignment: .trailing) {
                        if isLookingUp && name.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 16)
                        }
                    }
                    .padding(.horizontal, 20)
                Spacer(minLength: 0)
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
            .navigationTitle("Choose a short place name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .cancel) { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .confirm) { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        // Hidden grab handle, matching every other sheet in this flow.
        .presentationDragIndicator(.hidden)
        .task {
            focused = true
            // An edit of an unmoved pin already knows what this place is called;
            // there is nothing to look up.
            if let initialName, !initialName.isEmpty {
                isLookingUp = false
                if name.isEmpty { name = initialName }
                return
            }
            let suggestion = await defaultName()
            isLookingUp = false
            // A slow lookup must never stomp on something the user has already
            // typed, so the suggestion only lands in a still-empty field.
            guard let suggestion, name.isEmpty else { return }
            name = suggestion
        }
    }

    /// What confirm would actually store. Also gates the button and the
    /// keyboard's return key — a field holding only spaces is empty.
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        // Belt and braces alongside the disabled confirm: `.onSubmit` fires on
        // the return key, which stays live even while the button is disabled.
        guard !trimmedName.isEmpty else { return }
        // Two-pulse confirmation, moved here from the map's Save Observation
        // button: this is the tap that actually writes the sighting.
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onSave(trimmedName)
    }

    /// A mile. Close enough that two pins are almost certainly the same
    /// birding spot under the name the user already gave it.
    private static let reuseRadius: CLLocationDistance = 1609.344

    /// What the field starts out holding. A place the user has already named
    /// within a mile wins outright — their own wording for a patch beats
    /// anything a geocoder produces, and it keeps repeat visits to one spot
    /// filed under one name. Failing that, the pin is somewhere new, so the
    /// default is just the town: broad enough to be true wherever in it the
    /// pin landed, and short enough to type over.
    private func defaultName() async -> String? {
        if let nearby = store.nearestObservationName(to: coordinate, within: Self.reuseRadius) {
            return nearby
        }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // `MKReverseGeocodingRequest` rather than `CLGeocoder`, which iOS 26
        // deprecated. `cityName` is the direct replacement for the placemark's
        // `locality` — the town on its own, with no state or street attached,
        // which is what a short place name wants. `cityWithContext` is the
        // fallback rather than `fullAddress`: out in a county with no
        // incorporated town, "Tompkins County, NY" is still a place a person
        // recognizes, whereas a street address is noise to type over.
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        do {
            let items = try await request.mapItems
            guard let address = items.first?.addressRepresentations else { return nil }
            return address.cityName ?? address.cityWithContext
        } catch {
            // Offline or rate-limited: leave the field empty and let the user
            // type their own rather than guessing.
            Log.error("ObservationNameSheet: reverse geocode failed — \(error)")
            return nil
        }
    }
}

// MARK: - Add / edit / delete, as one piece of state

/// A pending "which sighting did you mean?" question, raised when an Edit or a
/// Delete finds more than one sighting the affordance could have meant.
struct ObservationChoice: Identifiable {
    /// Fresh per question rather than derived from the species, so two questions
    /// that differ only in `limitedTo` — the same bird asked about at two
    /// different places on the map — can never be mistaken for the same sheet.
    let id = UUID()
    let scientificName: String
    let commonName: String
    /// Which question is being asked. Both raise the same list of sightings;
    /// only the title and what a tap does differ.
    let isDeleting: Bool
    /// The sightings this question is about, when the affordance stood for only
    /// some of the species' history. A map thumbnail collapses every repeat
    /// sighting at one spot into one image, and it can only sensibly ask about
    /// those — offering a sighting from the other side of the country under a
    /// pin the user long-pressed here would be a non sequitur. `nil` means the
    /// question is about the species as a whole, which is what a life-list row
    /// or the photo viewer asks.
    let limitedTo: Set<LifeListEntry.Observation.Identity>?

    var title: String {
        isDeleting ? "Delete which observation?" : "Edit which observation?"
    }

    /// The sightings to offer, read live off `store` so a delete drops its row
    /// from the list standing behind the confirmation. The restriction is
    /// applied to that live read rather than to a frozen copy, so a sighting
    /// that no longer exists simply falls out.
    func observations(in store: LifeListStore) -> [LifeListEntry.Observation] {
        let all = store.observations(for: scientificName)
        guard let limitedTo else { return all }
        return all.filter { limitedTo.contains($0.identity) }
    }
}

/// One recorded sighting awaiting its delete confirmation. Every delete in the
/// app funnels through this so the wording can't drift — and so no tap ever
/// removes a sighting without being asked twice.
struct PendingObservationDelete: Identifiable {
    let scientificName: String
    let commonName: String
    let observation: LifeListEntry.Observation

    var id: String { scientificName + "|" + observation.summaryText }
}

/// The three things any Add / Edit / Delete affordance in the app can be
/// partway through, bundled so a host declares one piece of state and attaches
/// one modifier instead of four. Every menu, swipe action, and button that acts
/// on a sighting drives one of these.
@MainActor
@Observable
final class ObservationActions {
    /// A sighting being written — new or edited. See `observationFlow`.
    var draft: ObservationDraft?
    /// A "which sighting did you mean?" question awaiting an answer.
    var choice: ObservationChoice?
    /// A sighting awaiting its delete confirmation.
    var pendingDelete: PendingObservationDelete?

    /// Files a new sighting of a species.
    func add(scientificName: String, commonName: String) {
        draft = .adding(scientificName: scientificName, commonName: commonName)
    }

    /// Edits one known sighting.
    func edit(
        scientificName: String,
        commonName: String,
        observation: LifeListEntry.Observation
    ) {
        draft = .editing(
            scientificName: scientificName,
            commonName: commonName,
            observation: observation
        )
    }

    /// Edits "this bird", from somewhere that stands for the species rather than
    /// for one of its sightings — a life-list row, the full-screen viewer. A bird
    /// seen once has only one sighting the request could mean, so that one is
    /// edited outright; with several on record the user is asked which.
    func edit(scientificName: String, commonName: String, in store: LifeListStore) {
        resolve(
            scientificName: scientificName,
            commonName: commonName,
            observations: store.observations(for: scientificName),
            limited: false,
            isDeleting: false
        )
    }

    /// Edits "this bird" where the affordance stands for only *part* of its
    /// history — a map thumbnail, which collapses every repeat sighting at one
    /// spot into a single image. The question, if one has to be asked, covers
    /// exactly those sightings and no others.
    func edit(
        scientificName: String,
        commonName: String,
        among observations: [LifeListEntry.Observation]
    ) {
        resolve(
            scientificName: scientificName,
            commonName: commonName,
            observations: observations,
            limited: true,
            isDeleting: false
        )
    }

    /// Deletes one known sighting, after a confirmation.
    func delete(
        scientificName: String,
        commonName: String,
        observation: LifeListEntry.Observation
    ) {
        pendingDelete = PendingObservationDelete(
            scientificName: scientificName,
            commonName: commonName,
            observation: observation
        )
    }

    /// Deletes "this bird", the mirror of the species-scoped `edit` above.
    func delete(scientificName: String, commonName: String, in store: LifeListStore) {
        resolve(
            scientificName: scientificName,
            commonName: commonName,
            observations: store.observations(for: scientificName),
            limited: false,
            isDeleting: true
        )
    }

    /// Deletes from a partial set of sightings — the mirror of `edit(among:)`.
    func delete(
        scientificName: String,
        commonName: String,
        among observations: [LifeListEntry.Observation]
    ) {
        resolve(
            scientificName: scientificName,
            commonName: commonName,
            observations: observations,
            limited: true,
            isDeleting: true
        )
    }

    /// The shared body of the four calls above: one candidate is acted on
    /// outright, several raise the question, none is a no-op. `limited` says
    /// whether `observations` is the species' whole history (in which case the
    /// chooser re-reads it live) or a subset the caller picked out.
    private func resolve(
        scientificName: String,
        commonName: String,
        observations: [LifeListEntry.Observation],
        limited: Bool,
        isDeleting: Bool
    ) {
        if observations.count > 1 {
            choice = ObservationChoice(
                scientificName: scientificName,
                commonName: commonName,
                isDeleting: isDeleting,
                limitedTo: limited ? Set(observations.map(\.identity)) : nil
            )
        } else if let only = observations.first {
            if isDeleting {
                delete(scientificName: scientificName, commonName: commonName, observation: only)
            } else {
                edit(scientificName: scientificName, commonName: commonName, observation: only)
            }
        }
    }
}

extension View {
    /// Installs the presentations behind `actions`: the date → map → name flow,
    /// the "which sighting?" chooser, and the delete confirmation. Attach it
    /// wherever a menu or swipe action drives an `ObservationActions`.
    /// `store` is optional only because the full-screen viewer reads it from the
    /// environment, where it can be absent (previews); with no store there is
    /// nothing any of these presentations could act on, so they simply aren't
    /// installed.
    func observationActions(_ actions: ObservationActions, store: LifeListStore?) -> some View {
        modifier(ObservationActionsModifier(actions: actions, store: store))
    }
}

private struct ObservationActionsModifier: ViewModifier {
    @Bindable var actions: ObservationActions
    let store: LifeListStore?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let store {
            content
                .observationFlow($actions.draft, store: store)
                .sheet(item: $actions.choice) { choice in
                    ObservationChoiceSheet(
                        choice: choice,
                        store: store,
                        onFinished: { actions.choice = nil }
                    )
                }
                .observationDeleteConfirmation($actions.pendingDelete, store: store)
        } else {
            content
        }
    }
}

extension View {
    /// The one delete confirmation in the app for a single sighting. Split out
    /// of `observationActions` so the chooser sheet — which has to raise its own,
    /// over itself — can use exactly the same alert.
    func observationDeleteConfirmation(
        _ pending: Binding<PendingObservationDelete?>,
        store: LifeListStore,
        onDeleted: (() -> Void)? = nil
    ) -> some View {
        modifier(ObservationDeleteConfirmation(pending: pending, store: store, onDeleted: onDeleted))
    }
}

private struct ObservationDeleteConfirmation: ViewModifier {
    @Binding var pending: PendingObservationDelete?
    let store: LifeListStore
    let onDeleted: (() -> Void)?

    func body(content: Content) -> some View {
        content.alert(
            // No `role: .destructive` on the *entry* into this alert anywhere in
            // the app — see the life-list row's swipe — but the confirm itself is
            // destructive and reads as such.
            pending.map { "Delete this \($0.commonName) observation?" } ?? "",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting: pending
        ) { target in
            Button("Delete", role: .destructive) {
                store.removeObservation(
                    scientificName: target.scientificName,
                    identity: target.observation.identity
                )
                pending = nil
                onDeleted?()
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { target in
            Text(target.observation.summaryText)
        }
    }
}

/// The chooser's contents. Both the edit flow and the delete confirmation are
/// presented from *here* rather than from whatever raised the chooser, so the
/// chooser stays standing underneath: backing out of either lands back on the
/// list of sightings instead of dumping the user out entirely.
private struct ObservationChoiceSheet: View {
    let choice: ObservationChoice
    /// Threaded down for the usual reason — `@Observable` environment objects
    /// don't cross a sheet boundary.
    let store: LifeListStore
    /// The chosen action went through; put the chooser away.
    let onFinished: () -> Void

    @State private var draft: ObservationDraft?
    @State private var pendingDelete: PendingObservationDelete?

    var body: some View {
        ObservationPickerSheet(
            title: choice.title,
            // Read live off the store so a delete that leaves the species
            // standing updates the list behind the confirmation — narrowed to
            // the sightings the question is actually about (see `limitedTo`).
            observations: choice.observations(in: store),
            onSelect: { observation in
                if choice.isDeleting {
                    pendingDelete = PendingObservationDelete(
                        scientificName: choice.scientificName,
                        commonName: choice.commonName,
                        observation: observation
                    )
                } else {
                    draft = .editing(
                        scientificName: choice.scientificName,
                        commonName: choice.commonName,
                        observation: observation
                    )
                }
            }
        )
        .observationFlow($draft, store: store, onCommit: onFinished)
        .observationDeleteConfirmation($pendingDelete, store: store, onDeleted: {
            // Step aside once there is nothing left to *choose between*.
            // Clearing out several stray sightings is one visit to this list,
            // not one visit per sighting — the list behind the confirmation is
            // read live off the store, so each deleted row is already gone — but
            // a list offering a single option isn't a question any more, and a
            // sheet still titled "Delete which observation?" over one row reads
            // as a dead end. Same threshold the full-screen viewer's observation
            // list uses when a delete takes it down to one.
            if choice.observations(in: store).count < 2 { onFinished() }
        })
    }
}

// MARK: - Picking one sighting out of several

extension LifeListEntry.Observation {
    /// The same "Place • Date" description as `ObservationRowLabel`, as a plain
    /// string — for the places that can only take text, like an alert's message.
    var summaryText: String {
        let day = date.formatted(.dateTime.year().month(.abbreviated).day())
        guard let place = location, !place.isEmpty else { return day }
        return "\(place) • \(day)"
    }
}

/// "Place • Date" — the one-line description of a recorded sighting, shared by
/// every list that shows observations so they can't drift apart in format.
struct ObservationRowLabel: View {
    let observation: LifeListEntry.Observation

    var body: some View {
        HStack(spacing: 4) {
            if let place = observation.location, !place.isEmpty {
                Text(place)
                    .fixedSize(horizontal: false, vertical: true)
                Text("•")
                    .foregroundStyle(.secondary)
            }
            Text(observation.date, format: .dateTime.year().month(.abbreviated).day())
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// Sheet listing a species' sightings, newest first, so one of them can be
/// picked. Every list of observations in the app is this view: the full-screen
/// viewer's "N Observations", and the Life List tab's "which one did you mean?"
/// choosers. What a tap *does* is the caller's business; the swipe actions are
/// only present when the caller supplies them.
struct ObservationPickerSheet: View {
    let title: String
    let observations: [LifeListEntry.Observation]
    /// Tapping a row.
    let onSelect: (LifeListEntry.Observation) -> Void
    /// Whether a row can be tapped at all. Defaults to yes; the full-screen
    /// viewer, whose tap takes the sighting to the map, says no for one without
    /// coordinates rather than offering a tap that would do nothing.
    var canSelect: (LifeListEntry.Observation) -> Bool = { _ in true }
    /// Trailing-swipe Edit. `nil` leaves the rows without swipe actions.
    var onEdit: ((LifeListEntry.Observation) -> Void)? = nil
    /// Trailing-swipe Delete, alongside Edit.
    var onDelete: ((LifeListEntry.Observation) -> Void)? = nil

    /// Closes the sheet from the back button. Works for every host: this view is
    /// always the sheet's root content, so dismissing it clears whichever
    /// binding presented it.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(observations, id: \.identity) { observation in
                    row(for: observation)
                    // Trailing actions are laid out from the trailing edge
                    // inward in declaration order, so Delete goes first to put
                    // Edit on its left — the same pairing (and the same colors)
                    // a life-list row swipes to reveal.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if let onDelete {
                            Button {
                                onDelete(observation)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                        if let onEdit {
                            Button {
                                onEdit(observation)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.kestrelEditGreen)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The grab handle is hidden on every sheet in this flow, so
                // without this the only way out of the list is a swipe nobody is
                // told about. The system cancel role — the same X, in the same
                // top-left slot, that the date and naming sheets carry — rather
                // than a back chevron: this list is raised directly by a swipe or
                // a menu, so leaving it abandons the action outright rather than
                // stepping back to something.
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Hidden grab handle, matching every other sheet in the app.
        .presentationDragIndicator(.hidden)
    }

    /// One sighting. A row the caller has marked unselectable is plain content
    /// rather than a `Button`, so it neither highlights on touch nor offers a tap
    /// that would go nowhere; its swipe actions still work.
    @ViewBuilder
    private func row(for observation: LifeListEntry.Observation) -> some View {
        let label = ObservationRowLabel(observation: observation)
            .font(.body)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
        if canSelect(observation) {
            Button {
                onSelect(observation)
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }
}
