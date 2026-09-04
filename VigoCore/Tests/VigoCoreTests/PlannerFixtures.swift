import Foundation
@testable import VigoCore

/// Synthetic geometry and timetables for the planner tests.
///
/// Distances here are exact rather than approximate: the offsets use the same earth
/// radius as `TransitRepository.haversineMetres`, so a stop built with
/// `northMetres: 250` really is 250 m away and a test can assert on the boundary of a
/// radius without a fudge factor.
enum PlannerFixture {

    /// Praza de América, the origin for all synthetic layouts.
    static let base = Coordinate(latitude: 42.2209973130163, longitude: -8.73283517659561)

    /// Metres per degree of latitude on the sphere `haversineMetres` uses.
    static let metresPerDegree = 6_371_000.0 * .pi / 180.0

    static func stop(
        _ id: String, northMetres: Double = 0, eastMetres: Double = 0, name: String? = nil
    ) -> Stop {
        let latitude = base.latitude + northMetres / metresPerDegree
        let longitude = base.longitude
            + eastMetres / (metresPerDegree * cos(base.latitude * .pi / 180))
        let displayName = name ?? "Parada \(id)"
        return Stop(
            id: StopID(id), gtfsStopCode: "P\(id)", vitrasaCode: VitrasaStopCode(gtfsStopCode: id),
            name: displayName, searchName: TextNormalization.searchFolded(displayName),
            latitude: latitude, longitude: longitude, wheelchairBoarding: nil)
    }

    // MARK: - A synthetic network

    /// Five stops on an east-west line, 600 m apart, plus a twin of C across the road.
    ///
    /// ```
    ///   A ──600m── B ──600m── C ──600m── D
    ///                         C2 (40 m north of C)
    ///                         E  (280 m north of C2, 320 m from C)
    /// ```
    /// E is served by nothing and exists only to make walk-chaining visible: it is inside
    /// the 300 m transfer radius of C2 but outside C's, so it can only be reached by
    /// walking twice in a row — which the planner must refuse to do.
    /// L1 runs A→B→C, L2 runs C2→D and L5 runs C→D, so A→D can be done either with a
    /// walking transfer at C or with a same-stop one. N1 runs A→B→C after midnight, and
    /// L4 runs A→B→C with a stopper and an express that overtakes it.
    static let networkStops: [Stop] = [
        stop("1001", name: "A"),
        stop("1002", eastMetres: 600, name: "B"),
        stop("1003", eastMetres: 1_200, name: "C"),
        stop("1004", northMetres: 40, eastMetres: 1_200, name: "C2"),
        stop("1005", eastMetres: 1_800, name: "D"),
        stop("1006", northMetres: 320, eastMetres: 1_200, name: "E"),
    ]

    static func index(of id: String, in timetable: Timetable) -> Int {
        Int(timetable.index(of: StopID(id))!)
    }

    private static var networkStopsCSV: String {
        var lines = ["stop_id,stop_code,stop_name,stop_lat,stop_lon,wheelchair_boarding"]
        for stop in networkStops {
            lines.append("\(stop.id),\(stop.gtfsStopCode),\(stop.name),"
                         + "\(stop.latitude),\(stop.longitude),0")
        }
        return lines.joined(separator: "\n")
    }

    /// R9 has no trips: a ghost line, which must never reach a pattern.
    private static let networkRoutes = """
    route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color
    R1,1,L1,A - C,3,ED4713,000000
    R2,1,L2,C2 - D,3,993300,000000
    R3,1,N1,NOCTURNO A - C,3,336699,000000
    R4,1,L4,A - C EXPRES,3,00A000,000000
    R5,1,L5,C - D,3,7040A0,000000
    R6,1,L6,A - D DIRECTO,3,C08000,000000
    R9,1,G9,LIÑA FANTASMA,3,888888,000000
    """

    private static let networkTrips = """
    route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
    R1,WEEK,T1_0800,C,0,B1,
    R1,WEEK,T1_0830,C,0,B1,
    R1,WEEK,T1_0900,C,0,B1,
    R1,SUN,T1_SUN,C,0,B1,
    R2,WEEK,T2_0830,D,0,B2,
    R2,WEEK,T2_0900,D,0,B2,
    R3,WEEK,TN_2510,C,0,B3,
    R4,WEEK,T4_1000,C,0,B4,
    R4,WEEK,T4_1005,C EXPRES,0,B4,
    R5,WEEK,T5_0821,D,0,B5,
    R5,WEEK,T5_0830,D,0,B5,
    R6,WEEK,T6_0650,D,0,B6,
    R6,WEEK,T6_0900,D,0,B6,
    """

