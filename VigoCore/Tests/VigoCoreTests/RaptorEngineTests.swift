import Testing
import Foundation
@testable import VigoCore

/// Times on the anchor axis for 2026-09-04, so the expectations read as clock times.
private enum T {
    static func at(_ hour: Int, _ minute: Int) -> Int32 { Int32(hour * 3_600 + minute * 60) }
}

@Suite("RAPTOR rounds")
struct RaptorEngineTests {

    private struct Network {
        let timetable: Timetable
        let a: Int, b: Int, c: Int, twin: Int, d: Int, e: Int

        init(options: PlannerOptions = PlannerOptions()) throws {
            timetable = try PlannerFixture.networkTimetable(options: options)
            a = PlannerFixture.index(of: "1001", in: timetable)
            b = PlannerFixture.index(of: "1002", in: timetable)
            c = PlannerFixture.index(of: "1003", in: timetable)
            twin = PlannerFixture.index(of: "1004", in: timetable)
            d = PlannerFixture.index(of: "1005", in: timetable)
            e = PlannerFixture.index(of: "1006", in: timetable)
        }

        func query(from: Int, to: Int, at departure: Int32,
                   horizon: Int32 = 3 * 3_600,
                   accessWalk: Int32 = 0) -> RaptorQuery {
            RaptorQuery(access: [StopWalk(stop: Int32(from), seconds: accessWalk)],
                        egress: [StopWalk(stop: Int32(to), seconds: 0)],
                        departure: departure, horizon: horizon)
        }
    }

    // MARK: - The basics

    @Test("A direct ride is found in one round")
    func direct() throws {
        let network = try Network()
        let result = RaptorEngine().run(
            network.timetable, network.query(from: network.a, to: network.c, at: T.at(7, 0)))

        // The 08:00 from A reaches C at 08:20.
        #expect(result.arrival(round: 1, stop: network.c) == T.at(8, 20))
        #expect(result.arrival(round: 1, stop: network.b) == T.at(8, 10))
        #expect(result.roundsRun >= 1)

        guard case .ride(let pattern, _, let board, let alight)? =
                result.parent(round: 1, stop: network.c) else {
            Issue.record("expected a ride into C"); return
        }
        #expect(network.timetable.patternRouteShortName[Int(pattern)] == "L1")
        #expect(board == 0)
        #expect(alight == 2)
    }

