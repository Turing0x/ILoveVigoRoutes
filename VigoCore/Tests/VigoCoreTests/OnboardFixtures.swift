import Foundation
@testable import VigoCore

/// A layout the shared network cannot express: one line running in both directions, and a
/// second line that visits the same stop twice on a loop.
///
/// Both exist for the same reason — the two things that can make "which bus is this, and where
/// on its route am I" ambiguous. The shared `PlannerFixture` network has neither, and bending
/// it into having them would change what a dozen unrelated tests are asserting about.
///
/// ```
///   A ──600m── B ──600m── C ──600m── D          L1 runs A→B→C→D, L1 (other pattern) D→C→B→A
///   G ──600m── H                                 L7 loops G→H→G
/// ```
enum OnboardFixture {
    static let a = PlannerFixture.stop("8001", name: "A")
    static let b = PlannerFixture.stop("8002", eastMetres: 600, name: "B")
    static let c = PlannerFixture.stop("8003", eastMetres: 1_200, name: "C")
    static let d = PlannerFixture.stop("8004", eastMetres: 1_800, name: "D")
    /// Served only by L2, which starts at C: the transfer target.
    static let f = PlannerFixture.stop("8005", northMetres: 1_500, eastMetres: 1_200, name: "F")
    static let g = PlannerFixture.stop("8006", northMetres: 3_000, name: "G")
    static let h = PlannerFixture.stop("8007", northMetres: 3_000, eastMetres: 600, name: "H")

    static let anchor = PlannerFixture.anchor  // Friday 2026-09-04

    private static var stopsCSV: String {
        var lines = ["stop_id,stop_code,stop_name,stop_lat,stop_lon,wheelchair_boarding"]
        for stop in [a, b, c, d, f, g, h] {
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
            R1,1,9B.,A - D,3,ED4713,000000
            R2,1,L2,C - F,3,336699,000000
            R7,1,L7,Circular G,3,00A000,000000
            """,
            "trips.txt": """
            route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
            R1,WEEK,T1_0800,D,0,B1,
            R1,WEEK,T1_0900,D,0,B1,
            R1,WEEK,TR_0800,A,1,B1,
            R2,WEEK,T2_0825,F,0,B2,
            R2,WEEK,T2_0900,F,0,B2,
            R7,WEEK,T7_0800,G,0,B7,
            """,
            "stop_times.txt": """
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
            T1_0800,08:00:00,08:00:00,\(a.id),1,0,0
            T1_0800,08:10:00,08:10:00,\(b.id),2,0,0
            T1_0800,08:20:00,08:20:00,\(c.id),3,0,0
            T1_0800,08:30:00,08:30:00,\(d.id),4,0,0
            T1_0900,09:00:00,09:00:00,\(a.id),1,0,0
            T1_0900,09:10:00,09:10:00,\(b.id),2,0,0
            T1_0900,09:20:00,09:20:00,\(c.id),3,0,0
            T1_0900,09:30:00,09:30:00,\(d.id),4,0,0
            TR_0800,08:00:00,08:00:00,\(d.id),1,0,0
            TR_0800,08:10:00,08:10:00,\(c.id),2,0,0
            TR_0800,08:20:00,08:20:00,\(b.id),3,0,0
            TR_0800,08:30:00,08:30:00,\(a.id),4,0,0
            T2_0825,08:25:00,08:25:00,\(c.id),1,0,0
            T2_0825,08:40:00,08:40:00,\(f.id),2,0,0
            T2_0900,09:00:00,09:00:00,\(c.id),1,0,0
            T2_0900,09:15:00,09:15:00,\(f.id),2,0,0
            T7_0800,08:00:00,08:00:00,\(g.id),1,0,0
            T7_0800,08:20:00,08:20:00,\(h.id),2,0,0
            T7_0800,08:40:00,08:40:00,\(g.id),3,0,0
            """,
            "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date",
            "calendar_dates.txt": """
            service_id,date,exception_type
            WEEK,20260903,1
            WEEK,20260904,1
            WEEK,20260905,1
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

    static func timetable(options: PlannerOptions = PlannerOptions()) throws -> Timetable {
        try TimetableBuilder(repository: try repository(), options: options,
                             footpaths: .empty).build(anchor: anchor)
    }

    static func planner(repository: TransitRepository,
                        options: PlannerOptions = PlannerOptions()) -> JourneyPlanner {
        JourneyPlanner(repository: repository,
                       store: TimetableStore(repository: repository, options: options,
                                             footpaths: .empty),
                       options: options)
    }

    /// A clock time on the anchor day, in the calendar the repository uses.
    static func at(_ hour: Int, _ minute: Int, calendar: Calendar) -> Date {
        anchor.startOfDay(in: calendar)!
            .addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
    }

    /// The pattern of `line` whose first stop is `first`, and one of its trips by id.
    static func pattern(_ line: String, startingAt first: Stop, in timetable: Timetable) -> Int {
        (0..<timetable.patternCount).first {
            TextNormalization.normalizedLineName(timetable.patternRouteShortName[$0])
                == TextNormalization.normalizedLineName(line)
                && timetable.stops[Int(timetable.stopIndex(pattern: $0, position: 0))].id == first.id
        }!
    }

    static func trip(_ id: String, ofPattern pattern: Int, in timetable: Timetable) -> Int {
        (0..<timetable.tripCount(ofPattern: pattern)).first {
            timetable.tripRef(pattern: pattern, trip: $0).tripID == TripID(id)
        }!
    }

    /// An `OnboardRide` as the app would store it: the line as the feed spells it, the
    /// pattern's stop-id fingerprint, and the position the traveller has reached.
    static func ride(line: String = "9B.", pattern: Int, trip: String,
                     boardPosition: Int = 0, currentPosition: Int,
                     delaySeconds: Int = 0, in timetable: Timetable,
                     now: Date) -> OnboardRide {
        let stopAt: (Int) -> Stop = { position in
            timetable.stops[Int(timetable.stopIndex(pattern: pattern, position: position))]
        }
        let tripIndex = self.trip(trip, ofPattern: pattern, in: timetable)
        let scheduled = timetable.date(forAxisSeconds: Int(
            timetable.departure(pattern: pattern, trip: tripIndex, position: currentPosition)))
        return OnboardRide(
            routeShortName: line, headsign: timetable.tripRef(pattern: pattern,
                                                              trip: tripIndex).headsign,
            patternStopIDs: (0..<timetable.stopCount(ofPattern: pattern)).map { stopAt($0).id },
            tripID: TripID(trip),
            boardStop: .from(stopAt(boardPosition)), boardPosition: boardPosition,
            currentStop: .from(stopAt(currentPosition)), currentPosition: currentPosition,
            scheduledAtCurrent: scheduled, observedDelaySeconds: delaySeconds,
            declaredAt: now, updatedAt: now, confidence: .inferred)
    }
}
