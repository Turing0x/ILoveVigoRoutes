import Testing
import Foundation
@testable import VigoCore

/// A minimal feed for facade-level tests: `JourneyPlanner` needs a real feed window and a
/// real calendar gap to exercise every `PlanOutcome`, which the shared `PlannerFixture`
/// network (built for RAPTOR itself) does not have — its seven days are either fully
/// served or outside the window, with no gap day in between.
///
/// A (origin) and B (destination), 3 km apart — far enough that the direct walk (~40 min)
/// loses to the bus, one trip 08:00→08:10. E sits 20 km north, served by nothing: a
/// destination near it has a stop to resolve as egress, but no route reaches it and no
/// direct walk there is reasonable either.
private enum PlannerFacadeFixture {
    static let a = PlannerFixture.stop("F1", name: "A")
    static let b = PlannerFixture.stop("F2", eastMetres: 3_000, name: "B")
    static let e = PlannerFixture.stop("F3", northMetres: 20_000, name: "E")

    /// Every day in the window has WEEK service, except the 5th: a genuine no-service day
    /// inside a feed that otherwise has data for it.
    static let windowStart = 20_260_901
    static let windowEnd = 20_260_910
    static let gapDay = ServiceDate(yyyymmdd: 20_260_905)
    static let servedDay = ServiceDate(yyyymmdd: 20_260_903)
    static let outsideWindowDay = ServiceDate(yyyymmdd: 20_260_911)

    private static var stopsCSV: String {
        var lines = ["stop_id,stop_code,stop_name,stop_lat,stop_lon,wheelchair_boarding"]
        for stop in [a, b, e] {
            lines.append("\(stop.id),\(stop.gtfsStopCode),\(stop.name),"
                         + "\(stop.latitude),\(stop.longitude),0")
        }
        return lines.joined(separator: "\n")
    }

    static var provider: GTFSInMemory {
        GTFSInMemory(texts: [
            "agency.txt": """
            agency_id,agency_name,agency_url,agency_timezone,agency_lang
            1,Viguesa de Transportes S.L.,http://www.vitrasa.es/,Europe/Madrid,es
            """,
            "stops.txt": stopsCSV,
            "routes.txt": """
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color
            R1,1,L1,A - B,3,ED4713,000000
            """,
            "trips.txt": """
            route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
            R1,WEEK,T1,B,0,B1,
            """,
            "stop_times.txt": """
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
            T1,08:00:00,08:00:00,\(a.id),1,0,0
            T1,08:10:00,08:10:00,\(b.id),2,0,0
            """,
            "calendar.txt": """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WEEK,1,1,1,1,1,1,1,\(windowStart),\(windowEnd)
            """,
            "calendar_dates.txt": """
            service_id,date,exception_type
            WEEK,\(gapDay.yyyymmdd),2
            """,
            "shapes.txt": "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence,shape_dist_traveled",
        ])
    }

    static func repository() throws -> TransitRepository {
        let db = try AppDatabase.inMemory()
        let parsed = try GTFSParser().parse(from: provider)
        _ = try GTFSImporter(database: db).import(
            feed: parsed.feed, parseWarnings: parsed.warnings, importedAt: Fixture.importedAt)
        return TransitRepository(database: db)
    }

    static func planner(repository: TransitRepository, options: PlannerOptions = PlannerOptions())
        -> JourneyPlanner {
        JourneyPlanner(repository: repository,
                      store: TimetableStore(repository: repository, options: options),
                      options: options)
    }

    /// Local noon on `day`, well inside the service day.
    static func noon(_ day: ServiceDate, calendar: Calendar) -> Date {
        day.startOfDay(in: calendar)!.addingTimeInterval(12 * 3_600)
    }

    static func departure(_ day: ServiceDate, hour: Int, minute: Int, calendar: Calendar) -> Date {
        day.startOfDay(in: calendar)!.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
    }
}

@Suite("JourneyPlanner")
struct JourneyPlannerTests {

    private static let farAway = Coordinate(latitude: 60, longitude: 60)

    @Test("An empty database reports no data at all")
    func noData() async throws {
        let repository = TransitRepository(database: try AppDatabase.inMemory())
        let planner = PlannerFacadeFixture.planner(repository: repository)
        let result = try await planner.plan(PlanQuery(
            origin: .coordinate(PlannerFixture.base, label: "A"),
            destination: .coordinate(PlannerFixture.base, label: "B"),
            departure: Date()))
        guard case .noData = result.outcome else {
            Issue.record("expected .noData, got \(result.outcome)"); return
        }
    }

    @Test("No stop near the origin is reported before anything else geographic")
    func noStopsNearOrigin() async throws {
        let repository = try PlannerFacadeFixture.repository()
        let planner = PlannerFacadeFixture.planner(repository: repository)
        let result = try await planner.plan(PlanQuery(
            origin: .coordinate(Self.farAway, label: "Lejos"),
            destination: .coordinate(Coordinate(PlannerFacadeFixture.b), label: "B"),
            departure: PlannerFacadeFixture.noon(PlannerFacadeFixture.servedDay, calendar: repository.calendar)))
        guard case .noStopsNearOrigin(let radius) = result.outcome else {
            Issue.record("expected .noStopsNearOrigin, got \(result.outcome)"); return
        }
        #expect(radius == PlannerOptions().accessRadiusMetres)
    }

