import CoreLocation
import MapKit
import UIKit

/// "Find Nearby Sightings": eBird's species map for one bird, zoomed to the
/// ground around the user and filtered to this time of year — the website's
/// nearest equivalent to the eBird app's list of places a species has been
/// seen nearby, which the website doesn't have.
///
/// The link is to `ebird.org/map/<code>`, which eBird only shows to a signed-in
/// user; anyone else is sent to its sign-in page first.
enum NearbySightings {
    static let title = "Find Nearby Sightings"
    /// A square with an arrow leaving it: the link opens outside the app.
    static let systemImage = "arrow.up.forward.app"

    /// How far the map reaches from the user in every direction: five miles.
    nonisolated static let radius: CLLocationDistance = 5 * 1_609.344

    /// For this many days into a month the map takes in the month before as
    /// well, so it isn't showing next to nothing on the 1st.
    nonisolated static let carryOverDays = 5

    /// Opens the map for a bird in the browser (or the eBird app, if it takes
    /// the link). Does nothing for a bird with no eBird code.
    static func open(scientificName: String, commonName: String?) {
        guard let code = SpeciesCatalog.shared.eBirdCode(
            scientificName: scientificName,
            commonName: commonName
        ) else { return }
        Task {
            let center = await whereTheUserIs()
            guard let url = url(code: code, center: center) else { return }
            await UIApplication.shared.open(url)
        }
    }

    /// The map's address. Centred on `center` with `radius` of ground on every
    /// side; without a centre, eBird picks the view. eBird only holds the box
    /// when there are sightings in it for the months asked about — for a bird
    /// that hasn't arrived yet it zooms out to fit the ones it has, and no
    /// parameter stops that.
    ///
    /// The months run from this one back to the last when it's early in the
    /// month. `yr=cur` is "the current season" rather than the calendar year:
    /// in early January, `bmo=12&emo=1&yr=cur` is last December through this
    /// January.
    nonisolated static func url(
        code: String,
        center: CLLocationCoordinate2D?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "ebird.org"
        components.path = "/map/\(code)"

        var items: [URLQueryItem] = []
        if let center {
            let span = MKCoordinateRegion(
                center: center,
                latitudinalMeters: 2 * radius,
                longitudinalMeters: 2 * radius
            ).span
            items += [
                URLQueryItem(name: "env.minX", value: degrees(center.longitude - span.longitudeDelta / 2)),
                URLQueryItem(name: "env.minY", value: degrees(center.latitude - span.latitudeDelta / 2)),
                URLQueryItem(name: "env.maxX", value: degrees(center.longitude + span.longitudeDelta / 2)),
                URLQueryItem(name: "env.maxY", value: degrees(center.latitude + span.latitudeDelta / 2)),
            ]
        }
        let months = self.months(now: now, calendar: calendar)
        items += [
            URLQueryItem(name: "bmo", value: String(months.begin)),
            URLQueryItem(name: "emo", value: String(months.end)),
            URLQueryItem(name: "yr", value: "cur"),
        ]
        components.queryItems = items
        return components.url
    }

    /// The first and last month the map shows, 1–12.
    nonisolated static func months(now: Date, calendar: Calendar) -> (begin: Int, end: Int) {
        let month = calendar.component(.month, from: now)
        guard calendar.component(.day, from: now) <= carryOverDays else { return (month, month) }
        return (month == 1 ? 12 : month - 1, month)
    }

    private nonisolated static func degrees(_ value: CLLocationDegrees) -> String {
        String(format: "%.6f", value)
    }

    /// A fresh fix when access has been granted, and otherwise the last place
    /// the user is known to have been. Never prompts.
    private static func whereTheUserIs() async -> CLLocationCoordinate2D? {
        let status = CLLocationManager().authorizationStatus
        let fix = status == .authorizedWhenInUse || status == .authorizedAlways
            ? await LocationCache.shared.current()
            : nil
        guard let known = fix
            ?? LocationCache.shared.lastCoordinate
            ?? SpeciesRangeFilter.cachedCoordinate()
        else { return nil }
        return CLLocationCoordinate2D(latitude: known.latitude, longitude: known.longitude)
    }
}
