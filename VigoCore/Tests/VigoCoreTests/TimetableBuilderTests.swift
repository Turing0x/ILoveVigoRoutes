import Testing
import Foundation
@testable import VigoCore

/// A single trip on 2026-10-26 at 00:05, the day Madrid's clocks go back — the night from
/// 2026-10-25 to 2026-10-26 is 25 hours, not 24. Built as its own tiny feed rather than
/// reusing `PlannerFixture`'s network, whose calendar only covers a September week nowhere
/// near either clock change.
private enum DSTFixture {
    static let stops = """
    stop_id,stop_code,stop_name,stop_lat,stop_lon,wheelchair_boarding
    DST1,PDST1,Antes do cambio,42.2209973130163,-8.73283517659561,0
    DST2,PDST2,Despois do cambio,42.2358735452815,-8.72008331665535,0
    """

    static let routes = """
    route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color
    R1,1,D1,CAMBIO DE HORA,3,000000,000000
    """

    static let trips = """
    route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
    R1,DST,T_TOMORROW,Despois do cambio,0,B1,
    """

    /// Belongs to 2026-10-26's service day, well before midnight-plus-24h on any reading —
    /// this is not a past-midnight trip, it tests the *day offset*, not the axis fold.
    static let stopTimes = """
    trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
    T_TOMORROW,00:05:00,00:05:00,DST1,1,0,0
    T_TOMORROW,00:15:00,00:15:00,DST2,2,0,0
    """

    static let calendar = """
    service_id, monday, tuesday, wednesday, thursday, friday, saturday, sunday, start_date, end_date
    """

    static let calendarDates = """
    service_id,date,exception_type
    DST,20261024,1
    DST,20261025,1
    DST,20261026,1
    """

    static var provider: GTFSInMemory {
        GTFSInMemory(texts: [
            "agency.txt": Fixture.agency,
            "stops.txt": stops,
            "routes.txt": routes,
            "trips.txt": trips,
            "stop_times.txt": stopTimes,
            "calendar.txt": calendar,
            "calendar_dates.txt": calendarDates,
            "shapes.txt": "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence,shape_dist_traveled",
        ])
    }

    static func timetable(anchor: ServiceDate) throws -> Timetable {
        let db = try AppDatabase.inMemory()
        let parsed = try GTFSParser().parse(from: provider)
        _ = try GTFSImporter(database: db).import(feed: parsed.feed, parseWarnings: parsed.warnings)
        let repository = TransitRepository(database: db)
        return try TimetableBuilder(repository: repository).build(anchor: anchor)
    }
}

/// One trip whose middle stop arrives *before* the one before it — `GTFSValidator` only
/// flags this as an advisory (`stopTimes.nonMonotonic`), it does not reject the import, so a
/// row shaped like this really can reach `TimetableBuilder`.
private enum BackwardsFixture {
    static let stops = """
    stop_id,stop_code,stop_name,stop_lat,stop_lon,wheelchair_boarding
    BW1,PBW1,A,42.2209973130163,-8.73283517659561,0
    BW2,PBW2,B,42.2250000000000,-8.73000000000000,0
    BW3,PBW3,C,42.2358735452815,-8.72008331665535,0
    """

    static let routes = """
    route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color
    R1,1,BK,VOLVE ATRÁS,3,000000,000000
    """

    static let trips = """
    route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
    R1,BW,T_BACK,C,0,B1,
    """

    /// 08:00 → 07:50 → 08:10: the middle stop arrives ten minutes before the first one.
    static let stopTimes = """
    trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
    T_BACK,08:00:00,08:00:00,BW1,1,0,0
    T_BACK,07:50:00,07:50:00,BW2,2,0,0
    T_BACK,08:10:00,08:10:00,BW3,3,0,0
    """

    static let calendar = """
    service_id, monday, tuesday, wednesday, thursday, friday, saturday, sunday, start_date, end_date
    """

    static let calendarDates = """
    service_id,date,exception_type
    BW,20260904,1
    """

