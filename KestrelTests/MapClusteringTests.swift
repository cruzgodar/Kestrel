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
}
