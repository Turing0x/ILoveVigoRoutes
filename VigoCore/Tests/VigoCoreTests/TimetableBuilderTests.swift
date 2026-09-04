import Testing
import Foundation
@testable import VigoCore

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
        // L1, L2, N1 and the two halves of L4.
        #expect(timetable.patternCount == 5)
        // Friday and Saturday run eight trips each; Thursday contributes only the night one.
        #expect(timetable.tripCount == 17)
        #expect(timetable.stopCount == 5)
    }

    // MARK: - Indexes

    @Test("The inverse index lists every pattern serving a stop, with its position")
    func inverseIncidence() throws {
        let timetable = try PlannerFixture.networkTimetable()
        let c = PlannerFixture.index(of: "1003", in: timetable)
        let slots = timetable.patternSlots(ofStop: c).map {
            (Int(timetable.stopPatternPattern[$0]), Int(timetable.stopPatternPosition[$0]))
        }
        // C is the last stop of L1, N1 and both halves of L4, and is on no other pattern.
        #expect(slots.count == 4)
        #expect(slots.allSatisfy { $0.1 == 2 })
        #expect(Set(slots.map { timetable.patternRouteShortName[$0.0] }) == ["L1", "N1", "L4"])

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
        #expect(timetable.stopCount == 5, "the stops still exist, there is just nothing running")
    }
}
