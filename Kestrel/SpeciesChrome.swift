import SwiftUI

/// The furniture both species views wear: the name capsule at the top and the
/// details panel at the bottom.
///
/// Two screens show a bird's photograph — the full-screen viewer
/// (`SpeciesPhotoFullScreen`) and the Identify tab's half-screen pane
/// (`HalfScreenSpeciesView`) — and they are the same thing at two sizes, so
/// their chrome is defined once here rather than twice in two files that would
/// drift. What differs between them is only what each can *do*: the viewer can
/// raise an observation list and send a sighting to the map, and the pane can
/// do neither, which it says by passing `nil` for those actions rather than by
/// having a panel of its own.
enum SpeciesChrome {
    /// Height of the top controls (a 22pt glyph + 13pt padding = 48pt). The
    /// name capsule matches it; the details panel's corner radius is half of it.
    static let height: CGFloat = 48

    /// The corner radius of a piece of chrome tucked into a display corner.
    /// Fixed, so the panel and the capsule both stay pills; concentricity is
    /// got by *placing* them rather than by bending their corners.
    static let cornerPillRadius: CGFloat = 24

    /// The glass both pieces are cut from: tinted dark, so white text and an
    /// accent-coloured link stay legible over a bright photograph. Untinted
    /// glass takes its brightness from whatever is behind it, and behind this
    /// is a photograph — a bird against a pale sky lifted the panel to nearly
    /// white and took the text with it.
    ///
    /// One value, so the capsule and the panel can never drift apart. Raise
    /// `glassTint` to darken both.
    static let glass: Glass = .regular.tint(.black.opacity(glassTint))

    /// How dark that glass is over a photograph.
    static let glassTint: Double = 0.55

    /// How dark the half-screen pane's panel is, which is darker.
    ///
    /// Its own figure because it is not over a photograph. The pane's panel
    /// sits mostly on the coloured card — a pale wash on a pale background —
    /// and glass over that is far lighter than glass over a picture, which
    /// left white text on it thinner than the same text in the viewer.
    static let paneGlassTint: Double = 0.72

    /// The glass the half-screen pane's panel is cut from. See `paneGlassTint`.
    static let paneGlass: Glass = .regular.tint(.black.opacity(paneGlassTint))

    /// The colour a tappable thing on the panel is drawn in.
    ///
    /// Not the accent colour, which is the solid, fully-saturated purple meant
    /// for filling a control. This is text on a dark glass panel over a
    /// photograph, where the same job is done by the paler purple the watch
    /// draws a new lifer's name in and the Identify tab washes its add rows
    /// with — one definition, in `HighlightedText`, so all three stay the same
    /// purple.
    static let linkTint: Color = HighlightedText.addHighlight
}

// MARK: - Name capsule

/// The species name in a glass capsule, dressed the same way the details panel
/// is. Hugs the name; a name too wide for the cap (which leaves room for the
/// bar's buttons on either side) scales down to fit.
struct SpeciesNameCapsule: View {
    let name: String
    /// The width the capsule has to live inside — the safe width of whatever is
    /// showing the photo, not the display's.
    let contentWidth: CGFloat
    /// Width kept clear for whatever shares the capsule's line. The viewer is
    /// the reason this is not simply a margin: its capsule is the navigation
    /// bar's principal item, sitting between Back and More, and has to leave
    /// both of them room. A pane with no bar wants nothing but a margin.
    var reserving: CGFloat = 150
    /// True where the capsule is tucked into a display corner, which squares its
    /// radius off to a constant pill and pins it leading inside its fit budget.
    var hugsCorner: Bool = false

    private var shape: AnyShape {
        AnyShape(.rect(
            cornerRadius: hugsCorner ? SpeciesChrome.cornerPillRadius : SpeciesChrome.height / 2
        ))
    }

    var body: some View {
        let cap = max(contentWidth - reserving, 80)
        // `ViewThatFits` picks the natural-width label when it fits within `cap`
        // (so the capsule hugs the text) and only falls back to the scaled,
        // cap-width label when the name is genuinely too long. A plain
        // line-limited `Text` would silently truncate to the budget and always
        // "fit", so `fixedSize` is what exposes the label's true ideal width.
        ViewThatFits(in: .horizontal) {
            label
                .fixedSize(horizontal: true, vertical: false)
            label
                .minimumScaleFactor(0.5)
        }
        // The fit budget is a transparent box wider than the capsule inside it,
        // so where the capsule sits within that box is where it actually lands.
        // Centred by default, but pinned leading in a corner — otherwise the
        // capsule floats out towards the middle of the screen, and, because a
        // concentric corner is measured from the display's, its radius collapses
        // to nothing that far in.
        .frame(maxWidth: cap, alignment: hugsCorner ? .leading : .center)
    }

    private var label: some View {
        Text(name)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(height: SpeciesChrome.height)
            .glassEffect(SpeciesChrome.glass, in: shape)
            // Swallow taps on the capsule so tapping the chrome doesn't also
            // fire the photo's single-tap-to-hide. Only the hugging capsule
            // absorbs; the transparent fit budget around it stays pass-through.
            .contentShape(shape)
            .onTapGesture { }
    }
}