    /// `T4_1005` leaves A five minutes after `T4_1000` and reaches C twenty minutes before
    /// it. `TN_2510` runs at 25:10, i.e. 01:10 the next calendar morning.
    ///
    /// `T5_0821` leaves C at 08:21:00, exactly one minute after `T1_0800` gets there: the
    /// default `minTransferSeconds` makes it catchable and one second more does not.
    ///
    /// L6 is the trap for a planner that lets a passenger board with a label from the round
    /// it is currently in. `T6_0650` leaves A too early to be caught by a 07:00 traveller
    /// but is still sitting at C at 08:30 — reachable only by getting off L1 there, which
    /// is a second vehicle and therefore a second round. A planner that boards it during
    /// round one reports a two-bus journey as a one-bus one.
    private static let networkStopTimes = """
    trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
    T1_0800,08:00:00,08:00:00,1001,1,0,0
    T1_0800,08:10:00,08:10:00,1002,2,0,0
    T1_0800,08:20:00,08:20:00,1003,3,0,0
    T1_0830,08:30:00,08:30:00,1001,1,0,0
    T1_0830,08:40:00,08:40:00,1002,2,0,0
    T1_0830,08:50:00,08:50:00,1003,3,0,0
    T1_0900,09:00:00,09:00:00,1001,1,0,0
    T1_0900,09:10:00,09:10:00,1002,2,0,0
    T1_0900,09:20:00,09:20:00,1003,3,0,0
    T1_SUN,12:00:00,12:00:00,1001,1,0,0
    T1_SUN,12:10:00,12:10:00,1002,2,0,0
    T1_SUN,12:20:00,12:20:00,1003,3,0,0
    T2_0830,08:30:00,08:30:00,1004,1,0,0
    T2_0830,08:40:00,08:40:00,1005,2,0,0
    T2_0900,09:00:00,09:00:00,1004,1,0,0
    T2_0900,09:10:00,09:10:00,1005,2,0,0
    TN_2510,25:10:00,25:10:00,1001,1,0,0
    TN_2510,25:20:00,25:20:00,1002,2,0,0
    TN_2510,25:30:00,25:30:00,1003,3,0,0
    T4_1000,10:00:00,10:00:00,1001,1,0,0
    T4_1000,10:20:00,10:20:00,1002,2,0,0
    T4_1000,10:40:00,10:40:00,1003,3,0,0
    T4_1005,10:05:00,10:05:00,1001,1,0,0
    T4_1005,10:12:00,10:12:00,1002,2,0,0
    T4_1005,10:20:00,10:20:00,1003,3,0,0
    T5_0821,08:21:00,08:21:00,1003,1,0,0
    T5_0821,08:31:00,08:31:00,1005,2,0,0
    T5_0830,08:30:00,08:30:00,1003,1,0,0
    T5_0830,08:45:00,08:45:00,1005,2,0,0
    T6_0650,06:50:00,06:50:00,1001,1,0,0
    T6_0650,08:30:00,08:30:00,1003,2,0,0
    T6_0650,08:40:00,08:40:00,1005,3,0,0
    T6_0900,09:00:00,09:00:00,1001,1,0,0
    T6_0900,09:30:00,09:30:00,1003,2,0,0
    T6_0900,09:40:00,09:40:00,1005,3,0,0
    """

    /// 2026-09-03 is a Thursday and 2026-09-06 a Sunday, so an anchor of 2026-09-04 has a
    /// populated day either side and the Sunday sits outside the three-day window.
    private static let networkCalendarDates = """
    service_id,date,exception_type
    WEEK,20260903,1
    WEEK,20260904,1
    WEEK,20260905,1
    SUN,20260906,1
    """

    static var networkProvider: GTFSInMemory {
        GTFSInMemory(texts: [
            "agency.txt": """
            agency_id,agency_name,agency_url,agency_timezone,agency_lang
            1,Viguesa de Transportes S.L.,http://www.vitrasa.es/,Europe/Madrid,es
            """,
            "stops.txt": networkStopsCSV,
            "routes.txt": networkRoutes,
            "trips.txt": networkTrips,
            "stop_times.txt": networkStopTimes,
            "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date",
            "calendar_dates.txt": networkCalendarDates,
            "shapes.txt": "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence,shape_dist_traveled",
        ])
    }

    static func networkDatabase() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        let parsed = try GTFSParser().parse(from: networkProvider)
        _ = try GTFSImporter(database: db).import(
            feed: parsed.feed, parseWarnings: parsed.warnings, importedAt: Fixture.importedAt)
        return db
    }

    /// The anchor every planner test builds around: Friday 2026-09-04.
    static let anchor = ServiceDate(yyyymmdd: 20_260_904)

    static func networkTimetable(options: PlannerOptions = PlannerOptions()) throws -> Timetable {
        let repository = TransitRepository(database: try networkDatabase())
        return try TimetableBuilder(repository: repository, options: options).build(anchor: anchor)
    }
}