    @Test("The walk from the origin is added to the departure time")
    func accessWalk() throws {
        let network = try Network()
        let result = RaptorEngine().run(
            network.timetable,
            network.query(from: network.a, to: network.c, at: T.at(7, 0), accessWalk: 300))

        #expect(result.arrival(round: 0, stop: network.a) == T.at(7, 5))
        #expect(result.parent(round: 0, stop: network.a) == .access(seconds: 300))
        #expect(result.arrival(round: 1, stop: network.c) == T.at(8, 20),
                "five minutes of walking still catches the 08:00")
    }

    @Test("With nowhere to enter the network nothing is reached")
    func noAccess() throws {
        let network = try Network()
        let result = RaptorEngine().run(network.timetable, RaptorQuery(
            access: [], egress: [StopWalk(stop: Int32(network.c), seconds: 0)],
            departure: T.at(7, 0), horizon: 3 * 3_600))
        #expect(result.bestArrival.allSatisfy { $0 == RaptorResult.unreached })
        #expect(result.roundsRun == 0)
    }

    // MARK: - Transfers

    @Test("A same-stop transfer takes a second vehicle and one more round")
    func sameStopTransfer() throws {
        let network = try Network()
        let result = RaptorEngine().run(
            network.timetable, network.query(from: network.a, to: network.d, at: T.at(7, 0)))

        // One vehicle gets to D at 09:40 on L6; two get there at 08:31 by changing at C.
        #expect(result.arrival(round: 1, stop: network.d) == T.at(9, 40))
        #expect(result.arrival(round: 2, stop: network.d) == T.at(8, 31))
        #expect(result.roundsRun == 2, "nothing is left to improve after the second round")

        guard case .ride(let pattern, _, _, _)? = result.parent(round: 2, stop: network.d) else {
            Issue.record("expected a ride into D"); return
        }
        #expect(network.timetable.patternRouteShortName[Int(pattern)] == "L5")
    }

    /// The minimum change time is the difference between a transfer that works and one
    /// that has the user sprinting. One second either side of it must change the answer.
    @Test("A transfer that is one second too tight is not taken")
    func minimumTransferTime() throws {
        let network = try Network()
        let engine = RaptorEngine(options: PlannerOptions(minTransferSeconds: 61))
        let result = engine.run(
            network.timetable, network.query(from: network.a, to: network.d, at: T.at(7, 0)))

        #expect(result.arrival(round: 2, stop: network.d) == T.at(8, 40),
                "the 08:21 is missed by a second, so the walk to C2 and the 08:30 win")
    }

    @Test("Twin stops across the road are joined by a walk inside the round")
    func walkingTransfer() throws {
        let network = try Network()
        let result = RaptorEngine().run(
            network.timetable, network.query(from: network.a, to: network.d, at: T.at(7, 0)))

        let expected = WalkModel().seconds(metres: 40)
        #expect(result.arrival(round: 1, stop: network.twin)
                == T.at(8, 20) + Int32(expected))
        #expect(result.parent(round: 1, stop: network.twin)
                == .walk(from: Int32(network.c), seconds: Int32(expected)))
    }

    /// With the same-stop change made impossible, the only way to D is the 40 m walk to
    /// C2 — and the slack added to that walk decides which bus is catchable.
    @Test("The footpath buffer decides whether the connecting bus is caught")
    func footpathBuffer() throws {
        let network = try Network()
        let tight = RaptorEngine(options: PlannerOptions(
            minTransferSeconds: 3_600, footpathBufferSeconds: 30))
        let slack = RaptorEngine(options: PlannerOptions(
            minTransferSeconds: 3_600, footpathBufferSeconds: 600))
        let query = network.query(from: network.a, to: network.d, at: T.at(7, 0))

        #expect(tight.run(network.timetable, query).arrival(round: 2, stop: network.d)
                == T.at(8, 40), "arrives at C2 at 08:20:41 and catches the 08:30")
        #expect(slack.run(network.timetable, query).arrival(round: 2, stop: network.d)
                == T.at(9, 10), "ten minutes of slack misses it and waits for the 09:00")
    }

    /// A transfer is one walk, not a hike assembled from several. E sits 280 m from C2 and
    /// 320 m from C, so the only route to it on foot is C → C2 → E, and letting the round
    /// chain walks would quietly turn a 300 m transfer policy into a 320 m one.
    @Test("Walking does not chain: one footpath hop per round")
    func oneWalkPerRound() throws {
        let network = try Network()
        let result = RaptorEngine().run(
            network.timetable, network.query(from: network.a, to: network.d, at: T.at(7, 0)))

        #expect(result.arrival(round: 1, stop: network.twin) != nil, "C2 is one walk from C")
        #expect(result.arrival(round: 1, stop: network.e) == nil,
                "E is only reachable by walking twice")
        #expect(result.bestArrival[network.e] == RaptorResult.unreached,
                "and no later round finds it either, since nothing stops at E")

        for round in 0...4 {
            for stop in 0..<network.timetable.stopCount {
                if case .walk(let from, _)? = result.parent(round: round, stop: stop) {
                    #expect(Int(from) != network.twin, "a walk from a stop only just walked to")
                }
            }
        }
    }

    /// Two independent lines each ending a stop apart, joined by a footpath: S1 (line L1,
    /// arrives 09:10) and S2 (line L2, arrives 09:20). The 120 s footpath from S1 beats S2's
    /// own ride, so the walk-relaxation loop overwrites S2's `arrival` *and* its `parent` to
    /// say it was walked into from S1 — correctly, for the arrival, since 09:12 really is
    /// reachable that way. But `rideParent` has to remember S2's own ride (L2) regardless,
    /// because a footpath *out* of S2 later that round is computed from that ride's time
    /// (`rideArrival`, snapshotted before the overwrite) — and following the wrong parent
    /// back would attribute that walk to the wrong line entirely.
    private static func rideOverwrittenByWalkTimetable()
        -> (timetable: Timetable, s0: Int, s1: Int, s2: Int, s4: Int) {
        let stops = [
            PlannerFixture.stop("RP0", name: "S0"), PlannerFixture.stop("RP1", name: "S1"),
            PlannerFixture.stop("RP2", name: "S2"), PlannerFixture.stop("RP4", name: "S4"),
        ]
        var stopIndexByID: [StopID: Int32] = [:]
        for (index, stop) in stops.enumerated() { stopIndexByID[stop.id] = Int32(index) }

        let timetable = Timetable(
            stops: stops, stopIndexByID: stopIndexByID,
            patternStopsOffset: [0, 2, 4], patternStops: [0, 1, 3, 2],
            patternTripsOffset: [0, 1, 2],
            tripRefs: [
                TripRef(tripID: TripID("L1#0"), serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                        dayOffsetSeconds: 0, headsign: nil),
                TripRef(tripID: TripID("L2#0"), serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                        dayOffsetSeconds: 0, headsign: nil),
            ],
            patternTimesOffset: [0, 2],
            tripArrival: [T.at(9, 0), T.at(9, 10), T.at(9, 0), T.at(9, 20)],
            tripDeparture: [T.at(9, 0), T.at(9, 10), T.at(9, 0), T.at(9, 20)],
            patternRouteID: [RouteID("RL1"), RouteID("RL2")], patternRouteShortName: ["L1", "L2"],
            stopPatternsOffset: [0, 1, 2, 3, 4],
            stopPatternPattern: [0, 0, 1, 1], stopPatternPosition: [0, 1, 1, 0],
            footpathOffset: [0, 0, 1, 2, 2], footpathTarget: [2, 1], footpathSeconds: [120, 120],
            anchorDay: ServiceDate(yyyymmdd: 20_260_101), anchorMidnight: Date(timeIntervalSince1970: 0),
            coveredDays: [ServiceDate(yyyymmdd: 20_260_101)], feedFingerprint: nil)
        return (timetable, 0, 1, 2, 3)
    }

    @Test("A ride's parent survives being overwritten by an incoming walk")
    func rideParentSurvivesIncomingWalk() throws {
        let (timetable, s0, s1, s2, s4) = Self.rideOverwrittenByWalkTimetable()
        let result = RaptorEngine().run(timetable, RaptorQuery(
            access: [StopWalk(stop: Int32(s0), seconds: 0), StopWalk(stop: Int32(s4), seconds: 0)],
            egress: [], departure: T.at(9, 0), horizon: 3 * 3_600))

        #expect(result.arrival(round: 1, stop: s2) == T.at(9, 12),
                "S1's ride (09:10) plus the 120 s footpath beats S2's own ride (09:20)")
        #expect(result.parent(round: 1, stop: s2) == .walk(from: Int32(s1), seconds: 120))

        guard case .ride(let pattern, _, _, _)? = result.rideParent(round: 1, stop: s2) else {
            Issue.record("expected S2's own ride to survive as rideParent"); return
        }
        #expect(timetable.patternRouteShortName[Int(pattern)] == "L2")
    }

    // MARK: - Bounds

    @Test("Nothing outside the horizon is reached")
    func horizon() throws {
        let network = try Network()
        let result = RaptorEngine().run(
            network.timetable,
            network.query(from: network.a, to: network.c, at: T.at(7, 0), horizon: 30 * 60))
        #expect(result.arrival(round: 1, stop: network.c) == nil, "the first bus is at 08:00")
        #expect(result.roundsRun == 0)
    }

    /// Target pruning is an optimisation, so the only thing worth asserting about it is
    /// that it changes nothing: a looser bound must produce the same optimum.
    @Test("A wider horizon finds the same journey")
    func pruningIsSound() throws {
        let network = try Network()
        let engine = RaptorEngine()
        let tight = engine.run(network.timetable,
                               network.query(from: network.a, to: network.d,
                                             at: T.at(7, 0), horizon: 3 * 3_600))
        let wide = engine.run(network.timetable,
                              network.query(from: network.a, to: network.d,
                                            at: T.at(7, 0), horizon: 12 * 3_600))
        #expect(tight.bestArrival[network.d] == wide.bestArrival[network.d])
        #expect(tight.arrival(round: 2, stop: network.d) == wide.arrival(round: 2, stop: network.d))
    }

    @Test("The round cap is respected")
    func roundCap() throws {
        let network = try Network()
        let engine = RaptorEngine(options: PlannerOptions(maxRounds: 1))
        let result = engine.run(
            network.timetable, network.query(from: network.a, to: network.d, at: T.at(7, 0)))
        #expect(result.arrival(round: 1, stop: network.c) == T.at(8, 20))
        #expect(result.bestArrival[network.d] == T.at(9, 40),
                "only the one-vehicle L6 survives; the 08:31 needs a second round")
    }

    /// A passenger who gets off L1 at C at 08:20 needs a *second* vehicle to carry on, and
    /// a second vehicle is a second round. `T6_0650` is still standing at C at 08:30, so a
    /// planner that boards with a label from the round it is already in reports that
    /// two-bus journey as a one-bus one — plausible, cheaper-looking, and wrong.
    @Test("A stop reached during this round cannot be boarded during this round")
    func boardingUsesThePreviousRound() throws {
        let network = try Network()
        let result = RaptorEngine().run(
            network.timetable, network.query(from: network.a, to: network.d, at: T.at(7, 0)))

        #expect(result.arrival(round: 1, stop: network.d) == T.at(9, 40),
                "08:40 here would mean L1 and L6 were counted as one vehicle")
        guard case .ride(let pattern, let trip, let board, _)? =
                result.parent(round: 1, stop: network.d) else {
            Issue.record("expected a ride into D"); return
        }
        #expect(network.timetable.patternRouteShortName[Int(pattern)] == "L6")
        #expect(board == 0, "boarded at A, the stop reached in round zero")
        #expect(network.timetable.tripRef(pattern: Int(pattern), trip: Int(trip)).tripID
                == TripID("T6_0900"))
    }

    // MARK: - The night line

    /// The whole reason the timetable folds three days together: at 01:00 the only bus
    /// running belongs to yesterday's service day.
    @Test("A journey after midnight rides yesterday's trip")
    func afterMidnight() throws {
        let network = try Network()
        let result = RaptorEngine().run(
            network.timetable, network.query(from: network.a, to: network.c, at: T.at(1, 0)))

        #expect(result.arrival(round: 1, stop: network.c) == T.at(1, 30))
        guard case .ride(let pattern, let trip, _, _)? =
                result.parent(round: 1, stop: network.c) else {
            Issue.record("expected a ride into C"); return
        }
        #expect(network.timetable.patternRouteShortName[Int(pattern)] == "N1")
        let ref = network.timetable.tripRef(pattern: Int(pattern), trip: Int(trip))
        #expect(ref.tripID == TripID("TN_2510"))
        #expect(ref.serviceDate == ServiceDate(yyyymmdd: 20_260_903), "Thursday's service day")
    }

    // MARK: - Determinism

    @Test("The same query answers the same way twice")
    func deterministic() throws {
        let network = try Network()
        let engine = RaptorEngine()
        let query = network.query(from: network.a, to: network.d, at: T.at(7, 0))
        let first = engine.run(network.timetable, query)
        let second = engine.run(network.timetable, query)
        #expect(first.arrival == second.arrival)
        #expect(first.bestArrival == second.bestArrival)
        #expect(first.parent == second.parent)
        #expect(first.roundsRun == second.roundsRun)
    }

    @Test("Labels never get worse as rounds go on")
    func monotone() throws {
        let network = try Network()
        let result = RaptorEngine().run(
            network.timetable, network.query(from: network.a, to: network.d, at: T.at(7, 0)))
        for stop in 0..<network.timetable.stopCount {
            let labels = (0...4).compactMap { result.arrival(round: $0, stop: stop) }
            #expect(labels == labels.sorted(by: >),
                    "a later round that arrives later would not be on the Pareto front")
        }
    }
}
