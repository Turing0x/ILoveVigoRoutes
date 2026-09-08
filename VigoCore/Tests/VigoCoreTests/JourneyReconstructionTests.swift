import Testing
import Foundation
@testable import VigoCore

/// Times on the anchor axis, so expectations read as clock times.
private enum T {
    static func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Int32 {
        Int32(hour * 3_600 + minute * 60 + second)
    }
}

@Suite("Journey reconstruction")
struct JourneyReconstructionTests {

    private static let origin = Place.coordinate(PlannerFixture.base, label: "Origen")
    private static let destination = Place.coordinate(
        Coordinate(PlannerFixture.stop("DST", northMetres: 2_000)), label: "Destino")

    // MARK: - Against the shared synthetic network

    private struct Network {
        let timetable: Timetable
        let a: Int, c: Int, d: Int

        init() throws {
            timetable = try PlannerFixture.networkTimetable()
            a = PlannerFixture.index(of: "1001", in: timetable)
            c = PlannerFixture.index(of: "1003", in: timetable)
            d = PlannerFixture.index(of: "1005", in: timetable)
        }
    }

    @Test("A direct ride reconstructs into a walk, a ride, and a walk")
    func directRide() throws {
        let network = try Network()
        let query = RaptorQuery(access: [StopWalk(stop: Int32(network.a), seconds: 120)],
                                egress: [StopWalk(stop: Int32(network.c), seconds: 90)],
                                departure: T.at(7, 0), horizon: 3 * 3_600)
        let result = RaptorEngine().run(network.timetable, query)
        let journeys = JourneyReconstruction.alternatives(
            timetable: network.timetable, result: result, query: query,
            origin: Self.origin, destination: Self.destination, options: PlannerOptions())

        #expect(journeys.count == 1)
        guard let journey = journeys.first else { return }
        #expect(journey.transfers == 0)
        #expect(journey.legs.count == 3)

        guard case .walk(let from, _, let inSeconds, _) = journey.legs[0] else {
            Issue.record("expected the access walk first"); return
        }
        #expect(from == Self.origin)
        #expect(inSeconds == 120)

        guard case .ride(let routeID, let shortName, _, _, let board, let alight,
                         let departure, let arrival, let intermediate) = journey.legs[1] else {
            Issue.record("expected a ride second"); return
        }
        #expect(shortName == "L1")
        #expect(routeID == RouteID("R1"))
        #expect(board.id == StopID("1001"))
        #expect(alight.id == StopID("1003"))
        #expect(intermediate.map(\.id) == [StopID("1002")])
        #expect(network.timetable.axisSeconds(for: departure) == Int(T.at(8, 0)))
        #expect(network.timetable.axisSeconds(for: arrival) == Int(T.at(8, 20)))

        guard case .walk(_, let to, let outSeconds, _) = journey.legs[2] else {
            Issue.record("expected the egress walk last"); return
        }
        #expect(to == Self.destination)
        #expect(outSeconds == 90)

        #expect(network.timetable.axisSeconds(for: journey.departure) == Int(T.at(7, 58)),
                "the two minutes on foot come out of the traveller's own time")
        #expect(network.timetable.axisSeconds(for: journey.arrival) == Int(T.at(8, 21, 30)))
    }

    /// El defecto que arregla `negligibleWalkSeconds`: cuando la parada de bajada *es* el
    /// destino, el radio de egreso la sigue devolviendo con uno o dos segundos encima —
    /// nunca exactamente cero— y la reconstrucción emitía con eso un tramo «a pie 1 s / 0 m».
    /// En la fila de alternativas salía como un `legChip` más y en el mapa como un segmento
    /// discontinuo de longitud cero.
    @Test("Una parada de bajada que es el destino no deja tramo final a pie")
    func negligibleEgressWalkIsNotALeg() throws {
        let network = try Network()
        let query = RaptorQuery(access: [StopWalk(stop: Int32(network.a), seconds: 120)],
                                egress: [StopWalk(stop: Int32(network.c), seconds: 1)],
                                departure: T.at(7, 0), horizon: 3 * 3_600)
        let result = RaptorEngine().run(network.timetable, query)
        let journeys = JourneyReconstruction.alternatives(
            timetable: network.timetable, result: result, query: query,
            origin: Self.origin, destination: Self.destination, options: PlannerOptions())

        guard let journey = journeys.first else { Issue.record("expected a journey"); return }
        #expect(journey.legs.count == 2, "walk in and the ride; nothing to walk at the far end")
        guard case .ride = journey.legs[1] else {
            Issue.record("the journey has to end on the vehicle"); return
        }
        // Lo que la ordenación y `WalkRefinement` leen del último tramo: cero, no un segundo.
        #expect(JourneyOrdering.egressWalkSeconds(journey) == 0)
        #expect(WalkRefinement.estimatedEgressSeconds(journey) == 0)
        #expect(journey.walkingSeconds == 120, "solo el acceso")
        // El segundo descartado sigue contando en la hora de llegada: se deja de dibujar,
        // no de contar.
        #expect(network.timetable.axisSeconds(for: journey.arrival) == Int(T.at(8, 20, 1)))
    }

    /// El caso simétrico, y el que las demás pruebas de este fichero ejercitan de paso: un
    /// origen que ya está en la parada tampoco produce un tramo de acceso.
    @Test("Un origen que ya está en la parada no deja tramo de acceso")
    func negligibleAccessWalkIsNotALeg() throws {
        let network = try Network()
        let query = RaptorQuery(access: [StopWalk(stop: Int32(network.a), seconds: 0)],
                                egress: [StopWalk(stop: Int32(network.c), seconds: 90)],
                                departure: T.at(7, 0), horizon: 3 * 3_600)
        let result = RaptorEngine().run(network.timetable, query)
        let journeys = JourneyReconstruction.alternatives(
            timetable: network.timetable, result: result, query: query,
            origin: Self.origin, destination: Self.destination, options: PlannerOptions())

        guard let journey = journeys.first else { Issue.record("expected a journey"); return }
        #expect(journey.legs.count == 2, "the ride and the walk out")
        guard case .ride = journey.legs[0] else {
            Issue.record("the journey has to start on the vehicle"); return
        }
        #expect(WalkRefinement.estimatedAccessSeconds(journey) == 0)
        #expect(network.timetable.axisSeconds(for: journey.departure) == Int(T.at(8, 0)),
                "sin caminata, salir es subirse")
    }

    @Test("A same-stop transfer needs no walk leg between the two rides, and both rounds are offered")
    func sameStopTransfer() throws {
        let network = try Network()
        let query = RaptorQuery(access: [StopWalk(stop: Int32(network.a), seconds: 0)],
                                egress: [StopWalk(stop: Int32(network.d), seconds: 0)],
                                departure: T.at(7, 0), horizon: 3 * 3_600)
        let result = RaptorEngine().run(network.timetable, query)
        let journeys = JourneyReconstruction.alternatives(
            timetable: network.timetable, result: result, query: query,
            origin: Self.origin, destination: Self.destination, options: PlannerOptions())

        #expect(journeys.count == 2, "the one-vehicle L6 and the two-vehicle L1+L5 both clear the 5-minute bar")
        #expect(journeys.map(\.transfers) == [1, 0], "sorted soonest arrival first")

        let changed = journeys[0]
        // Dos tramos y no cuatro: los extremos van con caminata de cero segundos, que desde
        // `negligibleWalkSeconds` deja de ser un tramo. Lo que este test mira es que entre
        // los dos autobuses no aparezca ninguno.
        #expect(changed.legs.count == 2, "two rides and nothing between them")
        guard case .ride(_, let firstShort, _, _, _, let firstAlight, _, let firstArrival, _) = changed.legs[0],
              case .ride(_, let secondShort, _, _, let secondBoard, _, let secondDeparture, let secondArrival, _)
                = changed.legs[1]
        else { Issue.record("expected two consecutive rides"); return }
        #expect(firstShort == "L1"); #expect(secondShort == "L5")
        #expect(firstAlight.id == secondBoard.id, "same stop, no footpath")
        #expect(network.timetable.axisSeconds(for: firstArrival) == Int(T.at(8, 20)))
        #expect(network.timetable.axisSeconds(for: secondDeparture) == Int(T.at(8, 21)))
        #expect(network.timetable.axisSeconds(for: secondArrival) == Int(T.at(8, 31)))

        let direct = journeys[1]
        #expect(direct.legs.count == 1)
        #expect(network.timetable.axisSeconds(for: direct.arrival) == Int(T.at(9, 40)))
    }

    @Test("A walking transfer becomes its own leg between the two rides")
    func walkingTransfer() throws {
        let network = try Network()
        let options = PlannerOptions(minTransferSeconds: 3_600, footpathBufferSeconds: 30)
        let query = RaptorQuery(access: [StopWalk(stop: Int32(network.a), seconds: 0)],
                                egress: [StopWalk(stop: Int32(network.d), seconds: 0)],
                                departure: T.at(7, 0), horizon: 3 * 3_600)
        let result = RaptorEngine(options: options).run(network.timetable, query)
        let journeys = JourneyReconstruction.alternatives(
            timetable: network.timetable, result: result, query: query,
            origin: Self.origin, destination: Self.destination, options: options)

        guard let journey = journeys.first else { Issue.record("expected a journey"); return }
        // Tres y no cinco: los dos extremos son caminatas de cero segundos, que ya no son
        // tramos. El del medio, que es el que este test mira, sí lo es.
        #expect(journey.legs.count == 3, "ride, walk transfer, ride")
        guard case .ride(_, _, _, _, _, let firstAlight, _, _, _) = journey.legs[0],
              case .walk(let from, let to, let seconds, let metres) = journey.legs[1],
              case .ride(_, _, _, _, let secondBoard, _, _, _, _) = journey.legs[2]
        else { Issue.record("expected ride, walk, ride"); return }

        #expect(firstAlight.id == StopID("1003"), "alights at C")
        guard case .stop(let fromStop) = from, case .stop(let toStop) = to else {
            Issue.record("both ends of a transfer walk are stops"); return
        }
        #expect(fromStop.id == StopID("1003"))
        #expect(toStop.id == StopID("1004"), "walks to C's twin")
        #expect(secondBoard.id == StopID("1004"))
        #expect(seconds == WalkModel(options: options).seconds(metres: 40, as: .transfer))
        #expect(abs(metres - 40) < 1, "recovered from seconds, so only approximate")
        #expect(network.timetable.axisSeconds(for: journey.arrival) == Int(T.at(8, 40)))
    }

    // MARK: - Backward fit, on a network built to expose it

    /// One pattern with three evenly-spaced trips into a single fixed connection: the
    /// earliest-arrival search boards the 08:00, which is twenty minutes earlier than it
    /// needs to be. The backward-fit pass should replace it with the 08:10 — the latest
    /// trip that still makes the 08:31 onward.
    private static func backwardFitTimetable() -> (timetable: Timetable, a: Int, c: Int, d: Int) {
        let stops = [
            PlannerFixture.stop("BF1", name: "A"),
            PlannerFixture.stop("BF2", name: "C"),
            PlannerFixture.stop("BF3", name: "D"),
        ]
        var stopIndexByID: [StopID: Int32] = [:]
        for (index, stop) in stops.enumerated() { stopIndexByID[stop.id] = Int32(index) }

        // Pattern 0: A -> C, three trips five minutes apart.
        let pattern0Times: [(Int32, Int32)] = [
            (T.at(8, 0), T.at(8, 0)), (T.at(8, 20), T.at(8, 20)),
        ]
        _ = pattern0Times // (kept for documentation; times are built explicitly below)

        var tripArrival: [Int32] = []
        var tripDeparture: [Int32] = []
        var tripRefs: [TripRef] = []
        let offsets: [Int32] = [0, 300, 600] // 08:00, 08:05, 08:10
        for (index, offset) in offsets.enumerated() {
            tripRefs.append(TripRef(tripID: TripID("P0T\(index)"),
                                    serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                                    dayOffsetSeconds: 0, headsign: nil))
            tripDeparture.append(T.at(8, 0) &+ offset); tripArrival.append(T.at(8, 0) &+ offset)
            tripDeparture.append(T.at(8, 20) &+ offset); tripArrival.append(T.at(8, 20) &+ offset)
        }
        // Pattern 1: C -> D, one trip.
        tripRefs.append(TripRef(tripID: TripID("P1T0"), serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                                dayOffsetSeconds: 0, headsign: nil))
        let pattern1TimesStart = tripArrival.count
        tripDeparture.append(T.at(8, 31)); tripArrival.append(T.at(8, 31))
        tripDeparture.append(T.at(8, 40)); tripArrival.append(T.at(8, 40))

        let timetable = Timetable(
            stops: stops, stopIndexByID: stopIndexByID,
            patternStopsOffset: [0, 2, 4], patternStops: [0, 1, 1, 2],
            patternTripsOffset: [0, 3, 4], tripRefs: tripRefs,
            patternTimesOffset: [0, 6, Int32(pattern1TimesStart) + 2],
            tripArrival: tripArrival, tripDeparture: tripDeparture,
            patternRouteID: [RouteID("R0"), RouteID("R1")],
            patternRouteShortName: ["P0", "P1"],
            stopPatternsOffset: [0, 1, 3, 4],
            stopPatternPattern: [0, 0, 1, 1], stopPatternPosition: [0, 1, 0, 1],
            footpathOffset: [0, 0, 0, 0], footpathTarget: [], footpathSeconds: [],
            anchorDay: ServiceDate(yyyymmdd: 20_260_101), anchorMidnight: Date(timeIntervalSince1970: 0),
            coveredDays: [ServiceDate(yyyymmdd: 20_260_101)], coveredDaySources: [.observed],
            feedFingerprint: nil)

        return (timetable, 0, 1, 2)
    }

    @Test("Backward fit boards the latest trip that still makes the fixed connection")
    func backwardFit() throws {
        let (timetable, a, c, d) = Self.backwardFitTimetable()
        _ = c
        let query = RaptorQuery(access: [StopWalk(stop: Int32(a), seconds: 0)],
                                egress: [StopWalk(stop: Int32(d), seconds: 0)],
                                departure: T.at(7, 0), horizon: 3 * 3_600)
        let options = PlannerOptions(minTransferSeconds: 60)
        let result = RaptorEngine(options: options).run(timetable, query)
        let journeys = JourneyReconstruction.alternatives(
            timetable: timetable, result: result, query: query,
            origin: Self.origin, destination: Self.destination, options: options)

        #expect(journeys.count == 1)
        guard let journey = journeys.first, journey.legs.count == 2 else {
            Issue.record("expected two rides, with no walk at either end"); return
        }
        guard case .ride(_, _, _, _, _, _, let firstDeparture, let firstArrival, _) = journey.legs[0],
              case .ride(_, _, _, _, _, _, let secondDeparture, _, _) = journey.legs[1]
        else { Issue.record("expected two rides"); return }

        #expect(timetable.axisSeconds(for: firstDeparture) == Int(T.at(8, 10)),
                "not the 08:00 RAPTOR's own earliest-arrival search would board")
        #expect(timetable.axisSeconds(for: firstArrival) == Int(T.at(8, 30)))
        #expect(timetable.axisSeconds(for: secondDeparture) == Int(T.at(8, 31)))
        #expect(timetable.axisSeconds(for: journey.departure) == Int(T.at(8, 10)),
                "the passenger is told to leave twenty minutes later than before")
        #expect(timetable.axisSeconds(for: journey.arrival) == Int(T.at(8, 40)), "arrival is unchanged")
    }

    // MARK: - A chain that ends on foot (Auditoría RAPTOR, Tanda 1: H-01, H-02, H-06)

    /// One ride, then a single transfer walk to the egress stop: the smallest network where
    /// the chosen way out is a hop away from where the vehicle actually alights, so the
    /// chain ends on foot rather than at a stop the ride itself served.
    private static func trailingWalkTimetable() -> (timetable: Timetable, r0: Int, r1: Int, r2: Int) {
        let stops = [
            PlannerFixture.stop("TW0", name: "R0"), PlannerFixture.stop("TW1", name: "R1"),
            PlannerFixture.stop("TW2", name: "R2"),
        ]
        var stopIndexByID: [StopID: Int32] = [:]
        for (index, stop) in stops.enumerated() { stopIndexByID[stop.id] = Int32(index) }

        let timetable = Timetable(
            stops: stops, stopIndexByID: stopIndexByID,
            patternStopsOffset: [0, 2], patternStops: [0, 1],
            patternTripsOffset: [0, 1],
            tripRefs: [TripRef(tripID: TripID("L1#0"), serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                               dayOffsetSeconds: 0, headsign: nil)],
            patternTimesOffset: [0],
            tripArrival: [T.at(9, 0), T.at(9, 10)], tripDeparture: [T.at(9, 0), T.at(9, 10)],
            patternRouteID: [RouteID("RL1")], patternRouteShortName: ["L1"],
            stopPatternsOffset: [0, 1, 2, 2],
            stopPatternPattern: [0, 0], stopPatternPosition: [0, 1],
            footpathOffset: [0, 0, 1, 2], footpathTarget: [2, 1], footpathSeconds: [120, 120],
            anchorDay: ServiceDate(yyyymmdd: 20_260_101), anchorMidnight: Date(timeIntervalSince1970: 0),
            coveredDays: [ServiceDate(yyyymmdd: 20_260_101)], coveredDaySources: [.observed],
            feedFingerprint: nil)
        return (timetable, 0, 1, 2)
    }

    /// H-01: `Journey.arrival` was the last ride's own arrival plus the egress walk only,
    /// silently dropping any transfer walk in between — understating the headline time by
    /// exactly that walk while the leg list underneath it kept showing the full one.
    @Test("A trailing transfer walk after the last ride counts toward the arrival")
    func trailingWalkCountsTowardArrival() throws {
        let (timetable, r0, _, r2) = Self.trailingWalkTimetable()
        let query = RaptorQuery(access: [StopWalk(stop: Int32(r0), seconds: 0)],
                                egress: [StopWalk(stop: Int32(r2), seconds: 60)],
                                departure: T.at(9, 0), horizon: 3 * 3_600)
        let result = RaptorEngine().run(timetable, query)
        let journeys = JourneyReconstruction.alternatives(
            timetable: timetable, result: result, query: query,
            origin: Self.origin, destination: Self.destination, options: PlannerOptions())

        #expect(journeys.count == 1)
        guard let journey = journeys.first else { return }
        #expect(journey.legs.count == 3, "ride, transfer walk, walk out — the access walk is zero")
        #expect(journey.arrival == timetable.date(forAxisSeconds: Int(T.at(9, 10)) + 120 + 60),
                "the ride's own 09:10 plus the 120 s transfer walk its legs already show, plus the 60 s egress walk")
    }

    /// Two independent lines feeding a chain of two footpaths, with the second line's own
    /// ride beaten by a walk from the first. L1: S0 → S1 (arrives 09:10). L2: S4 → S2
    /// (arrives 09:20). S1↔S2 is a 120 s footpath, S2↔S3 a 60 s one. S1's ride beats S2's
    /// own by more than the 120 s footpath costs, so the walk-relaxation loop overwrites
    /// S2's `parent` to say it was walked into from S1 — a real, valid arrival on its own,
    /// just not the one that goes on to reach S3. The walk out of S2 that reaches S3 is
    /// computed from S2's *ride* (09:20 + 60 s = 09:21), and following the wrong parent back
    /// from S3 would report the journey as L1 plus a two-footpath hike through S1, when the
    /// engine only ever walked once.
    private static func rideOverwrittenByWalkTimetable()
        -> (timetable: Timetable, s0: Int, s1: Int, s2: Int, s3: Int, s4: Int) {
        let stops = [
            PlannerFixture.stop("RB0", name: "S0"), PlannerFixture.stop("RB1", name: "S1"),
            PlannerFixture.stop("RB2", name: "S2"), PlannerFixture.stop("RB3", name: "S3"),
            PlannerFixture.stop("RB4", name: "S4"),
        ]
        var stopIndexByID: [StopID: Int32] = [:]
        for (index, stop) in stops.enumerated() { stopIndexByID[stop.id] = Int32(index) }

        let timetable = Timetable(
            stops: stops, stopIndexByID: stopIndexByID,
            patternStopsOffset: [0, 2, 4], patternStops: [0, 1, 4, 2],
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
            stopPatternsOffset: [0, 1, 2, 3, 3, 4],
            stopPatternPattern: [0, 0, 1, 1], stopPatternPosition: [0, 1, 1, 0],
            footpathOffset: [0, 0, 1, 3, 4, 4],
            footpathTarget: [2, 1, 3, 2], footpathSeconds: [120, 120, 60, 60],
            anchorDay: ServiceDate(yyyymmdd: 20_260_101), anchorMidnight: Date(timeIntervalSince1970: 0),
            coveredDays: [ServiceDate(yyyymmdd: 20_260_101)], coveredDaySources: [.observed],
            feedFingerprint: nil)
        return (timetable, 0, 1, 2, 3, 4)
    }

    /// H-02: reconstruction followed a stop's *current* `parent`, which a later footpath in
    /// the same round can overwrite, instead of the `rideParent` snapshot that survives it.
    @Test("Reconstruction follows the ride RAPTOR took, not whatever last overwrote a stop's parent")
    func rideSurvivesAWalkThatOverwritesItsParent() throws {
        let (timetable, s0, _, _, s3, s4) = Self.rideOverwrittenByWalkTimetable()
        let query = RaptorQuery(
            access: [StopWalk(stop: Int32(s0), seconds: 0), StopWalk(stop: Int32(s4), seconds: 0)],
            egress: [StopWalk(stop: Int32(s3), seconds: 30)],
            departure: T.at(9, 0), horizon: 3 * 3_600)
        let result = RaptorEngine().run(timetable, query)
        let journeys = JourneyReconstruction.alternatives(
            timetable: timetable, result: result, query: query,
            origin: Self.origin, destination: Self.destination, options: PlannerOptions())

        #expect(journeys.count == 1)
        guard let journey = journeys.first else { return }
        #expect(journey.legs.count == 3, "one ride, one transfer walk, one egress walk")

        guard case .ride(_, let shortName, _, _, let board, _, _, _, _) = journey.legs[0] else {
            Issue.record("expected a single ride"); return
        }
        #expect(shortName == "L2", "the ride that actually reaches S2, not L1 via the overwritten parent")
        #expect(board.id == StopID("RB4"), "boards where L2 boards — not S0, L1's stop")

        guard case .walk(let from, let to, let seconds, _) = journey.legs[1] else {
            Issue.record("expected a single transfer walk"); return
        }
        guard case .stop(let fromStop) = from, case .stop(let toStop) = to else {
            Issue.record("both ends of the transfer walk are stops"); return
        }
        #expect(fromStop.id == StopID("RB2"), "walks from S2, its real ride's stop — not from S1")
        #expect(toStop.id == StopID("RB3"))
        #expect(seconds == 60, "one hop, not a chain through S1")

        #expect(journey.arrival == timetable.date(forAxisSeconds: Int(T.at(9, 20)) + 60 + 30),
                "S2's own ride (09:20) plus the transfer and egress walks — S1's ride plays no part")
    }

    /// H-06: the backward walk over `parent`/`rideParent` had no bound of its own — a
    /// `.walk` step never advances `currentRound`, so nothing but such a bound stops two
    /// stops that (however it happened) each point at the other from looping forever. This
    /// state cannot arise through `RaptorEngine.run` today — its `rideParent` snapshot only
    /// ever holds a `.ride` — but `reconstruct` has to survive it regardless of how it got
    /// there, which is why the `RaptorResult` here is fabricated by hand rather than run.
    @Test("A cycle of mutual walk parents does not loop forever")
    func walkCycleTerminates() throws {
        let stopCount = 3
        var arrival = [Int32](repeating: RaptorResult.unreached, count: 2 * stopCount)
        var parent = [RaptorParent?](repeating: nil, count: 2 * stopCount)
        arrival[0] = 0
        parent[0] = .access(seconds: 0)
        arrival[stopCount + 1] = 600
        parent[stopCount + 1] = .walk(from: 2, seconds: 0)
        arrival[stopCount + 2] = 600
        parent[stopCount + 2] = .walk(from: 1, seconds: 0)
        let result = RaptorResult(stopCount: stopCount, roundsRun: 1, arrival: arrival,
                                  parent: parent, bestArrival: [0, 600, 600], rideParent: parent)
        let query = RaptorQuery(access: [StopWalk(stop: 0, seconds: 0)],
                                egress: [StopWalk(stop: 2, seconds: 30)], departure: 0, horizon: 10_800)

        let journeys = JourneyReconstruction.alternatives(
            timetable: try Network().timetable, result: result, query: query,
            origin: Self.origin, destination: Self.destination, options: PlannerOptions())
        #expect(journeys.isEmpty, "a cyclic parent graph describes no real journey")
    }

    // MARK: - Alternative selection

    /// Two independent one-vehicle routes to the same destination: a direct one and a
    /// two-vehicle one departing the same access stop. The size of the two-vehicle route's
    /// saving is the only thing that changes between the two networks below.
    private static func thresholdTimetable(secondLegArrival: Int32) -> (timetable: Timetable, a: Int, d: Int) {
        let stops = [
            PlannerFixture.stop("TH1", name: "A"),
            PlannerFixture.stop("TH2", name: "C"),
            PlannerFixture.stop("TH3", name: "D"),
        ]
        var stopIndexByID: [StopID: Int32] = [:]
        for (index, stop) in stops.enumerated() { stopIndexByID[stop.id] = Int32(index) }

        var tripArrival: [Int32] = []
        var tripDeparture: [Int32] = []
        var tripRefs: [TripRef] = []

        // Pattern 0: A -> D direct, one vehicle, arrives 08:00.
        tripRefs.append(TripRef(tripID: TripID("DIRECT"), serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                                dayOffsetSeconds: 0, headsign: nil))
        tripDeparture.append(T.at(7, 0)); tripArrival.append(T.at(7, 0))
        tripDeparture.append(T.at(8, 0)); tripArrival.append(T.at(8, 0))
        let pattern0TimesOffset: Int32 = 0

        // Pattern 1: A -> C, arrives in time to catch pattern 2.
        tripRefs.append(TripRef(tripID: TripID("LEG1"), serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                                dayOffsetSeconds: 0, headsign: nil))
        let pattern1TimesOffset = Int32(tripArrival.count)
        tripDeparture.append(T.at(7, 0)); tripArrival.append(T.at(7, 0))
        tripDeparture.append(T.at(7, 20)); tripArrival.append(T.at(7, 20))

        // Pattern 2: C -> D, arriving `secondLegArrival`.
        tripRefs.append(TripRef(tripID: TripID("LEG2"), serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                                dayOffsetSeconds: 0, headsign: nil))
        let pattern2TimesOffset = Int32(tripArrival.count)
        tripDeparture.append(T.at(7, 25)); tripArrival.append(T.at(7, 25))
        tripDeparture.append(secondLegArrival); tripArrival.append(secondLegArrival)

        let timetable = Timetable(
            stops: stops, stopIndexByID: stopIndexByID,
            patternStopsOffset: [0, 2, 4, 6], patternStops: [0, 2, 0, 1, 1, 2],
            patternTripsOffset: [0, 1, 2, 3], tripRefs: tripRefs,
            patternTimesOffset: [pattern0TimesOffset, pattern1TimesOffset, pattern2TimesOffset,
                                 Int32(tripArrival.count)],
            tripArrival: tripArrival, tripDeparture: tripDeparture,
            patternRouteID: [RouteID("R0"), RouteID("R1"), RouteID("R2")],
            patternRouteShortName: ["Direct", "Leg1", "Leg2"],
            // Stop 1 (C) needs both its Leg1-alight slot *and* its Leg2-board slot: without
            // the second, the round that alights Leg1 at C would never discover Leg2 is
            // boardable there, and the two-vehicle route would silently vanish.
            // A: (pattern0,pos0), (pattern1,pos0). C: (pattern1,pos1), (pattern2,pos0).
            // D: (pattern0,pos1), (pattern2,pos1).
            stopPatternsOffset: [0, 2, 4, 6],
            stopPatternPattern: [0, 1, 1, 2, 0, 2], stopPatternPosition: [0, 0, 1, 0, 1, 1],
            footpathOffset: [0, 0, 0, 0], footpathTarget: [], footpathSeconds: [],
            anchorDay: ServiceDate(yyyymmdd: 20_260_101), anchorMidnight: Date(timeIntervalSince1970: 0),
            coveredDays: [ServiceDate(yyyymmdd: 20_260_101)], coveredDaySources: [.observed],
            feedFingerprint: nil)

        return (timetable, 0, 2)
    }

    @Test("An extra transfer that saves less than the threshold is dropped")
    func extraTransferNotWorthIt() throws {
        // Two vehicles arrive at 07:57, saving 180 s over the direct 08:00 — under the
        // default 300 s bar.
        let (timetable, a, d) = Self.thresholdTimetable(secondLegArrival: T.at(7, 57))
        let query = RaptorQuery(access: [StopWalk(stop: Int32(a), seconds: 0)],
                                egress: [StopWalk(stop: Int32(d), seconds: 0)],
                                departure: T.at(6, 0), horizon: 3 * 3_600)
        let options = PlannerOptions(minTransferSeconds: 60)
        let result = RaptorEngine(options: options).run(timetable, query)
        let journeys = JourneyReconstruction.alternatives(
            timetable: timetable, result: result, query: query,
            origin: Self.origin, destination: Self.destination, options: options)

        #expect(journeys.count == 1, "the two-vehicle option is dominated in practice, not just on paper")
        #expect(journeys[0].transfers == 0)
    }

    @Test("An extra transfer that saves at least the threshold is kept")
    func extraTransferWorthIt() throws {
        // Two vehicles arrive at 07:30, saving 1800 s over the direct 08:00.
        let (timetable, a, d) = Self.thresholdTimetable(secondLegArrival: T.at(7, 30))
        let query = RaptorQuery(access: [StopWalk(stop: Int32(a), seconds: 0)],
                                egress: [StopWalk(stop: Int32(d), seconds: 0)],
                                departure: T.at(6, 0), horizon: 3 * 3_600)
        let options = PlannerOptions(minTransferSeconds: 60)
        let result = RaptorEngine(options: options).run(timetable, query)
        let journeys = JourneyReconstruction.alternatives(
            timetable: timetable, result: result, query: query,
            origin: Self.origin, destination: Self.destination, options: options)

        #expect(journeys.count == 2)
        #expect(journeys.map(\.transfers) == [1, 0])
    }

    /// El tope de la reconstrucción es `maxCandidates` desde la Fase 10, no `maxAlternatives`:
    /// esto produce el conjunto entre el que la preferencia del usuario elige, y
    /// `maxAlternatives` pasa a ser cuántas se enseñan. El comportamiento probado —que hay un
    /// tope y que se queda con la llegada más temprana— es el mismo.
    @Test("The list of alternatives is capped by maxCandidates")
    func capIsRespected() throws {
        // The same network that yields two alternatives, asked for one.
        let (timetable, a, d) = Self.thresholdTimetable(secondLegArrival: T.at(7, 30))
        let query = RaptorQuery(access: [StopWalk(stop: Int32(a), seconds: 0)],
                                egress: [StopWalk(stop: Int32(d), seconds: 0)],
                                departure: T.at(6, 0), horizon: 3 * 3_600)
        let options = PlannerOptions(minTransferSeconds: 60, maxCandidates: 1)
        let result = RaptorEngine(options: options).run(timetable, query)
        let journeys = JourneyReconstruction.alternatives(
            timetable: timetable, result: result, query: query,
            origin: Self.origin, destination: Self.destination, options: options)

        #expect(journeys.count == 1)
        #expect(journeys[0].transfers == 1, "the cap keeps the soonest arrival, not the first found")
    }
}
