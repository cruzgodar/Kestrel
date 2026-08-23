import CoreLocation
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
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return nil }
            return placemark.locality ?? placemark.subAdministrativeArea
        } catch {
            // Offline or rate-limited: leave the field empty and let the user
            // type their own rather than guessing.
            Log.error("ObservationNameSheet: reverse geocode failed — \(error)")
            return nil
        }
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
    /// Trailing-swipe Edit. `nil` leaves the rows without swipe actions.
    var onEdit: ((LifeListEntry.Observation) -> Void)? = nil
    /// Trailing-swipe Delete, alongside Edit.
    var onDelete: ((LifeListEntry.Observation) -> Void)? = nil

    var body: some View {
        NavigationStack {
            List {
                ForEach(observations, id: \.identity) { observation in
                    Button {
                        onSelect(observation)
                    } label: {
                        ObservationRowLabel(observation: observation)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
        }
        .presentationDetents([.medium, .large])
        // Hidden grab handle, matching every other sheet in the app.
        .presentationDragIndicator(.hidden)
    }
}