// MARK: - Details panel

/// Bottom details — the sighting (place and date, or a count when there are
/// several) and the photo attribution — in a glass panel. Non-link text is
/// white like the name; the panel's width is capped for a generous margin from
/// the edges.
///
/// Every interactive part is optional. Hand it `onShowObservations` and the
/// count becomes a button; hand it `onShowOnMap` and the place name becomes a
/// link. A host that can do neither (the Identify pane, which has no
/// presentation of its own to put a sheet on) passes neither, and the same
/// panel renders the same facts as plain text.
struct SpeciesInfoPanel: View {
    /// The bird the panel describes, or `nil` when there isn't one yet — the
    /// Identify pane before anything has been heard, which shows the panel with
    /// its heading and nothing under it rather than showing no panel at all.
    let item: SpeciesPhotoItem?
    /// A heading set above everything else in the panel — the bird's name,
    /// where the host has nowhere else to put it. The full-screen viewer does
    /// (its own capsule, or the navigation bar) and passes `nil`; the Identify
    /// pane, which is one card with one corner free, folds the name into the
    /// panel rather than spending a second piece of chrome on it.
    /// Every recorded sighting of this bird, newest first — empty for a
    /// pin-scoped item, which stands for the one sighting in `observation`.
    let observations: [LifeListEntry.Observation]
    /// The one sighting the photo stands for, *as it now stands*. `nil` for a
    /// species-scoped item.
    var observation: LifeListEntry.Observation?
    /// Raises the full list of sightings. `nil` prints the count plainly.
    var onShowObservations: (() -> Void)?
    /// Sends a sighting to the map. `nil` leaves the place name plain.
    var onShowOnMap: ((LifeListEntry.Observation?) -> Void)?
    /// What VoiceOver calls the place-name tap.
    var mapButtonTitle: String?
    /// The width the panel has to live inside.
    let contentWidth: CGFloat
    /// True where the panel is tucked into a display corner — see
    /// `SpeciesChrome.cornerPillRadius`.
    var hugsCorner: Bool = false
    /// The glass to cut it from. The default is the one the viewer wears over
    /// a photograph; the half-screen pane passes a darker one — see
    /// `SpeciesChrome.paneGlassTint`.
    var glass: Glass = SpeciesChrome.glass
    /// The heading, if the host wants one. Declared last so the existing
    /// call sites are untouched.
    var title: String?

    private var info: SpeciesPhotoInfo? {
        item.flatMap { SpeciesPhotoMetadata.shared.info(for: $0.scientificName) }
    }

