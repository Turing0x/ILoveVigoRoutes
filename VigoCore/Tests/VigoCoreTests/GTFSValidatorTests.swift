import Testing
import Foundation
@testable import VigoCore

@Suite("GTFS validator")
struct GTFSValidatorTests {

    @Test("A well-formed feed is importable")
    func healthyFeed() throws {
        let report = GTFSValidator().validate(try Fixture.parsedFeed())
        #expect(report.isImportable)
        #expect(report.blocking.isEmpty)
        #expect(report.stopCount == 4)
        #expect(report.routeCount == 4)
    }

    /// The real feed carries 16 routes with no trips. Showing them would reproduce the
    /// "ghost lines" complaint that motivated this app.
    @Test("Flags routes that have no trips")
    func ghostRoutes() throws {
        let report = GTFSValidator().validate(try Fixture.parsedFeed())
        #expect(report.routesWithTrips == 3)
        let ghost = try #require(report.advisories.first { $0.check == "routes.withoutTrips" })
        #expect(ghost.count == 1)
        #expect(ghost.severity == .advisory, "a ghost route degrades the UI, it does not break the data")
    }

    @Test("Blocks a feed whose stop times point at missing trips")
    func orphanStopTimes() throws {
        var feed = try Fixture.parsedFeed()
        feed.stopTimes.append(StopTime(tripID: TripID("GHOST"), stopID: StopID("3493"),
                                       stopSequence: 1,
                                       arrival: ServiceTime(seconds: 100),
                                       departure: ServiceTime(seconds: 100)))
        let report = GTFSValidator().validate(feed)
        #expect(!report.isImportable)
        #expect(report.blocking.contains { $0.check == "stopTimes.trip_id" })
    }

    @Test("Blocks a feed whose trips point at missing routes")
    func orphanTrips() throws {
        var feed = try Fixture.parsedFeed()
        feed.trips.append(Trip(id: TripID("X"), routeID: RouteID("NOPE"),
                               serviceID: ServiceID("A  01LP001_008001"),
                               headsign: nil, directionID: nil, shapeID: nil))
        let report = GTFSValidator().validate(feed)
        #expect(!report.isImportable)
        #expect(report.blocking.contains { $0.check == "trips.route_id" })
    }

    @Test("Blocks a feed that defines no service")
    func noService() throws {
        var feed = try Fixture.parsedFeed()
        feed.calendarDates = []
        feed.calendar = []
        let report = GTFSValidator().validate(feed)
        #expect(!report.isImportable)
    }

    /// A missing shape costs a drawn line, not a departure time, so it must not block.
    @Test("A missing shape is advisory, not blocking")
    func missingShape() throws {
        var feed = try Fixture.parsedFeed()
        feed.shapePoints = []
        let report = GTFSValidator().validate(feed)
        #expect(report.isImportable)
        #expect(report.advisories.contains { $0.check == "trips.shape_id" })
    }

    /// The production feed only ever covers seven days. That has to be surfaced, because
    /// it decides how aggressively the app must re-check for a new feed.
    @Test("Flags a short service window and a calendar_dates-only feed")
    func shortWindow() throws {
        let report = GTFSValidator().validate(try Fixture.parsedFeed())
        #expect(report.advisories.contains { $0.check == "calendar.shortWindow" })
        #expect(report.advisories.contains { $0.check == "calendar.datesOnly" })
    }

    @Test("Counts times past midnight and reports the latest")
    func pastMidnightAccounting() throws {
        let report = GTFSValidator().validate(try Fixture.parsedFeed())
        #expect(report.timesPastMidnight == 2)
        #expect(report.latestTime?.secondsSinceServiceDayStart == 91_320)
    }

    @Test("Flags stops that cannot be queried for live arrivals")
    func stopsWithoutRealtimeCode() throws {
        let report = GTFSValidator().validate(try Fixture.parsedFeed())
        #expect(report.advisories.contains { $0.check == "stops.withoutVitrasaCode" })
    }
}
