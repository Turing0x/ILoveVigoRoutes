import Testing
import Foundation
@testable import VigoCore

/// A chosen stop (A), a better stop 200 m north of it (N), and a destination 3 km east (D).
///
/// L1 is the slow bus from where the traveller stands: A 08:00 → D 08:40. L2 is the fast one
/// round the corner: N 08:05 → D at `fastArrival`. Searching the radius from A — what the
/// planner did for every origin before Fase 15b — takes L2 and never mentions L1, which is
/// the 5720 → Concello bug in three stops.
private enum StopOriginFixture {
    static let a = PlannerFixture.stop("SO1", name: "A elegida")
    static let n = PlannerFixture.stop("SO2", northMetres: 200, name: "N cercana")
    static let d = PlannerFixture.stop("SO3", eastMetres: 3_000, name: "D destino")
    static let day = ServiceDate(yyyymmdd: 20_260_903)

    static func provider(fastArrival: String, slowRuns: Bool) -> GTFSInMemory {
        var lines = ["stop_id,stop_code,stop_name,stop_lat,stop_lon,wheelchair_boarding"]
        for stop in [a, n, d] {
            lines.append("\(stop.id),\(stop.gtfsStopCode),\(stop.name),"
                         + "\(stop.latitude),\(stop.longitude),0")
        }
        var stopTimes = ["trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type",
                         "T2,08:05:00,08:05:00,\(n.id),1,0,0",
                         "T2,\(fastArrival),\(fastArrival),\(d.id),2,0,0"]
        var trips = ["route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id",
                     "R2,WEEK,T2,D,0,B2,"]
        if slowRuns {
            stopTimes += ["T1,08:00:00,08:00:00,\(a.id),1,0,0",
                          "T1,08:40:00,08:40:00,\(d.id),2,0,0"]
            trips.append("R1,WEEK,T1,D,0,B1,")
        }
        return GTFSInMemory(texts: [
            "agency.txt": """
            agency_id,agency_name,agency_url,agency_timezone,agency_lang
            1,Viguesa de Transportes S.L.,http://www.vitrasa.es/,Europe/Madrid,es
            """,
            "stops.txt": lines.joined(separator: "\n"),
            "routes.txt": """
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color
            R1,1,L1,A - D,3,ED4713,000000
            R2,1,L2,N - D,3,ED4713,000000
            """,
            "trips.txt": trips.joined(separator: "\n"),
            "stop_times.txt": stopTimes.joined(separator: "\n"),
            "calendar.txt": """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WEEK,1,1,1,1,1,1,1,20260901,20260910
            """,
            "calendar_dates.txt": "service_id,date,exception_type",
            "shapes.txt": "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence,shape_dist_traveled",
        ])
    }

    static func plan(origin: Place, fastArrival: String = "08:15:00",
                     slowRuns: Bool = true) async throws -> PlanResult {
        let db = try AppDatabase.inMemory()
        let parsed = try GTFSParser().parse(from: provider(fastArrival: fastArrival, slowRuns: slowRuns))
        _ = try GTFSImporter(database: db).import(
            feed: parsed.feed, parseWarnings: parsed.warnings, importedAt: Fixture.importedAt)
        let repository = TransitRepository(database: db)
        let planner = JourneyPlanner(repository: repository,
                                     store: TimetableStore(repository: repository, footpaths: .empty))
        let departure = day.startOfDay(in: repository.calendar)!.addingTimeInterval(8 * 3_600)
        return try await planner.plan(PlanQuery(
            origin: origin, destination: .coordinate(Coordinate(d), label: "Destino"),
            departure: departure))
    }

    static func buses(_ result: PlanResult) -> [Journey] {
        let journeys: [Journey]
        switch result.outcome {
        case .journeys(let found): journeys = found
        case .walkOnly(let walk): journeys = [walk]
        default: journeys = []
        }
        return journeys.filter { $0.firstBoarding != nil }
    }
}

@Suite("Stop chosen as origin")
struct StopOriginTests {

    @Test("Una parada elegida como origen: todo sale de ella, sin caminata previa")
    func anchoredToChosenStop() async throws {
        let result = try await StopOriginFixture.plan(origin: .stop(StopOriginFixture.a))
        let buses = StopOriginFixture.buses(result)
        #expect(!buses.isEmpty, "got \(result.outcome)")
        for journey in buses {
            #expect(journey.firstBoarding?.id == StopOriginFixture.a.id)
            if case .walk = journey.legs.first { Issue.record("starts with a walk: \(journey.legs)") }
        }
    }

    @Test("Una coordenada sigue buscando en todo el radio, y no lleva aviso")
    func coordinateUnchanged() async throws {
        let result = try await StopOriginFixture.plan(
            origin: .coordinate(Coordinate(StopOriginFixture.a), label: "Aquí"))
        let buses = StopOriginFixture.buses(result)
        #expect(buses.contains { $0.firstBoarding?.id == StopOriginFixture.n.id })
        #expect(result.nearbyStopHint == nil)
    }

    @Test("Otra parada que llega 25 min antes sale como aviso, no como alternativa")
    func hintWhenClearlyBetter() async throws {
        let result = try await StopOriginFixture.plan(origin: .stop(StopOriginFixture.a))
        let hint = try #require(result.nearbyStopHint)
        #expect(hint.stop.id == StopOriginFixture.n.id)
        #expect(abs((hint.arrivesEarlierBy ?? 0) - 25 * 60) < 1)
        #expect(hint.walkSeconds > 0)
    }

    @Test("El umbral es de diez minutos: con diez hay aviso, con nueve no",
          arguments: [("08:30:00", true), ("08:31:00", false)])
    func hintThreshold(fastArrival: String, expectsHint: Bool) async throws {
        let result = try await StopOriginFixture.plan(origin: .stop(StopOriginFixture.a),
                                                      fastArrival: fastArrival)
        #expect((result.nearbyStopHint != nil) == expectsHint)
    }

    @Test("Si de la parada elegida no sale nada, la cercana se avisa sin umbral")
    func hintWhenChosenStopHasNothing() async throws {
        let result = try await StopOriginFixture.plan(origin: .stop(StopOriginFixture.a),
                                                      fastArrival: "08:39:00", slowRuns: false)
        #expect(StopOriginFixture.buses(result).isEmpty)
        let hint = try #require(result.nearbyStopHint)
        #expect(hint.stop.id == StopOriginFixture.n.id)
        #expect(hint.arrivesEarlierBy == nil)
    }

    @Test("La propia parada nunca es su aviso")
    func neverHintsItself() {
        let a = StopOriginFixture.a, d = StopOriginFixture.d
        let t0 = Date(timeIntervalSince1970: 0)
        let own = Journey(legs: [.ride(routeID: RouteID("R1"), routeShortName: "L1", headsign: nil,
                                       tripID: TripID("T1"), board: a, alight: d,
                                       departure: t0, arrival: t0.addingTimeInterval(600),
                                       intermediateStops: [])],
                          departure: t0, arrival: t0.addingTimeInterval(600), transfers: 0)
        #expect(NearbyStopHint.choose(origin: a, anchored: [], unanchored: [own],
                                      minimumGain: 600) == nil)
    }
}