    var body: some View {
        // Concentric with the display's own corners when the panel is tucked
        // into one, so its curve continues the screen's rather than cutting
        // across it; the familiar capsule ends everywhere else.
        let shape: AnyShape = AnyShape(.rect(
            cornerRadius: hugsCorner ? SpeciesChrome.cornerPillRadius : SpeciesChrome.height / 2
        ))
        return VStack(spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let item {
                sightingSection(item)
            }

            if let info {
                attribution(info)
            } else if item != nil {
                // No photo for this species yet — reassure the user one is
                // coming, in the same slot the attribution would occupy.
                Text("Photo coming soon!")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
        .frame(maxWidth: min(contentWidth - 80, 360))
        .glassEffect(glass, in: shape)
        // Swallow taps on blank areas of the panel so tapping the chrome
        // doesn't fire the photo's single-tap-to-hide. The inner map button /
        // source link keep working — their own gestures take precedence over
        // this no-op.
        .contentShape(shape)
        .onTapGesture { }
    }

    /// The sighting part. A bird seen once shows where and when; a bird seen
    /// several times shows the count instead and leaves the individual
    /// sightings to whoever can present them — there is no one place and date
    /// to print, and listing them all would swamp the panel.
    @ViewBuilder
    private func sightingSection(_ item: SpeciesPhotoItem) -> some View {
        if observations.count > 1 {
            countLine(observations.count)
        } else if item.showsAllObservations && observations.isEmpty {
            // Species-scoped with nothing on record: either a bird that was
            // never seen, or one whose last sighting was just deleted.
            // `singleSighting` would fall back to the item's own captured
            // `placeName` / `dateFound`, which for the delete case describe a
            // record that no longer exists.
            EmptyView()
        } else {
            // `observations` is empty for a pin-scoped item, so this is where
            // its own sighting is printed.
            singleSighting(observations.first ?? observation, item: item)
        }
    }

    /// "N Observations" — a button where the host can show them, plain text
    /// where it can't.
    @ViewBuilder
    private func countLine(_ count: Int) -> some View {
        let label = HStack(spacing: 4) {
            Text("\(count) Observations")
            if onShowObservations != nil {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
            }
        }
        .font(.subheadline)
        .foregroundStyle(onShowObservations == nil ? Color.white : SpeciesChrome.linkTint)
        // The same generous hit area the single place-and-date line gets.
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        if let onShowObservations {
            Button {
                onShowObservations()
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(NoDimButtonStyle())
            .accessibilityLabel("\(count) observations")
        } else {
            label
        }
    }

    /// Place + date for a bird with one sighting to its name.
    @ViewBuilder
    private func singleSighting(
        _ sighting: LifeListEntry.Observation?,
        item: SpeciesPhotoItem
    ) -> some View {
        let place = sighting?.location ?? item.placeName
        let date = sighting?.date ?? item.dateFound
        // Whether "Show on Map" has anywhere to go. A host's callback quietly
        // does nothing for a sighting logged without coordinates (an eBird row
        // with no lat/lon), so without this check the place name would render
        // as an accent-coloured link that swallows the tap.
        let mappable = onShowOnMap != nil && (sighting ?? item.observation)?.hasCoordinate == true
        if let date {
            // Place (accent-coloured, the map link) + date stacked together.
            // When the map action is available the *whole block* — place, date,
            // and a little padding around them — is one button, so the tap
            // target is generous rather than just the place-name text.
            let block = VStack(spacing: 3) {
                if let place, !place.isEmpty {
                    // Tight spacing keeps the pin close to the place name.
                    HStack(spacing: 4) {
                        Text(place)
                        if mappable {
                            Image(systemName: "mappin.circle")
                        }
                    }
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(mappable ? SpeciesChrome.linkTint : Color.white)
                }
                Text(date, format: ObservationDate.dayStyle)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }

            if mappable, let onShowOnMap {
                Button { onShowOnMap(sighting) } label: {
                    block
                        // Generous hit area: padding around the whole
                        // place+date block so taps near it land.
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NoDimButtonStyle())
                .accessibilityLabel(mapButtonTitle ?? "Show on Map")
            } else {
                block
            }
        }
    }

    /// The photographer's credit, linked to the source page when there is one.
    /// The whole block is the tap target, but only the "View source" line takes
    /// the accent colour; the attribution above it stays white.
    @ViewBuilder
    private func attribution(_ info: SpeciesPhotoInfo) -> some View {
        let block = VStack(spacing: 4) {
            Text(info.attributionWithLicense)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            if info.sourceURL != nil {
                Text("View source")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(SpeciesChrome.linkTint)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())

        if let sourceURL = info.sourceURL {
            Link(destination: sourceURL) { block }
                .buttonStyle(NoDimButtonStyle())
                .accessibilityLabel("View photo source")
        } else {
            block
        }
    }
}

/// The wash a bird's chrome takes, the same one its row carries in the Identify
/// list: purple for a bird not yet on the life list, blue for a starred one,
/// grey for the rest.
///
/// The list leaves that last case untinted, because a row sits on the list's
/// own background and needs no help to read as a row. The species pane's card
/// has nothing behind it but the tab, so its plain case is a grey of the same
/// weight rather than nothing at all.
enum SpeciesTint: Equatable {
    /// Not on the life list when the session began.
    case newLifer
    /// On the list, and starred.
    case starred
    /// Neither.
    case plain

    /// How much of the tint is laid over what is behind it. One figure for all
    /// three, so they read as a set; the same one the rows wash themselves
    /// with, so a bird's card and a bird's row are the same colour.
    static let opacity: Double = 0.35

    /// Grey at the weight of the other two. It cannot literally share their
    /// HSB value — a colour with no saturation at brightness 1 is white — so
    /// what it shares is the opacity and a mid brightness, which lands it at
    /// the lightness the two washes come out at over a pale background.
    private static let plainBase = Color(hue: 0, saturation: 0, brightness: 0.5)

    /// Which wash a bird takes.
    ///
    /// `lifeListSnapshot` is the life list as it stood when the session began
    /// (see `RecordingManager.lifeListSnapshot`), so a bird's colour does not
    /// change under the user the instant they add it.
    init(scientificName: String, lifeListSnapshot: Set<String>, starredNames: Set<String>) {
        if !lifeListSnapshot.contains(scientificName) {
            self = .newLifer
        } else if starredNames.contains(scientificName) {
            self = .starred
        } else {
            self = .plain
        }
    }

    /// The tint at full strength.
    var base: Color {
        switch self {
        case .newLifer: HighlightedText.addHighlight
        case .starred: HighlightedText.starHighlight
        case .plain: Self.plainBase
        }
    }

    /// The tint as it is drawn.
    var color: Color { base.opacity(Self.opacity) }

    /// One tint `fraction` of the way to another, for a card whose colour has
    /// to follow a swipe rather than jump when it lands.
    ///
    /// Mixed in RGB and drawn once, rather than the two washes stacked with
    /// complementary opacities: stacked, the pair composite one over the other
    /// instead of blending, and the total loses about a tenth of its strength
    /// halfway across — the card visibly pales as the finger passes the middle.
    static func blend(_ from: SpeciesTint, to: SpeciesTint, fraction: Double) -> Color {
        let t = min(max(fraction, 0), 1)
        guard from != to, t > 0 else { return from.color }
        let a = from.components
        let b = to.components
        return Color(
            .sRGB,
            red: a.red + (b.red - a.red) * t,
            green: a.green + (b.green - a.green) * t,
            blue: a.blue + (b.blue - a.blue) * t,
            opacity: opacity
        )
    }

    private var components: (red: Double, green: Double, blue: Double) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(base).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue))
    }
}
