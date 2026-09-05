import Testing
import Foundation
@testable import VigoCore

/// A single line with a real headway: A → B every ten minutes, six departures.
///
/// The other planner fixtures have one trip apiece, which is enough to prove an outcome but
/// says nothing about *choice*. Alternatives across departures only exist when there is a
/// next bus to offer, so this fixture is the smallest network where "this one or the next
/// one" is a real question.
private enum HeadwayFixture {
    static let a = PlannerFixture.stop("H1", name: "A")
    static let b = PlannerFixture.stop("H2", eastMetres: 3_000, name: "B")

    static let windowStart = 20_260_901
    static let windowEnd = 20_260_910
    static let servedDay = ServiceDate(yyyymmdd: 20_260_903)

    /// 08:00, 08:10 … 08:50 — six departures, each a ten-minute ride.
    static let departureHours = 8
    static let departureMinutes = [0, 10, 20, 30, 40, 50]

    private static var stopTimesCSV: String {
        var lines = ["trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type"]
        for (index, minute) in departureMinutes.enumerated() {
            let trip = "T\(index + 1)"
            let board = String(format: "%02d:%02d:00", departureHours, minute)
            let alight = String(format: "%02d:%02d:00", departureHours + (minute + 10) / 60,
                                (minute + 10) % 60)
            lines.append("\(trip),\(board),\(board),\(a.id),1,0,0")
            lines.append("\(trip),\(alight),\(alight),\(b.id),2,0,0")
        }
        return lines.joined(separator: "\n")
    }

    private static var tripsCSV: String {
        var lines = ["route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id"]
        for index in departureMinutes.indices {
            lines.append("R1,WEEK,T\(index + 1),B,0,B\(index + 1),")
        }
        return lines.joined(separator: "\n")
    }

    static var provider: GTFSInMemory {
        GTFSInMemory(texts: [
            "agency.txt": """
            agency_id,agency_name,agency_url,agency_timezone,agency_lang
            1,Viguesa de Transportes S.L.,http://www.vitrasa.es/,Europe/Madrid,es
            """,
            "stops.txt": """
            stop_id,stop_code,stop_name,stop_lat,stop_lon,wheelchair_boarding
            \(a.id),\(a.gtfsStopCode),\(a.name),\(a.latitude),\(a.longitude),0
            \(b.id),\(b.gtfsStopCode),\(b.name),\(b.latitude),\(b.longitude),0
            """,
            "routes.txt": """
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color
            R1,1,L1,A - B,3,ED4713,000000
            """,
            "trips.txt": tripsCSV,
            "stop_times.txt": stopTimesCSV,
            "calendar.txt": """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WEEK,1,1,1,1,1,1,1,\(windowStart),\(windowEnd)
            """,
            "calendar_dates.txt": "service_id,date,exception_type",
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

    static func planner(_ repository: TransitRepository, options: PlannerOptions) -> JourneyPlanner {
        JourneyPlanner(repository: repository,
                      store: TimetableStore(repository: repository, options: options),
                      options: options)
    }

    static func query(_ repository: TransitRepository, hour: Int, minute: Int) -> PlanQuery {
        PlanQuery(origin: .coordinate(Coordinate(a), label: "A"),
                  destination: .coordinate(Coordinate(b), label: "B"),
                  departure: servedDay.startOfDay(in: repository.calendar)!
                      .addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60)))
    }
}

@Suite("Alternatives across departures")
struct JourneyAlternativesTests {

    private func journeys(_ outcome: PlanOutcome) -> [Journey] {
        guard case .journeys(let journeys) = outcome else {
            Issue.record("expected .journeys, got \(outcome)"); return []
        }
        return journeys
    }

    @Test("A line with a headway offers this bus and the next ones")
    func fourConsecutiveDepartures() async throws {
        let repository = try HeadwayFixture.repository()
        let planner = HeadwayFixture.planner(repository, options: PlannerOptions())
        let result = try await planner.plan(HeadwayFixture.query(repository, hour: 7, minute: 55))

        let found = journeys(result.outcome)
        #expect(found.count == 4)
        // Strictly later each time: without the restart after the previous boarding, every
        // pass would rediscover the same 08:00 bus.
        #expect(zip(found, found.dropFirst()).allSatisfy { $0.departure < $1.departure })
        // Sorted by arrival, and all distinct.
        #expect(zip(found, found.dropFirst()).allSatisfy { $0.arrival <= $1.arrival })
        #expect(Set(found).count == found.count)
        #expect(found.allSatisfy { $0.transfers == 0 })
    }

    @Test("No alternative is offered beyond the search horizon")
    func horizonIsRespected() async throws {
        let repository = try HeadwayFixture.repository()
        // 07:55 + 40 min = 08:35. Only the buses arriving at 08:10, 08:20 and 08:30 fit.
        let options = PlannerOptions(searchHorizon: 40 * 60)
        let planner = HeadwayFixture.planner(repository, options: options)
        let query = HeadwayFixture.query(repository, hour: 7, minute: 55)
        let result = try await planner.plan(query)

        let found = journeys(result.outcome)
        #expect(found.count == 3)
        let deadline = query.departure.addingTimeInterval(options.searchHorizon)
        #expect(found.allSatisfy { $0.arrival <= deadline })
    }

    @Test("The number of searches is bounded, not the number of buses")
    func scansAreBounded() async throws {
        let repository = try HeadwayFixture.repository()
        let options = PlannerOptions(maxDepartureScans: 2)
        let planner = HeadwayFixture.planner(repository, options: options)
        let result = try await planner.plan(HeadwayFixture.query(repository, hour: 7, minute: 55))

        // Six buses are catchable inside the horizon; two passes may only find two of them.
        #expect(journeys(result.outcome).count == 2)
    }

    /// Desde la Fase 10 el tope del planificador es `maxCandidates` — el conjunto entre el
    /// que elige la preferencia —, y `maxAlternatives` es cuántas se enseñan.
    @Test("The list is capped by maxCandidates")
    func capIsRespected() async throws {
        let repository = try HeadwayFixture.repository()
        let planner = HeadwayFixture.planner(repository, options: PlannerOptions(maxCandidates: 2))
        let result = try await planner.plan(HeadwayFixture.query(repository, hour: 7, minute: 55))

        #expect(journeys(result.outcome).count == 2)
    }

    @Test("With no bus left, the scan stops instead of walking the horizon")
    func stopsWhenTheServiceEnds() async throws {
        let repository = try HeadwayFixture.repository()
        let planner = HeadwayFixture.planner(repository, options: PlannerOptions())
        // 08:45: only the 08:50 departure is left.
        let result = try await planner.plan(HeadwayFixture.query(repository, hour: 8, minute: 45))

        #expect(journeys(result.outcome).count == 1)
    }
}
