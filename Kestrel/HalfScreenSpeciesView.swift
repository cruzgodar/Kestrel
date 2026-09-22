import SwiftUI

/// The Identify tab's left-hand pane on a foldable's inner display: the
/// full-screen bird viewer, in half a screen, standing open beside the list.
///
/// The same black card and the same zoomable photo the viewer uses, minus the
/// two controls that only make sense over a presentation — Back, because there
/// is nothing to go back to, and More, because the list beside it already
/// carries every one of those actions per row. What is left is a picture of the
/// bird, which is the point of it.
///
/// Unlike the viewer this is *live*: the list next to it is still running, so
/// the pane follows it (see `ContentView`), crossfading between birds rather
/// than paging. The photo can be zoomed in, and no further out than the pane —
/// `ZoomablePhotoPage` fits it to whatever box it is given and treats that as
/// the minimum zoom, so the picture can never shrink inside its own half.
struct HalfScreenSpeciesView: View {
    /// The bird on show. `nil` before anything has been heard, which draws the
    /// empty card.
    let scientificName: String?
    /// Reports whether the photo is zoomed in. The tab uses it to decide
    /// whether a newly-heard bird may take the pane over (see `ContentView`):
    /// a zoomed-in photo is someone looking closely at something, and pulling
    /// it out from under them would be rude.
    var onZoomChange: (Bool) -> Void = { _ in }

    /// Only for the name on the capsule. Optional so previews without a store
    /// still render.
    @Environment(LifeListStore.self) private var lifeListStore: LifeListStore?

    /// The viewer's page gate, which holds a page's full-resolution download
    /// until motion stops. Nothing here ever moves, so it is simply open.
    @State private var paging = ViewerPaging()

    /// How long one bird takes to dissolve into the next.
    static let crossfade: Double = 0.3

    /// Matches the viewer's chrome: a 22pt glyph plus 13pt of padding.
    private static let capsuleHeight: CGFloat = 48

    private var commonName: String? {
        guard let scientificName else { return nil }
        return lifeListStore?.commonName(for: scientificName)
            ?? SpeciesCatalog.shared.commonName(for: scientificName)
            ?? scientificName
    }

    var body: some View {
        ZStack {
            // Edge to edge, and under the photo rather than behind the whole
            // pane, so the card still reads as black while a crossfade has two
            // photos on top of it at partial opacity.
            Color.black

            if let scientificName {
                ZoomablePhotoPage(
                    item: SpeciesPhotoItem(scientificName: scientificName),
                    paging: paging,
                    // Fitted inside the pane, not grown to span a display: the
                    // pane *is* the frame, and fitting it is what makes that
                    // frame the zoom floor.
                    spansDisplay: false,
                    restingInsets: (0, 0),
                    onToggleUI: {},
                    onZoomChange: onZoomChange,
                    onAtTopEdgeChange: { _ in },
                    onPageBeyondEdge: { _ in },
                    expandsIntoSafeArea: false
                )
                // Identity per bird, so switching birds mounts a fresh page —
                // which is what gives the crossfade something to fade between,
                // and what resets the zoom for a picture nobody has looked at
                // yet.
                .id(scientificName)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let commonName {
                Text(commonName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 18)
                    .frame(height: Self.capsuleHeight)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 12)
                    .padding(.horizontal, 12)
                    // The name rides above the photo without taking its taps —
                    // a tap anywhere in the pane belongs to the photo.
                    .allowsHitTesting(false)
                    .id(commonName)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: Self.crossfade), value: scientificName)
        // The photo is fitted to the pane, but a zoom can carry it past the
        // edges; this is what keeps it inside its own half.
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(commonName.map { "Photo of \($0)" } ?? "No bird heard yet")
    }
}
