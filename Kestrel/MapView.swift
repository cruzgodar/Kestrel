import CoreLocation
import MapKit
import SwiftUI

struct MapView: View {
    @Environment(LifeListStore.self) private var store

    @State private var position: MapCameraPosition = .userLocation(
        fallback: .automatic
    )
    /// Latest map region from `onMapCameraChange`. Drives clustering — we
    /// need the visible span (in degrees) plus the view size (in points)
    /// to know which annotations would visually overlap.
    @State private var region: MKCoordinateRegion?
    @State private var viewSize: CGSize = .zero

    /// Pushed when the user taps a cluster with only one bird, or picks a
    /// row from the expand sheet. Drives the fullscreen detail cover.
    @State private var selectedEntry: LifeListEntry?
    /// Pushed when the user taps a cluster representative that's hiding
    /// other birds. Drives the expand sheet.
    @State private var expandedCluster: BirdCluster?

    /// Pinned thumbnail dimensions on the map. Chosen so a few birds fit
    /// per row at typical city-zoom, with a thin white border that reads
    /// against satellite + standard map styles.
    private static let thumbSize = CGSize(width: 52, height: 40)

    private var entriesWithCoordinates: [LifeListEntry] {
        store.entries.filter { $0.firstLatitude != nil && $0.firstLongitude != nil }
    }

    private var clusters: [BirdCluster] {
        guard let region else { return [] }
        return Self.computeClusters(
            entries: entriesWithCoordinates,
            region: region,
            viewSize: viewSize,
            thumbSize: Self.thumbSize
        )
    }

    var body: some View {
        GeometryReader { geo in
            Map(position: $position) {
                UserAnnotation()
                ForEach(clusters) { cluster in
                    Annotation(
                        cluster.representative.commonName,
                        coordinate: cluster.coordinate,
                        anchor: .center
                    ) {
                        Button {
                            if cluster.others.isEmpty {
                                selectedEntry = cluster.representative
                            } else {
                                expandedCluster = cluster
                            }
                        } label: {
                            BirdMapThumbnail(
                                scientificName: cluster.representative.scientificName,
                                size: Self.thumbSize
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                region = context.region
            }
            .onAppear {
                viewSize = geo.size
                if region == nil {
                    region = MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                        span: MKCoordinateSpan(latitudeDelta: 180, longitudeDelta: 360)
                    )
                }
            }
            .onChange(of: geo.size) { _, new in
                viewSize = new
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .task {
            // Trigger the permission prompt if the user opens Map before
            // ever tapping Start Recording, and seed LocationCache so the
            // life-list add buttons have a coordinate to attach right away.
            let manager = CLLocationManager()
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
            _ = await LocationCache.shared.current()
        }
        .fullScreenCover(item: $selectedEntry) { entry in
            BirdDetailView(entry: entry)
        }
        .sheet(item: $expandedCluster) { cluster in
            ClusterExpandView(cluster: cluster) { entry in
                expandedCluster = nil
                // Defer the fullscreen cover by one runloop turn so the
                // sheet's own dismiss transition can complete before the
                // cover slides in — otherwise the two animations fight
                // and the cover comes in from nowhere.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    selectedEntry = entry
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Clustering

    /// Greedy "Photos-style" clustering: walk entries newest-first, and
    /// fold each one into an existing cluster if its coordinate lands
    /// within one thumbnail (plus a 4pt gutter) of that cluster's
    /// representative. The first entry to land in any neighborhood
    /// becomes the representative — i.e. the most recent sighting wins.
    static func computeClusters(
        entries: [LifeListEntry],
        region: MKCoordinateRegion,
        viewSize: CGSize,
        thumbSize: CGSize
    ) -> [BirdCluster] {
        guard !entries.isEmpty,
              viewSize.width > 0, viewSize.height > 0,
              region.span.latitudeDelta > 0,
              region.span.longitudeDelta > 0 else { return [] }

        let sorted = entries.sorted { $0.firstSeen > $1.firstSeen }
        let lonPerPt = region.span.longitudeDelta / Double(viewSize.width)
        let latPerPt = region.span.latitudeDelta / Double(viewSize.height)
        let minDLon = lonPerPt * Double(thumbSize.width + 4)
        let minDLat = latPerPt * Double(thumbSize.height + 4)

        var reps: [(entry: LifeListEntry, coord: CLLocationCoordinate2D, others: [LifeListEntry])] = []
        reps.reserveCapacity(sorted.count)

        for entry in sorted {
            guard let lat = entry.firstLatitude,
                  let lon = entry.firstLongitude else { continue }
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            var folded = false
            for i in reps.indices {
                let dLat = abs(reps[i].coord.latitude - lat)
                let dLon = abs(reps[i].coord.longitude - lon)
                if dLat < minDLat && dLon < minDLon {
                    reps[i].others.append(entry)
                    folded = true
                    break
                }
            }
            if !folded {
                reps.append((entry, coord, []))
            }
        }

        return reps.map {
            BirdCluster(
                representative: $0.entry,
                coordinate: $0.coord,
                others: $0.others
            )
        }
    }
}

// MARK: - Cluster model

struct BirdCluster: Identifiable, Hashable {
    let representative: LifeListEntry
    let coordinate: CLLocationCoordinate2D
    let others: [LifeListEntry]

    var id: String { representative.scientificName }
    var all: [LifeListEntry] { [representative] + others }

    static func == (lhs: BirdCluster, rhs: BirdCluster) -> Bool {
        lhs.id == rhs.id
            && lhs.others.map(\.scientificName) == rhs.others.map(\.scientificName)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(representative.scientificName)
        hasher.combine(others.map(\.scientificName))
    }
}

// MARK: - Thumbnail rendered on the map

private struct BirdMapThumbnail: View {
    let scientificName: String
    let size: CGSize

    var body: some View {
        Group {
            if let img = SpeciesImageCache.shared.image(for: scientificName) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray
                    .overlay {
                        Image(systemName: "bird")
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white, lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Fullscreen detail (single bird)

private struct BirdDetailView: View {
    let entry: LifeListEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer(minLength: 0)

                Group {
                    if let url = SpeciesImage.largeURL(for: entry.scientificName),
                       let img = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: img)
                            .resizable()
                            .interpolation(.medium)
                            .scaledToFit()
                    } else if let img = SpeciesImageCache.shared.image(for: entry.scientificName) {
                        Image(uiImage: img)
                            .resizable()
                            .interpolation(.medium)
                            .scaledToFit()
                    } else {
                        Image(systemName: "bird")
                            .font(.system(size: 80))
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)

                VStack(spacing: 6) {
                    Text(entry.commonName)
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(entry.scientificName)
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.white.opacity(0.75))
                    Text(entry.firstSeen, format: .dateTime.month(.wide).day().year())
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .white.opacity(0.25))
                    }
                    .padding(.top, 20)
                    .padding(.trailing, 16)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Cluster expand sheet

private struct ClusterExpandView: View {
    let cluster: BirdCluster
    let onSelect: (LifeListEntry) -> Void

    private let columns = [GridItem(.adaptive(minimum: 88, maximum: 120), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(cluster.all) { entry in
                        Button {
                            onSelect(entry)
                        } label: {
                            VStack(spacing: 6) {
                                BirdMapThumbnail(
                                    scientificName: entry.scientificName,
                                    size: CGSize(width: 88, height: 66)
                                )
                                Text(entry.commonName)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("\(cluster.all.count) birds")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    MapView()
        .environment(LifeListStore())
}