    @Test("No stop near the destination is reported the same way")
    func noStopsNearDestination() async throws {
        let repository = try PlannerFacadeFixture.repository()
        let planner = PlannerFacadeFixture.planner(repository: repository)
        let result = try await planner.plan(PlanQuery(
            origin: .coordinate(Coordinate(PlannerFacadeFixture.a), label: "A"),
            destination: .coordinate(Self.farAway, label: "Lejos"),
            departure: PlannerFacadeFixture.noon(PlannerFacadeFixture.servedDay, calendar: repository.calendar)))
        guard case .noStopsNearDestination(let radius) = result.outcome else {
            Issue.record("expected .noStopsNearDestination, got \(result.outcome)"); return
        }
        #expect(radius == PlannerOptions().accessRadiusMetres)
    }

    @Test("A day past the feed's window is 'no data for that day', not 'no service'")
    func outsideFeedWindow() async throws {
        let repository = try PlannerFacadeFixture.repository()
        let planner = PlannerFacadeFixture.planner(repository: repository)
        let result = try await planner.plan(PlanQuery(
            origin: .coordinate(Coordinate(PlannerFacadeFixture.a), label: "A"),
            destination: .coordinate(Coordinate(PlannerFacadeFixture.b), label: "B"),
            departure: PlannerFacadeFixture.noon(
                PlannerFacadeFixture.outsideWindowDay, calendar: repository.calendar)))
        guard case .outsideFeedWindow(let window) = result.outcome else {
            Issue.record("expected .outsideFeedWindow, got \(result.outcome)"); return
        }
        #expect(window.lowerBound.yyyymmdd == PlannerFacadeFixture.windowStart)
        #expect(window.upperBound.yyyymmdd == PlannerFacadeFixture.windowEnd)
    }

    @Test("A gap day inside the window is 'no service', not 'no data'")
    func noServiceOnDay() async throws {
        let repository = try PlannerFacadeFixture.repository()
        let planner = PlannerFacadeFixture.planner(repository: repository)
        let result = try await planner.plan(PlanQuery(
            origin: .coordinate(Coordinate(PlannerFacadeFixture.a), label: "A"),
            destination: .coordinate(Coordinate(PlannerFacadeFixture.b), label: "B"),
            departure: PlannerFacadeFixture.noon(PlannerFacadeFixture.gapDay, calendar: repository.calendar)))
        guard case .noServiceOnDay(let day) = result.outcome else {
            Issue.record("expected .noServiceOnDay, got \(result.outcome)"); return
        }
        #expect(day == PlannerFacadeFixture.gapDay)
    }

    @Test("A bus that beats walking is offered as a journey")
    func journeyFound() async throws {
        let repository = try PlannerFacadeFixture.repository()
        let planner = PlannerFacadeFixture.planner(repository: repository)
        let result = try await planner.plan(PlanQuery(
            origin: .coordinate(Coordinate(PlannerFacadeFixture.a), label: "A"),
            destination: .coordinate(Coordinate(PlannerFacadeFixture.b), label: "B"),
            departure: PlannerFacadeFixture.departure(
                PlannerFacadeFixture.servedDay, hour: 7, minute: 55, calendar: repository.calendar)))
        guard case .journeys(let journeys) = result.outcome else {
            Issue.record("expected .journeys, got \(result.outcome)"); return
        }
        #expect(journeys.count == 1)
        #expect(journeys[0].transfers == 0)
        #expect(result.feedStatus.hasData)
    }

    @Test("Once the only bus has gone, a short walk is offered instead")
    func walkOnlyWhenBusIsGone() async throws {
        let repository = try PlannerFacadeFixture.repository()
        let planner = PlannerFacadeFixture.planner(repository: repository)
        let result = try await planner.plan(PlanQuery(
            origin: .coordinate(Coordinate(PlannerFacadeFixture.a), label: "A"),
            destination: .coordinate(Coordinate(PlannerFacadeFixture.b), label: "B"),
            departure: PlannerFacadeFixture.departure(
                PlannerFacadeFixture.servedDay, hour: 9, minute: 0, calendar: repository.calendar)))
        guard case .walkOnly(let journey) = result.outcome else {
            Issue.record("expected .walkOnly, got \(result.outcome)"); return
        }
        #expect(journey.legs.count == 1)
        guard case .walk = journey.legs[0] else { Issue.record("expected a single walk leg"); return }
    }

    @Test("A destination with no route and an unreasonable walk finds nothing")
    func noJourneyFound() async throws {
        let repository = try PlannerFacadeFixture.repository()
        let planner = PlannerFacadeFixture.planner(repository: repository)
        let result = try await planner.plan(PlanQuery(
            origin: .coordinate(Coordinate(PlannerFacadeFixture.a), label: "A"),
            destination: .coordinate(Coordinate(PlannerFacadeFixture.e), label: "E"),
            departure: PlannerFacadeFixture.departure(
                PlannerFacadeFixture.servedDay, hour: 7, minute: 0, calendar: repository.calendar)))
        guard case .noJourneyFound(let horizon) = result.outcome else {
            Issue.record("expected .noJourneyFound, got \(result.outcome)"); return
        }
        #expect(horizon == PlannerOptions().searchHorizon)
    }
}
