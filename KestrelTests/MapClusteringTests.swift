import CoreLocation
import Foundation
import MapKit
import Testing
@testable import Kestrel

/// Map clustering and the cluster model.
///
/// The determinism here matters more than it looks: `Dictionary.values` is
/// unordered and `sorted(by:)` isn't guaranteed stable on equal keys, so without
/// explicit tiebreakers a cluster card could shuffle its birds between
/// recomputations — including between the moment the user taps a thumbnail and
/// the moment the full-screen viewer opens over it, which would show them a
/// different bird than the one they tapped.
@Suite("Map clustering")
struct MapClusteringTests {

    private let may4 = utcDay(2026, 5, 4)
    private let may5 = utcDay(2026, 5, 5)
    private let may6 = utcDay(2026, 5, 6)

    private func point(
        _ id: String, _ sci: String, _ date: Date,
        lat: Double, lon: Double, place: String? = "P"
    ) -> MapPoint {
        MapPoint(id: id, scientificName: sci, commonName: sci, date: date,
                 location: place, latitude: lat, longitude: lon)
    }

    private let viewSize = CGSize(width: 400, height: 800)
    private let footprint = CGSize(width: 110, height: 102)

    private func cluster(
        _ points: [MapPoint],
        span: MKCoordinateSpan = MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    ) -> [BirdCluster] {
        MapView.computeClusters(
            points: points, span: span, centerLatitude: 42,
            viewSize: viewSize, footprint: footprint, gutter: 4
        )
    }

    // MARK: computeClusters

    @Test("points far apart stay separate")
    func distantPointsSeparate() {
        let clusters = cluster([
            point("a", "A a", may4, lat: 42.0, lon: -76.0),
            point("b", "B b", may4, lat: 43.0, lon: -77.0),
        ])
        #expect(clusters.count == 2)
        #expect(clusters.allSatisfy { $0.others.isEmpty })
    }

    @Test("points at the same spot fold into one stack")
    func coincidentPointsFold() {
        let clusters = cluster([
            point("a", "A a", may4, lat: 42.0, lon: -76.0),
            point("b", "B b", may5, lat: 42.0, lon: -76.0),
            point("c", "C c", may6, lat: 42.0, lon: -76.0),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].all.count == 3)
    }

    /// Zooming in has to split a stack apart, or the map would never resolve.
    @Test("zooming in separates points that were folded")
    func zoomSeparates() {
        let points = [
            point("a", "A a", may4, lat: 42.0000, lon: -76.0),
            point("b", "B b", may4, lat: 42.0100, lon: -76.0),
        ]
        let zoomedOut = cluster(points, span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0))
        let zoomedIn = cluster(points, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        #expect(zoomedOut.count == 1)
        #expect(zoomedIn.count == 2)
    }

    /// The representative each stack folds onto — and therefore the stack's own
    /// identity — must not depend on the input array's incidental order.
    @Test("clustering is independent of input order")
    func clusteringDeterministic() {
        let points = (0..<12).map { i in
            point("p\(i)", "Genus sp\(String(format: "%02d", i))", may4,
                  lat: 42.0 + Double(i % 3) * 0.5, lon: -76.0)
        }
        let reference = cluster(points).map(\.id).sorted()
        for _ in 0..<8 {
            #expect(cluster(points.shuffled()).map(\.id).sorted() == reference)
        }
    }

    /// Every point must land in exactly one cluster — none dropped, none doubled.
    @Test("clustering partitions the points")
    func clusteringIsAPartition() {
        let points = (0..<25).map { i in
            point("p\(i)", "Genus sp\(i)", may4,
                  lat: 42.0 + Double(i) * 0.02, lon: -76.0 + Double(i % 4) * 0.02)
        }
        let clusters = cluster(points)
        let covered = clusters.flatMap { $0.all.map(\.id) }
        #expect(covered.count == points.count)
        #expect(Set(covered) == Set(points.map(\.id)))
    }