    static func timetable() throws -> Timetable {
        let provider = GTFSInMemory(texts: [
            "agency.txt": Fixture.agency,
            "stops.txt": stops,
            "routes.txt": routes,
            "trips.txt": trips,
            "stop_times.txt": stopTimes,
            "calendar.txt": calendar,
            "calendar_dates.txt": calendarDates,
            "shapes.txt": "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence,shape_dist_traveled",
        ])
        let db = try AppDatabase.inMemory()
        let parsed = try GTFSParser().parse(from: provider)
        _ = try GTFSImporter(database: db).import(feed: parsed.feed, parseWarnings: parsed.warnings)
        let repository = TransitRepository(database: db)
        return try TimetableBuilder(repository: repository).build(anchor: ServiceDate(yyyymmdd: 20_260_904))
    }
}

@Suite("Timetable construction")
struct TimetableBuilderTests {

    // MARK: - Days

    /// Yesterday, today and tomorrow, folded onto one axis. Without yesterday the night
    /// lines vanish at 01:00; without tomorrow an evening query cannot finish its journey.
    @Test("Folds the three service days around the anchor")
    func threeDays() throws {
        let timetable = try PlannerFixture.networkTimetable()
        #expect(timetable.coveredDays == [
            ServiceDate(yyyymmdd: 20_260_903),
            ServiceDate(yyyymmdd: 20_260_904),
            ServiceDate(yyyymmdd: 20_260_905),
        ])
        #expect(timetable.anchorDay == PlannerFixture.anchor)
        #expect(!timetable.coveredDays.contains(ServiceDate(yyyymmdd: 20_260_906)),
                "the Sunday service is outside the window")
    }

    /// Yesterday contributes only what is still running: its daytime trips are over.
    @Test("Keeps only the trips of the previous day that run past midnight")
    func previousDayIsFiltered() throws {
        let timetable = try PlannerFixture.networkTimetable()
        let yesterday = timetable.tripRefs.filter { $0.serviceDate == ServiceDate(yyyymmdd: 20_260_903) }
        #expect(yesterday.map(\.tripID.rawValue) == ["TN_2510"])
        #expect(timetable.tripDeparture.allSatisfy { $0 >= 0 },
                "a trip left over from yesterday would land before the axis starts")
    }

    /// The one case the whole day-folding exists for.
    @Test("Places a 25:10 trip at 01:10 on the anchor day, still owned by the previous day")
    func pastMidnightTrip() throws {
        let timetable = try PlannerFixture.networkTimetable()
        let pattern = try #require((0..<timetable.patternCount)
            .first { timetable.patternRouteShortName[$0] == "N1" })
        let trip = try #require((0..<timetable.tripCount(ofPattern: pattern))
            .first { timetable.tripRef(pattern: pattern, trip: $0).serviceDate
                == ServiceDate(yyyymmdd: 20_260_903) })

        let departure = Int(timetable.departure(pattern: pattern, trip: trip, position: 0))
        #expect(departure == 70 * 60, "01:10 on the anchor axis")
        #expect(timetable.date(forAxisSeconds: departure) == Fixture.date(2026, 9, 4, 1, 10))

        let ref = timetable.tripRef(pattern: pattern, trip: trip)
        #expect(ref.serviceDate == ServiceDate(yyyymmdd: 20_260_903), "Thursday's service day")
        #expect(timetable.serviceTime(axisSeconds: departure, trip: ref).description == "25:10:00")
    }

    @Test("Tomorrow's trips are shifted a day forward")
    func nextDayIsShifted() throws {
        let timetable = try PlannerFixture.networkTimetable()
        let pattern = try #require((0..<timetable.patternCount)
            .first { timetable.patternRouteShortName[$0] == "L1" })
        let tomorrow = (0..<timetable.tripCount(ofPattern: pattern)).first {
            timetable.tripRef(pattern: pattern, trip: $0).tripID == TripID("T1_0800")
                && timetable.tripRef(pattern: pattern, trip: $0).serviceDate
                    == ServiceDate(yyyymmdd: 20_260_905)
        }
        let trip = try #require(tomorrow)
        #expect(timetable.departure(pattern: pattern, trip: trip, position: 0) == 86_400 + 8 * 3_600)
        #expect(timetable.date(forAxisSeconds:
            Int(timetable.departure(pattern: pattern, trip: trip, position: 0)))
            == Fixture.date(2026, 9, 5, 8, 0))
    }

    // MARK: - The clocks change

    /// H-08: the day offset is the real gap between midnights (`ESTADO.md`, paso 2/11 de la
    /// Fase 3), not a fixed 86 400 — this is the one weekend a year where that distinction
    /// is observable in the other direction from `pastMidnightTrip`. The night from
    /// 2026-10-25 to 2026-10-26 is 25 hours in Madrid; a fixed offset would place a trip
    /// meant for 00:05 the next day an hour early.
    @Test("A trip on the day after the clocks go back lands at its real wall-clock time")
    func dstOffsetIsTheRealGap() throws {
        let timetable = try DSTFixture.timetable(anchor: ServiceDate(yyyymmdd: 20_261_025))
        let pattern = try #require((0..<timetable.patternCount)
            .first { timetable.patternRouteShortName[$0] == "D1" })
        let trip = try #require((0..<timetable.tripCount(ofPattern: pattern))
            .first { timetable.tripRef(pattern: pattern, trip: $0).serviceDate
                == ServiceDate(yyyymmdd: 20_261_026) })

        let departure = Int(timetable.departure(pattern: pattern, trip: trip, position: 0))
        #expect(timetable.date(forAxisSeconds: departure) == Fixture.date(2026, 10, 26, 0, 5),
                "the real 25-hour night, not a naive +86400")
    }

    // MARK: - Patterns

    @Test("Groups trips that share a route and a stop sequence")
    func patternGrouping() throws {
        let timetable = try PlannerFixture.networkTimetable()
        // L1: three trips a day on Friday and Saturday.
        let pattern = try #require((0..<timetable.patternCount)
            .first { timetable.patternRouteShortName[$0] == "L1" })
        #expect(timetable.stopCount(ofPattern: pattern) == 3)
        #expect(timetable.tripCount(ofPattern: pattern) == 6)
        #expect((0..<3).map { Int(timetable.stopIndex(pattern: pattern, position: $0)) }
                == ["1001", "1002", "1003"].map { PlannerFixture.index(of: $0, in: timetable) })
    }

    @Test("Trips within a pattern are ordered by departure")
    func tripsAreSorted() throws {
        let timetable = try PlannerFixture.networkTimetable()
        for pattern in 0..<timetable.patternCount {
            let departures = (0..<timetable.tripCount(ofPattern: pattern)).map {
                timetable.departure(pattern: pattern, trip: $0, position: 0)
            }
            #expect(departures == departures.sorted(), "pattern \(pattern) is out of order")
        }
    }

    /// The correctness guarantee RAPTOR's binary search rests on. An express that passes a
    /// stopper has to become its own pattern, or the search finds a trip that is not
    /// actually the earliest one and returns a journey that is merely plausible.
    @Test("Splits a pattern when one trip overtakes another")
    func overtakingSplits() throws {
        let timetable = try PlannerFixture.networkTimetable()
        let express = (0..<timetable.patternCount).filter {
            timetable.patternRouteShortName[$0] == "L4"
        }
        #expect(express.count == 2, "the stopper and the express cannot share a pattern")
        #expect(express.allSatisfy { timetable.stopCount(ofPattern: $0) == 3 },
                "the split keeps the stop sequence, it does not change it")

        for pattern in express {
            let trips = (0..<timetable.tripCount(ofPattern: pattern)).map {
                timetable.tripRef(pattern: pattern, trip: $0).tripID.rawValue
            }
            #expect(Set(trips).count == 1, "each group holds one trip id across its two days")
        }
    }

    @Test("No pattern overtakes itself at any position")
    func noOvertakingSurvives() throws {
        let timetable = try PlannerFixture.networkTimetable()
        for pattern in 0..<timetable.patternCount {
            let stops = timetable.stopCount(ofPattern: pattern)
            for trip in 1..<max(1, timetable.tripCount(ofPattern: pattern)) {
                for position in 0..<stops {
                    #expect(timetable.arrival(pattern: pattern, trip: trip, position: position)
                            >= timetable.arrival(pattern: pattern, trip: trip - 1, position: position))
                    #expect(timetable.departure(pattern: pattern, trip: trip, position: position)
                            >= timetable.departure(pattern: pattern, trip: trip - 1, position: position))
                }
            }
        }
    }

    /// H-09: every fixture in this suite has `arrival == departure` at each position — the
    /// real feed does too, 0 dwell in all 137 456 rows of it — so the `departures` clause of
    /// `overtakes` has never been exercised by anything above. Removing it changes nothing
    /// any existing test can see. A dwell is what makes the two clauses diverge: X dwells
    /// 300 s at the middle stop; Y does not, and its own arrivals never beat X's anywhere —
    /// only its *departure* right after that middle stop does, because it does not wait.
    @Test("A trip that dwells is overtaken by one that does not, even with no earlier arrival")
    func overtakesCatchesADepartureOnly() throws {
        func raw(_ id: String, arrivals: [Int32], departures: [Int32]) -> TimetableBuilder.RawTrip {
            TimetableBuilder.RawTrip(
                ref: TripRef(tripID: TripID(id), serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                            dayOffsetSeconds: 0, headsign: nil),
                routeID: RouteID("R"), stops: [0, 1, 2], arrivals: arrivals, departures: departures)
        }
        // X dwells 300 s at the middle stop (arrival 200, departure 500).
        let x = raw("X", arrivals: [100, 200, 700], departures: [100, 500, 700])
        // Y passes straight through — later at every arrival, but ready to leave the middle
        // stop long before X even starts moving again.
        let y = raw("Y", arrivals: [110, 250, 750], departures: [110, 250, 750])

        #expect(TimetableBuilder.overtakes(y, x),
                "Y leaves the middle stop at 250, before X's own 500 — invisible to a check on arrivals alone")

        let groups = TimetableBuilder.nonOvertakingGroups([0, 1], in: [x, y])
        #expect(groups.count == 2, "X's dwell has to split them into two patterns")
    }

    /// H-13: `GTFSValidator` only flags a backwards stop time as an advisory, it does not
    /// reject the import — so `TimetableBuilder` reading straight from the database was
    /// trusting an ordering nothing had actually enforced. Half a trip is worse than none,
    /// the same argument `flush()`'s existing guards already make; a trip that runs
    /// backwards is worse than either.
    @Test("A trip whose middle stop arrives before the one before it is dropped, not folded in")
    func nonMonotonicTripIsDropped() throws {
        let timetable = try BackwardsFixture.timetable()
        #expect(timetable.patternCount == 0)
        #expect(timetable.tripCount == 0)
        #expect(timetable.stopCount == 3, "the stops themselves still exist")
    }

    /// A line with no trips must not produce a pattern, for the same reason the stop
    /// screen hides it: the app exists partly because the official one shows ghost lines.
    @Test("A route with no trips produces no pattern")
    func ghostRoutes() throws {
        let timetable = try PlannerFixture.networkTimetable()
        #expect(!timetable.patternRouteShortName.contains("G9"))
        #expect(!timetable.patternRouteID.contains(RouteID("R9")))
    }

    @Test("Counts the whole synthetic network")
    func totals() throws {
        let timetable = try PlannerFixture.networkTimetable()
        // L1, L2, L5, L6, N1 and the two halves of L4.
        #expect(timetable.patternCount == 7)
        // Friday and Saturday run twelve trips each; Thursday contributes only the night one.
        #expect(timetable.tripCount == 25)
        #expect(timetable.stopCount == 6)
    }

    // MARK: - Indexes

    @Test("The inverse index lists every pattern serving a stop, with its position")
    func inverseIncidence() throws {
        let timetable = try PlannerFixture.networkTimetable()
        let c = PlannerFixture.index(of: "1003", in: timetable)
        let slots = timetable.patternSlots(ofStop: c).map {
            (Int(timetable.stopPatternPattern[$0]), Int(timetable.stopPatternPosition[$0]))
        }
        // C is the last stop of L1, N1 and both halves of L4, the first of L5 and the
        // middle of L6.
        #expect(slots.count == 6)
        #expect(slots.filter { $0.1 == 2 }.count == 4)
        #expect(slots.filter { $0.1 == 0 }.map { timetable.patternRouteShortName[$0.0] } == ["L5"])
        #expect(slots.filter { $0.1 == 1 }.map { timetable.patternRouteShortName[$0.0] } == ["L6"])
        #expect(Set(slots.map { timetable.patternRouteShortName[$0.0] })
                == ["L1", "N1", "L4", "L5", "L6"])

        for pattern in 0..<timetable.patternCount {
            for position in 0..<timetable.stopCount(ofPattern: pattern) {
                let stop = Int(timetable.stopIndex(pattern: pattern, position: position))
                let listed = timetable.patternSlots(ofStop: stop).contains {
                    timetable.stopPatternPattern[$0] == Int32(pattern)
                        && timetable.stopPatternPosition[$0] == Int32(position)
                }
                #expect(listed, "pattern \(pattern) position \(position) is missing from the index")
            }
        }
    }

    @Test("Twin stops are connected by a footpath, distant ones are not")
    func footpaths() throws {
        let timetable = try PlannerFixture.networkTimetable()
        let c = PlannerFixture.index(of: "1003", in: timetable)
        let twin = PlannerFixture.index(of: "1004", in: timetable)
        let b = PlannerFixture.index(of: "1002", in: timetable)

        let fromC = timetable.footpaths(fromStop: c).map {
            (Int(timetable.footpathTarget[$0]), Int(timetable.footpathSeconds[$0]))
        }
        #expect(fromC.map(\.0) == [twin], "only the stop across the road is within 300 m")
        #expect(fromC[0].1 == WalkModel().seconds(metres: 40))
        #expect(timetable.footpaths(fromStop: b).isEmpty, "B's neighbours are 600 m away")
    }

    // MARK: - Provenance and determinism

    @Test("Records the feed it was built from")
    func fingerprint() throws {
        let timetable = try PlannerFixture.networkTimetable()
        #expect(timetable.feedFingerprint == Fixture.importedAt)
        #expect(timetable.anchorMidnight == Fixture.date(2026, 9, 4, 0, 0))
    }

    /// Two builds of the same feed must be identical, or the cache in `TimetableStore`
    /// would be handing out subtly different answers to the same question.
    @Test("Building twice produces the same arrays")
    func deterministic() throws {
        let repository = TransitRepository(database: try PlannerFixture.networkDatabase())
        let builder = TimetableBuilder(repository: repository)
        let first = try builder.build(anchor: PlannerFixture.anchor)
        let second = try builder.build(anchor: PlannerFixture.anchor)

        #expect(first.patternStops == second.patternStops)
        #expect(first.patternStopsOffset == second.patternStopsOffset)
        #expect(first.tripDeparture == second.tripDeparture)
        #expect(first.tripArrival == second.tripArrival)
        #expect(first.tripRefs == second.tripRefs)
        #expect(first.stopPatternPattern == second.stopPatternPattern)
        #expect(first.footpathTarget == second.footpathTarget)
    }

    @Test("A day with no service at all builds an empty timetable rather than failing")
    func emptyDay() throws {
        let repository = TransitRepository(database: try PlannerFixture.networkDatabase())
        let timetable = try TimetableBuilder(repository: repository)
            .build(anchor: ServiceDate(yyyymmdd: 20_270_101))
        #expect(timetable.patternCount == 0)
        #expect(timetable.tripCount == 0)
        #expect(timetable.coveredDays.isEmpty)
        #expect(timetable.stopCount == 6, "the stops still exist, there is just nothing running")
    }
}
