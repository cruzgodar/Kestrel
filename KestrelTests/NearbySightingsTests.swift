import CoreLocation
import Foundation
import Testing
@testable import Kestrel

struct NearbySightingsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test("the first five days of a month take in the month before")
    func carriesOverEarlyInTheMonth() {
        #expect(NearbySightings.months(now: date(2026, 10, 1), calendar: calendar) == (9, 10))
        #expect(NearbySightings.months(now: date(2026, 10, 5), calendar: calendar) == (9, 10))
        #expect(NearbySightings.months(now: date(2026, 10, 6), calendar: calendar) == (10, 10))
    }

    @Test("early January reaches back to December")
    func wrapsIntoDecember() {
        #expect(NearbySightings.months(now: date(2026, 1, 3), calendar: calendar) == (12, 1))
    }

    @Test("the map is centred on the user and reaches five miles each way")
    func boundingBox() throws {
        let center = CLLocationCoordinate2D(latitude: 42.48, longitude: -76.45)
        let url = try #require(NearbySightings.url(
            code: "carwre", center: center, now: date(2026, 10, 9), calendar: calendar
        ))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) throws -> Double {
            let text = items.first { $0.name == name }?.value ?? ""
            return try #require(Double(text))
        }
        #expect(url.path == "/map/carwre")
        let minY = try value("env.minY"), maxY = try value("env.maxY")
        let minX = try value("env.minX"), maxX = try value("env.maxX")
        #expect(abs((minY + maxY) / 2 - center.latitude) < 1e-5)
        #expect(abs((minX + maxX) / 2 - center.longitude) < 1e-5)
        let north = CLLocation(latitude: maxY, longitude: center.longitude)
        let east = CLLocation(latitude: center.latitude, longitude: maxX)
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        #expect(abs(here.distance(from: north) - NearbySightings.radius) < 50)
        #expect(abs(here.distance(from: east) - NearbySightings.radius) < 50)
        #expect(items.first { $0.name == "bmo" }?.value == "10")
        #expect(items.first { $0.name == "emo" }?.value == "10")
        #expect(items.first { $0.name == "yr" }?.value == "cur")
    }

    @Test("early January asks for last December through this January")
    func earlyJanuaryLink() throws {
        let url = try #require(NearbySightings.url(
            code: "rudduc", center: nil, now: date(2027, 1, 2), calendar: calendar
        ))
        #expect(url.absoluteString == "https://ebird.org/map/rudduc?bmo=12&emo=1&yr=cur")
    }

    @Test("species codes come from the bundled table")
    func codes() {
        #expect(SpeciesCatalog.shared.eBirdCode(scientificName: "Thryothorus ludovicianus") == "carwre")
        #expect(SpeciesCatalog.shared.eBirdCode(scientificName: "Astur cooperii") == "coohaw")
        #expect(SpeciesCatalog.shared.eBirdCode(scientificName: "Dog") == nil)
    }
}