    @Test("degenerate inputs produce no clusters rather than crashing")
    func degenerateInputs() {
        #expect(cluster([]).isEmpty)
        #expect(MapView.computeClusters(
            points: [point("a", "A a", may4, lat: 42, lon: -76)],
            span: MKCoordinateSpan(latitudeDelta: 0, longitudeDelta: 0),
            centerLatitude: 42, viewSize: viewSize, footprint: footprint, gutter: 4
        ).isEmpty)
        #expect(MapView.computeClusters(
            points: [point("a", "A a", may4, lat: 42, lon: -76)],
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1),
            centerLatitude: 42, viewSize: .zero, footprint: footprint, gutter: 4
        ).isEmpty)
    }

    /// Longitude degrees shrink toward the poles, so the horizontal threshold has
    /// to widen with latitude or high-latitude pins would never cluster.
    @Test("the longitude threshold widens toward the poles")
    func longitudeThresholdScalesWithLatitude() {
        let points = [
            point("a", "A a", may4, lat: 70.0, lon: -76.00),
            point("b", "B b", may4, lat: 70.0, lon: -75.90),
        ]
        let span = MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        let atEquator = MapView.computeClusters(
            points: points, span: span, centerLatitude: 0,
            viewSize: viewSize, footprint: footprint, gutter: 4
        )
        let atPolarLatitude = MapView.computeClusters(
            points: points, span: span, centerLatitude: 70,
            viewSize: viewSize, footprint: footprint, gutter: 4
        )
        #expect(atEquator.count >= atPolarLatitude.count,
                "the same longitude gap is a shorter distance at 70°N")
    }

    // MARK: the spatial hash

    /// The pairwise scan `computeClusters` used to be: fold each point onto the
    /// first representative found so far that is within the threshold.
    ///
    /// The spatial hash that replaced it has to give the *identical* answer, not
    /// merely a similar one — the representative a stack folds onto is the
    /// stack's identity, which is what the tap handler, the card and the
    /// full-screen viewer all key off.
    private func referenceClusters(
        _ points: [MapPoint],
        span: MKCoordinateSpan,
        centerLatitude: Double
    ) -> [BirdCluster] {
        let degPerPoint = span.latitudeDelta / Double(viewSize.height)
        let thresholdLat = degPerPoint * Double(footprint.height + 4)
        let cosLat = max(cos(centerLatitude * .pi / 180), 0.05)
        let thresholdLon = (degPerPoint * Double(footprint.width + 4)) / cosLat

        struct WIP {
            let point: MapPoint
            var others: [MapPoint] = []
        }
        var reps: [WIP] = []
        for point in points.sorted(by: BirdCluster.ordersBefore) {
            var folded = false
            for i in reps.indices {
                if abs(reps[i].point.latitude - point.latitude) < thresholdLat
                    && abs(reps[i].point.longitude - point.longitude) < thresholdLon {
                    reps[i].others.append(point)
                    folded = true
                    break
                }
            }
            if !folded { reps.append(WIP(point: point)) }
        }
        return reps.map {
            BirdCluster(
                representative: $0.point,
                coordinate: $0.point.coordinate,
                others: $0.others
            )
        }
    }

    /// A deterministic pseudo-random spread, so the two implementations are
    /// compared on messy input rather than on a tidy grid — and on the same messy
    /// input every run.
    private func scatter(_ count: Int, seed: UInt64 = 0x5eed) -> [MapPoint] {
        var state = seed
        func next() -> Double {
            // xorshift64*, inline so the test carries no dependency.
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return Double((state &* 2_685_821_657_736_338_717) >> 11) / Double(1 << 53)
        }
        return (0..<count).map { i in
            point("p\(i)", "Genus sp\(i % 40)", [may4, may5, may6][i % 3],
                  lat: 42.0 + next() * 0.4, lon: -76.0 + next() * 0.4)
        }
    }

    @Test("the spatial hash agrees with a pairwise scan, at every zoom")
    func gridMatchesPairwise() {
        let points = scatter(400)
        for delta in [2.0, 0.5, 0.1, 0.02, 0.004, 0.0005] {
            let span = MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
            let actual = cluster(points, span: span)
            let expected = referenceClusters(points, span: span, centerLatitude: 42)

            #expect(actual.map(\.representative.id) == expected.map(\.representative.id),
                    "representatives differ at span \(delta)")
            #expect(actual.map { $0.others.map(\.id) } == expected.map { $0.others.map(\.id) },
                    "stack membership differs at span \(delta)")
        }
    }

    /// When a point sits within the threshold of two representatives, the pairwise
    /// scan takes the one it met first. The hash checks nine cells in an order of
    /// its own, so it has to pick the lowest index among the candidates rather
    /// than the first one it happens to find.
    @Test("a point between two stacks joins the earlier one")
    func foldsOntoTheEarlierRepresentative() {
        // Sorted newest first, so "b" is the first representative and "a" the
        // second; "middle" is within reach of both.
        let span = MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        let threshold = (span.latitudeDelta / Double(viewSize.height)) * Double(footprint.height + 4)
        let points = [
            point("b", "B b", may6, lat: 42.0, lon: -76.0),
            point("a", "A a", may5, lat: 42.0 + threshold * 1.5, lon: -76.0),
            point("middle", "M m", may4, lat: 42.0 + threshold * 0.75, lon: -76.0),
        ]
        let clusters = cluster(points, span: span)
        let expected = referenceClusters(points, span: span, centerLatitude: 42)
        #expect(clusters.map(\.representative.id) == expected.map(\.representative.id))
        let holder = clusters.first { $0.others.contains { $0.id == "middle" } }
        #expect(holder?.representative.id == "b", "the first representative wins the tie")
    }

    /// eBird's "My eBird Data" export is one row per *observation*, so an active
    /// birder's import is tens of thousands of pins — and this runs synchronously
    /// on the main actor on every zoom-step settle. The pairwise scan was O(n²)
    /// and degenerated exactly where it hurts: at high zoom nearly every point is
    /// its own representative, so each new one scanned the whole list.
    ///
    /// The bound is deliberately loose. It is not a benchmark; it is there to fail
    /// if the quadratic behavior ever comes back, which at this size is the
    /// difference between milliseconds and minutes.
    @Test("clustering a large imported life list stays interactive")
    func scalesToALargeLifeList() {
        let points = scatter(20_000)
        // A high zoom, where almost nothing folds — the pairwise worst case.
        let span = MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)

        let started = Date()
        let clusters = cluster(points, span: span)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 2.0, "took \(elapsed)s — the quadratic scan is back")
        // Still a partition: every point accounted for, exactly once.
        let covered = clusters.flatMap { $0.all.map(\.id) }
        #expect(covered.count == points.count)
        #expect(Set(covered).count == points.count)
    }

    @Test("a degenerate threshold leaves every point standing alone")
    func zeroFootprintDoesNotFold() {
        // Nothing can be within a zero-width threshold — and the spatial hash
        // must not divide by it.
        let points = scatter(50)
        let clusters = MapView.computeClusters(
            points: points, span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1),
            centerLatitude: 42, viewSize: viewSize, footprint: .zero, gutter: 0
        )
        #expect(clusters.count == points.count)
        #expect(clusters.allSatisfy { $0.others.isEmpty })
    }

    // MARK: uniqueByEarliest

    /// A cluster can hold several sightings of the same bird; the card shows one
    /// thumbnail each, carrying the date and place of the *first* time that bird
    /// was seen here — matching how the rest of the app treats a first sighting.
    @Test("repeat sightings of one bird collapse to its earliest")
    func uniqueByEarliestPicksEarliest() {
        let cluster = BirdCluster(
            representative: point("x#2", "X y", may6, lat: 42, lon: -76, place: "Third"),
            coordinate: CLLocationCoordinate2D(latitude: 42, longitude: -76),
            others: [
                point("x", "X y", may4, lat: 42, lon: -76, place: "First"),
                point("x#1", "X y", may5, lat: 42, lon: -76, place: "Second"),
            ]
        )
        let unique = cluster.uniqueByEarliest
        #expect(unique.count == 1)
        #expect(unique[0].date == may4)
        #expect(unique[0].location == "First")
    }

    /// Ties go to the lower id, which is the life-list entry's own first sighting
    /// (`scientificName`) rather than one of its repeats (`scientificName#i`).
    @Test("an exact date tie keeps the canonical point")
    func uniqueByEarliestTieBreak() {
        let cluster = BirdCluster(
            representative: point("X y#3", "X y", may4, lat: 42, lon: -76, place: "Repeat"),
            coordinate: CLLocationCoordinate2D(latitude: 42, longitude: -76),
            others: [point("X y", "X y", may4, lat: 42, lon: -76, place: "Canonical")]
        )
        #expect(cluster.uniqueByEarliest[0].location == "Canonical")
    }

    @Test("several species each keep their own earliest")
    func uniqueByEarliestPerSpecies() {
        let cluster = BirdCluster(
            representative: point("a#1", "A a", may6, lat: 42, lon: -76),
            coordinate: CLLocationCoordinate2D(latitude: 42, longitude: -76),
            others: [
                point("a", "A a", may4, lat: 42, lon: -76),
                point("b", "B b", may5, lat: 42, lon: -76),
                point("b#1", "B b", may6, lat: 42, lon: -76),
            ]
        )
        let unique = cluster.uniqueByEarliest
        #expect(unique.count == 2)
        #expect(unique.first { $0.scientificName == "A a" }?.date == may4)
        #expect(unique.first { $0.scientificName == "B b" }?.date == may5)
    }

    /// Without the tiebreakers this is where the shuffle showed: several species
    /// logged in one checklist share an exact timestamp.
    @Test("birds sharing an exact date always come back in the same order")
    func uniqueByEarliestIsStable() {
        let points = (0..<20).map { i in
            point("p\(i)", "Genus sp\(String(format: "%02d", i))", may4, lat: 42, lon: -76)
        }
        func order(_ input: [MapPoint]) -> [String] {
            BirdCluster(
                representative: input[0],
                coordinate: CLLocationCoordinate2D(latitude: 42, longitude: -76),
                others: Array(input.dropFirst())
            ).uniqueByEarliest.map(\.id)
        }
        let reference = order(points)
        for _ in 0..<10 {
            #expect(order(points.shuffled()) == reference)
        }
    }

    @Test("the card lists birds newest first")
    func uniqueByEarliestNewestFirst() {
        let cluster = BirdCluster(
            representative: point("c", "C c", may6, lat: 42, lon: -76),
            coordinate: CLLocationCoordinate2D(latitude: 42, longitude: -76),
            others: [
                point("a", "A a", may4, lat: 42, lon: -76),
                point("b", "B b", may5, lat: 42, lon: -76),
            ]
        )
        #expect(cluster.uniqueByEarliest.map(\.scientificName) == ["C c", "B b", "A a"])
    }

    // MARK: sightings(of:)

    /// A thumbnail that stands for several sightings can't act on its
    /// representative alone — that would quietly touch only one of them and leave
    /// the pin looking untouched. This is the list its menu asks over.
    @Test("sightings(of:) returns every pinned sighting of one species")
    func sightingsOfSpecies() {
        let cluster = BirdCluster(
            representative: point("x#1", "X y", may5, lat: 42, lon: -76, place: "B"),
            coordinate: CLLocationCoordinate2D(latitude: 42, longitude: -76),
            others: [
                point("x", "X y", may4, lat: 42, lon: -76, place: "A"),
                point("other", "Other o", may4, lat: 42, lon: -76, place: "C"),
            ]
        )
        let sightings = cluster.sightings(of: "X y")
        #expect(sightings.count == 2)
        #expect(Set(sightings.compactMap(\.location)) == ["A", "B"])
        #expect(cluster.sightings(of: "Other o").count == 1)
        #expect(cluster.sightings(of: "Not here").isEmpty)
    }

    /// The point's observation must round-trip to an identity the store can match,
    /// or Edit and Delete from a pin would silently do nothing.
    @Test("a map point's observation carries the fields identity needs")
    func pointObservationMatchesStore() {
        let p = point("x", "X y", may4, lat: 42.4534198, lon: -76.4735178, place: "Ithaca, NY")
        let stored = LifeListEntry.Observation.at(may4, "Ithaca, NY", lat: 42.4534198, lon: -76.4735178)
        #expect(p.observation.identity == stored.identity)
    }

    /// A pin's edit and delete resolve the stored record *by value* first, so a
    /// point has to reconstitute the whole observation — provenance included.
    /// `Identity` excludes `isImported` and so can't tell two colliding sightings
    /// apart; falling back to it picks whichever came first, which is not
    /// necessarily the pin the user long-pressed. See `LifeListStore.locate`.
    @Test("a map point's observation carries the stored record exactly")
    func pointObservationCarriesProvenance() {
        let stored = LifeListEntry.Observation.at(
            may4, "Ithaca NY", lat: 42.45342, lon: -76.47352, imported: true
        )
        let entry = LifeListEntry.make("X y", "X", [stored])
        let p = MapPoint(
            id: "x", scientificName: "X y", commonName: "X",
            date: entry.firstSeen, location: entry.firstLocation,
            latitude: entry.firstLatitude!, longitude: entry.firstLongitude!,
            isImported: entry.firstIsImported
        )
        #expect(p.observation == stored, "not merely identity-equal — the same record")
    }

    // MARK: ordering

    @Test("BirdCluster.ordersBefore is deterministic on every tie")
    func clusterOrdering() {
        let a = point("a", "A a", may4, lat: 42, lon: -76)
        let b = point("b", "B b", may4, lat: 42, lon: -76)
        let newer = point("c", "A a", may5, lat: 42, lon: -76)
        #expect(BirdCluster.ordersBefore(newer, a), "newer first")
        #expect(BirdCluster.ordersBefore(a, b), "then scientific name")
        #expect(!BirdCluster.ordersBefore(a, a), "irreflexive")

        let sameSpecies1 = point("x", "X y", may4, lat: 42, lon: -76)
        let sameSpecies2 = point("x#1", "X y", may4, lat: 42, lon: -76)
        #expect(BirdCluster.ordersBefore(sameSpecies1, sameSpecies2), "then point id")
    }

    @Test("cluster identity is its representative plus its members")
    func clusterEquality() {
        let rep = point("a", "A a", may4, lat: 42, lon: -76)
        let other = point("b", "B b", may4, lat: 42, lon: -76)
        let coord = CLLocationCoordinate2D(latitude: 42, longitude: -76)
        let one = BirdCluster(representative: rep, coordinate: coord, others: [other])
        let same = BirdCluster(representative: rep, coordinate: coord, others: [other])
        let different = BirdCluster(representative: rep, coordinate: coord, others: [])
        #expect(one == same)
        #expect(one.hashValue == same.hashValue)
        #expect(one != different)
    }

    // MARK: an edit has to be visible through equality

    /// **The failure both of this file's `==` operators exist to prevent.**
    ///
    /// `RepInfo` and `BirdCluster` are hand-written `Equatable` only because
    /// `CLLocationCoordinate2D` isn't. Both used to settle for comparing
    /// `MapPoint.id`s — and an id is `"<species>"` or `"<species>#<index>"`,
    /// which does *not* move when the sighting behind it is edited. So the two
    /// "nothing changed, skip the write" guards that read these operators
    /// (`rebuildClusters`' `next != visibleReps`, and `recomposeOpenCard`'s
    /// `recomposed != open`) took an edit for a no-op and left the map holding
    /// the pre-edit record.
    ///
    /// What the user saw: editing a lone pin's date, then opening its menu again,
    /// re-opened the flow on the *old* date — and confirming that resolved to
    /// nothing in `LifeListStore.locate` (identity is made of exactly the fields
    /// the first edit had rewritten) and silently wrote nothing at all. The photo
    /// the pin opened captioned itself with the old place and date for the same
    /// reason.
    ///
    /// Every field is checked one at a time, because it only takes one of them
    /// slipping out of the comparison to reopen this.
    @Test("an edited sighting is not equal to the one it replaced", arguments: [
        "date", "place", "latitude", "longitude", "provenance",
    ])
    func editedPointBreaksEquality(_ field: String) {
        let before = MapPoint(
            id: "X y", scientificName: "X y", commonName: "X",
            date: may4, location: "Ithaca NY",
            latitude: 42.45342, longitude: -76.47352, isImported: false
        )
        var after = before
        switch field {
        case "date":       after = copy(before, date: may5)
        case "place":      after = copy(before, location: "Sapsucker Woods")
        case "latitude":   after = copy(before, latitude: 42.5)
        case "longitude":  after = copy(before, longitude: -76.5)
        default:           after = copy(before, isImported: true)
        }

        #expect(after.id == before.id, "the id deliberately doesn't move — that's the trap")

        let coord = CLLocationCoordinate2D(latitude: 42, longitude: -76)
        #expect(
            MapView.RepInfo(count: 1, coordinate: coord, representative: before, others: [])
                != MapView.RepInfo(count: 1, coordinate: coord, representative: after, others: []),
            "\(field) changed, so the annotation's rep info must be rewritten"
        )
        #expect(
            BirdCluster(representative: before, coordinate: coord, others: [])
                != BirdCluster(representative: after, coordinate: coord, others: []),
            "\(field) changed, so an open card must be re-pointed"
        )
    }

    /// The same, for a sighting that isn't the stack's representative — a card's
    /// grid cell acts on `others` just as directly as on the rep.
    @Test("an edit to a non-representative member also breaks equality")
    func editedMemberBreaksEquality() {
        let rep = point("A a", "A a", may5, lat: 42, lon: -76)
        let before = point("B b", "B b", may4, lat: 42, lon: -76, place: "Ithaca NY")
        let after = copy(before, location: "Sapsucker Woods")
        let coord = CLLocationCoordinate2D(latitude: 42, longitude: -76)

        #expect(
            MapView.RepInfo(count: 2, coordinate: coord, representative: rep, others: [before])
                != MapView.RepInfo(count: 2, coordinate: coord, representative: rep, others: [after])
        )
        #expect(
            BirdCluster(representative: rep, coordinate: coord, others: [before])
                != BirdCluster(representative: rep, coordinate: coord, others: [after])
        )
    }

    /// The cluster's own coordinate took part in neither operator, so a stack
    /// that moved while keeping its members — the pin's sighting re-pinned
    /// somewhere else — compared equal to where it used to be. That coordinate is
    /// what `handleAnnotationTap` hands the card it opens.
    @Test("a stack that moved is not equal to where it was")
    func movedStackBreaksEquality() {
        let rep = point("A a", "A a", may4, lat: 42, lon: -76)
        let here = CLLocationCoordinate2D(latitude: 42, longitude: -76)
        let there = CLLocationCoordinate2D(latitude: 43, longitude: -77)

        #expect(
            MapView.RepInfo(count: 1, coordinate: here, representative: rep, others: [])
                != MapView.RepInfo(count: 1, coordinate: there, representative: rep, others: [])
        )
        #expect(
            BirdCluster(representative: rep, coordinate: here, others: [])
                != BirdCluster(representative: rep, coordinate: there, others: [])
        )
    }

    /// Equality still has to be *true* for genuinely unchanged input, or the
    /// guards stop guarding: every camera settle would rewrite `visibleReps` and
    /// re-point an open card under a user who was only panning.
    @Test("an unchanged stack still compares equal, and still hashes equal")
    func unchangedStackStaysEqual() {
        let rep = point("A a", "A a", may4, lat: 42, lon: -76)
        let other = point("B b", "B b", may5, lat: 42, lon: -76)
        let coord = CLLocationCoordinate2D(latitude: 42, longitude: -76)

        let a = BirdCluster(representative: rep, coordinate: coord, others: [other])
        let b = BirdCluster(representative: rep, coordinate: coord, others: [other])
        #expect(a == b)
        #expect(a.hashValue == b.hashValue, "Hashable's own requirement")
        #expect(
            MapView.RepInfo(count: 2, coordinate: coord, representative: rep, others: [other])
                == MapView.RepInfo(count: 2, coordinate: coord, representative: rep, others: [other])
        )
    }

    /// `MapPoint` is a `let`-only value type, so an "edit" is a rebuild. Spelled
    /// out once here rather than at each call site above.
    private func copy(
        _ p: MapPoint,
        date: Date? = nil,
        location: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        isImported: Bool? = nil
    ) -> MapPoint {
        MapPoint(
            id: p.id,
            scientificName: p.scientificName,
            commonName: p.commonName,
            date: date ?? p.date,
            location: location ?? p.location,
            latitude: latitude ?? p.latitude,
            longitude: longitude ?? p.longitude,
            isImported: isImported ?? p.isImported
        )
    }

    // MARK: re-pointing an open card

    /// The map's bottom card used to hold the `BirdCluster` captured at tap time
    /// and never hear about the store again, so a sighting deleted from a grid
    /// cell's own menu left its thumbnail sitting in the grid — a ghost whose tap
    /// opened a viewer over a record that no longer existed, and whose edit
    /// silently did nothing. `recomposedCluster` is what re-points the card at
    /// the stack as it now stands.

    /// A write renumbers the edited species' points (`MapPoint.id` embeds an
    /// index into `otherObservations`, and `LifeListEntry.make` re-sorts on every
    /// write) and can hand the stack a different representative — so neither the
    /// coordinate nor `BirdCluster.id` survives. The *other* species in the stack
    /// keep their ids, and a card only ever opens over two or more.
    @Test("a card re-points to the stack that kept most of its points")
    func recomposeFollowsSharedPoints() throws {
        let a = point("A a", "A a", may4, lat: 42, lon: -76)
        let b = point("B b", "B b", may5, lat: 42, lon: -76)
        let open = BirdCluster(representative: b, coordinate: b.coordinate, others: [a])

        // "A a" was edited: renumbered, and now the stack's representative.
        let editedA = point("A a#1", "A a", may6, lat: 42, lon: -76)
        let after = BirdCluster(
            representative: editedA, coordinate: editedA.coordinate, others: [b]
        )
        let elsewhere = BirdCluster(
            representative: point("C c", "C c", may4, lat: 10, lon: 10),
            coordinate: CLLocationCoordinate2D(latitude: 10, longitude: 10),
            others: []
        )

        let recomposed = try #require(
            MapView.recomposedCluster(for: open, in: [elsewhere, after])
        )
        #expect(recomposed == after)
    }

    /// A delete that leaves the rest of the stack standing keeps the card open,
    /// pointed at what's left.
    @Test("a card survives one of its birds being deleted")
    func recomposeSurvivesADelete() throws {
        let a = point("A a", "A a", may4, lat: 42, lon: -76)
        let b = point("B b", "B b", may5, lat: 42, lon: -76)
        let open = BirdCluster(representative: b, coordinate: b.coordinate, others: [a])
        let after = BirdCluster(representative: b, coordinate: b.coordinate, others: [])

        let recomposed = try #require(MapView.recomposedCluster(for: open, in: [after]))
        #expect(recomposed == after)
        #expect(recomposed.all.count == 1, "the deleted bird is gone from the grid")
    }

    /// Nothing the card was showing is pinned here any more — every sighting in
    /// it was deleted or moved away. The caller closes the card.
    @Test("a card with nothing left recomposes to nil")
    func recomposeToNilWhenEmptied() {
        let a = point("A a", "A a", may4, lat: 42, lon: -76)
        let b = point("B b", "B b", may5, lat: 42, lon: -76)
        let open = BirdCluster(representative: b, coordinate: b.coordinate, others: [a])

        #expect(MapView.recomposedCluster(for: open, in: []) == nil)
        let unrelated = BirdCluster(
            representative: point("C c", "C c", may4, lat: 42, lon: -76),
            coordinate: CLLocationCoordinate2D(latitude: 42, longitude: -76),
            others: []
        )
        #expect(MapView.recomposedCluster(for: open, in: [unrelated]) == nil)
    }

    /// An untouched card must recompose to exactly itself, or every unrelated
    /// life-list write would churn the open card's contents.
    @Test("an unaffected card recomposes to itself")
    func recomposeIsStableWhenNothingChanged() throws {
        let a = point("A a", "A a", may4, lat: 42, lon: -76)
        let b = point("B b", "B b", may5, lat: 42, lon: -76)
        let open = BirdCluster(representative: b, coordinate: b.coordinate, others: [a])
        let elsewhere = BirdCluster(
            representative: point("C c", "C c", may4, lat: 10, lon: 10),
            coordinate: CLLocationCoordinate2D(latitude: 10, longitude: 10),
            others: []
        )

        let recomposed = try #require(
            MapView.recomposedCluster(for: open, in: [open, elsewhere])
        )
        #expect(recomposed == open)
    }

    /// If a stack splits, the card follows the larger half rather than picking
    /// whichever the clustering happened to return first.
    @Test("a split stack re-points to the half holding more of the card")
    func recomposePrefersTheLargerOverlap() throws {
        let a = point("A a", "A a", may4, lat: 42, lon: -76)
        let b = point("B b", "B b", may5, lat: 42, lon: -76)
        let c = point("C c", "C c", may6, lat: 42, lon: -76)
        let open = BirdCluster(representative: c, coordinate: c.coordinate, others: [a, b])

        let smaller = BirdCluster(representative: c, coordinate: c.coordinate, others: [])
        let larger = BirdCluster(representative: b, coordinate: b.coordinate, others: [a])

        let recomposed = try #require(
            MapView.recomposedCluster(for: open, in: [smaller, larger])
        )
        #expect(recomposed == larger)
    }


    // MARK: the date line

    /// Longitude is periodic and the app stores it in [-180, 180], so a raw
    /// subtraction calls two pins a fifth of a degree apart on either side of the
    /// date line 359.8° apart. Both the viewport cull and the clustering used to
    /// do exactly that: pins vanished on the far side of the line, and a stack
    /// straddling it never formed.

    @Test("wrapped longitude distance goes the short way round")
    func longitudeDistanceWraps() {
        #expect(MapView.longitudeDistance(179.9, -179.9).isApproximately(0.2))
        #expect(MapView.longitudeDistance(-179.9, 179.9).isApproximately(0.2))
        #expect(MapView.longitudeDistance(10, 12).isApproximately(2))
        #expect(MapView.longitudeDistance(-76, -76).isApproximately(0))
        #expect(MapView.longitudeDistance(0, 180).isApproximately(180),
                "the antipode is the farthest two longitudes can be")
    }

    @Test("unwrapping puts a longitude in a continuous frame around the camera")
    func unwrappingIsContinuousNearTheCamera() {
        // A camera on the date line sees -179.9 as just past +180, not a world away.
        #expect(MapView.unwrappedLongitude(-179.9, near: 179.9).isApproximately(180.1))
        #expect(MapView.unwrappedLongitude(179.9, near: -179.9).isApproximately(-180.1))
        // Away from the seam it changes nothing.
        #expect(MapView.unwrappedLongitude(-76, near: -76.5).isApproximately(-76))
        #expect(MapView.unwrappedLongitude(10, near: 0).isApproximately(10))
    }

    /// The clustering frame is centered on the camera, so a stack straddling the
    /// date line folds exactly as it would anywhere else.
    @Test("points either side of the date line cluster together")
    func straddlingPointsCluster() {
        let clusters = MapView.computeClusters(
            points: [
                point("a", "A a", may4, lat: 42.0, lon: 179.999),
                point("b", "B b", may5, lat: 42.0, lon: -179.999),
            ],
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1),
            centerLatitude: 42,
            centerLongitude: 180,
            viewSize: viewSize, footprint: footprint, gutter: 4
        )
        #expect(clusters.count == 1)
        #expect(clusters.first?.all.count == 2)
    }

    /// …and a stack that folds there still publishes its representative's real
    /// coordinate, not the shifted one the cell math ran on — the card and
    /// `sameCoordinate` would otherwise be a whole turn out.
    @Test("a stack near the date line keeps its true coordinate")
    func straddlingClusterKeepsRealCoordinate() throws {
        let clusters = MapView.computeClusters(
            points: [
                point("a", "A a", may4, lat: 42.0, lon: -179.999),
                point("b", "B b", may5, lat: 42.0, lon: 179.999),
            ],
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1),
            centerLatitude: 42,
            centerLongitude: -180,
            viewSize: viewSize, footprint: footprint, gutter: 4
        )
        let cluster = try #require(clusters.first)
        #expect(cluster.coordinate.longitude == cluster.representative.longitude)
        #expect(abs(cluster.coordinate.longitude) <= 180)
    }

    /// Genuinely distant points are still distant — the wrap must not fold the
    /// whole world into one stack.
    @Test("the wrap doesn't collapse genuinely distant points")
    func wrapDoesNotOverCluster() {
        let clusters = MapView.computeClusters(
            points: [
                point("a", "A a", may4, lat: 42.0, lon: 179.9),
                point("b", "B b", may5, lat: 42.0, lon: 100.0),
            ],
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1),
            centerLatitude: 42,
            centerLongitude: 180,
            viewSize: viewSize, footprint: footprint, gutter: 4
        )
        #expect(clusters.count == 2)
    }

    /// Away from the seam the camera's longitude changes nothing, which is what
    /// lets every other test in this suite leave it defaulted.
    @Test("clustering away from the date line ignores the camera longitude")
    func cameraLongitudeIsInertAwayFromTheSeam() {
        let points = [
            point("a", "A a", may4, lat: 42.0, lon: -76.0),
            point("b", "B b", may5, lat: 42.0, lon: -76.0),
            point("c", "C c", may6, lat: 43.0, lon: -77.0),
        ]
        let span = MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        let defaulted = MapView.computeClusters(
            points: points, span: span, centerLatitude: 42,
            viewSize: viewSize, footprint: footprint, gutter: 4
        )
        let centered = MapView.computeClusters(
            points: points, span: span, centerLatitude: 42, centerLongitude: -76,
            viewSize: viewSize, footprint: footprint, gutter: 4
        )
        #expect(defaulted.map(\.id) == centered.map(\.id))
        #expect(defaulted.map { $0.all.count } == centered.map { $0.all.count })
    }
}

private extension Double {
    /// Degrees compare to within a hair; these are exact-in-principle values
    /// arrived at by subtraction.
    func isApproximately(_ other: Double, tolerance: Double = 1e-9) -> Bool {
        abs(self - other) < tolerance
    }
}

