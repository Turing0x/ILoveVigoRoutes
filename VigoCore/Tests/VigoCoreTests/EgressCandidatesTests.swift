import Foundation
import Testing
@testable import VigoCore

/// Las paradas de bajada que se reconstruyen.
///
/// Es la pieza sin la cual el resto de la Fase 10 es decorativo: si la alternativa que menos te
/// hace andar no llega a generarse, un menú que ordena por caminata reordena opciones elegidas
/// todas por rapidez.
@Suite("Candidatos de bajada")
struct EgressCandidatesTests {

    private static let origin = Place.coordinate(PlannerFixture.base, label: "Origen")
    private static let destination = Place.coordinate(
        Coordinate(PlannerFixture.stop("DST", northMetres: 2_000)), label: "Destino")

    private func at(_ hour: Int, _ minute: Int) -> Int32 { Int32(hour * 3_600 + minute * 60) }

    /// L1 sale de A a las 08:00, pasa por B a las 08:10 y llega a C a las 08:20.
    ///
    /// Con estas dos salidas a pie, B y C **se compran una a la otra**: por B se llega antes a
    /// la puerta (08:15) andando cinco minutos; por C se llega más tarde (08:21) andando uno.
    /// Ninguna domina a la otra, así que las dos son respuestas legítimas a preguntas
    /// distintas.
    private func network() throws -> (timetable: Timetable, a: Int, b: Int, c: Int) {
        let timetable = try PlannerFixture.networkTimetable()
        return (timetable,
                PlannerFixture.index(of: "1001", in: timetable),
                PlannerFixture.index(of: "1002", in: timetable),
                PlannerFixture.index(of: "1003", in: timetable))
    }

    private func query(_ n: (timetable: Timetable, a: Int, b: Int, c: Int),
                       egress: [StopWalk]) -> RaptorQuery {
        RaptorQuery(access: [StopWalk(stop: Int32(n.a), seconds: 0)],
                    egress: egress, departure: at(7, 0), horizon: 3 * 3_600)
    }

    /// **El test de esta fase.** Con el comportamiento anterior —una sola parada de bajada por
    /// ronda, la de llegada mínima— solo existiría el trayecto que baja en B.
    @Test("Una parada que llega más tarde pero deja más cerca también se reconstruye")
    func theCloserStopIsGenerated() throws {
        let n = try network()
        let q = query(n, egress: [StopWalk(stop: Int32(n.b), seconds: 300),
                                  StopWalk(stop: Int32(n.c), seconds: 60)])
        let result = RaptorEngine().run(n.timetable, q)
        let journeys = JourneyReconstruction.alternatives(
            timetable: n.timetable, result: result, query: q,
            origin: Self.origin, destination: Self.destination, options: PlannerOptions())

        try #require(journeys.count == 2, "la rápida y la que deja más cerca")

        let walks = journeys.map(JourneyOrdering.egressWalkSeconds).sorted()
        #expect(walks == [60, 300])

        let closest = try #require(
            JourneyOrdering.leastWalkAtEnd.apply(journeys, limit: 1).first)
        guard case .walk(let from, _, let seconds, _) = closest.legs.last else {
            Issue.record("el último tramo tiene que ser a pie"); return
        }
        #expect(seconds == 60)
        #expect(from == .stop(n.timetable.stops[n.c]), "baja en C, la parada de al lado del destino")
    }

    /// L1: S0 → S1 (lejos del portal, 900 s a pie), llega 09:10. L2: S1 → S2 (al lado del
    /// portal, 30 s a pie), llega 09:30 — un segundo vehículo, tomado en el mismo S1 sin
    /// caminar. L2 solo existe para que llegar a S2 cueste una **segunda** ronda, mientras S1
    /// ya es alcanzable en la primera: `targetBest`, apretado tras la ronda 1 con los 900 s de
    /// S1, bloqueaba la llegada —mucho más tardía— de S2 aunque su propia caminata sea mínima
    /// (H-03: podar con la caminata de un candidato distinto, que «menos caminata» no conoce).
    private func farThenCloseTimetable() -> (timetable: Timetable, s0: Int, s1: Int, s2: Int) {
        let stops = [
            PlannerFixture.stop("FC0", name: "S0"), PlannerFixture.stop("FC1", eastMetres: 2_000, name: "S1"),
            PlannerFixture.stop("FC2", eastMetres: 2_600, name: "S2"),
        ]
        var stopIndexByID: [StopID: Int32] = [:]
        for (index, stop) in stops.enumerated() { stopIndexByID[stop.id] = Int32(index) }

        let timetable = Timetable(
            stops: stops, stopIndexByID: stopIndexByID,
            patternStopsOffset: [0, 2, 4], patternStops: [0, 1, 1, 2],
            patternTripsOffset: [0, 1, 2],
            tripRefs: [
                TripRef(tripID: TripID("L1#0"), serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                        dayOffsetSeconds: 0, headsign: nil),
                TripRef(tripID: TripID("L2#0"), serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                        dayOffsetSeconds: 0, headsign: nil),
            ],
            patternTimesOffset: [0, 2],
            tripArrival: [at(9, 0), at(9, 10), at(9, 20), at(9, 30)],
            tripDeparture: [at(9, 0), at(9, 10), at(9, 20), at(9, 30)],
            patternRouteID: [RouteID("RL1"), RouteID("RL2")], patternRouteShortName: ["L1", "L2"],
            stopPatternsOffset: [0, 1, 3, 4],
            stopPatternPattern: [0, 0, 1, 1], stopPatternPosition: [0, 1, 0, 1],
            footpathOffset: [0, 0, 0, 0], footpathTarget: [], footpathSeconds: [],
            anchorDay: ServiceDate(yyyymmdd: 20_260_101), anchorMidnight: Date(timeIntervalSince1970: 0),
            coveredDays: [ServiceDate(yyyymmdd: 20_260_101)], coveredDaySources: [.observed],
            feedFingerprint: nil)
        return (timetable, 0, 1, 2)
    }

    /// H-03: sin esta corrección, `result.arrival(round: 2, stop: s2)` es `nil` y
    /// `egressCandidates` solo devuelve la parada de 900 s — la única alternativa ofrecida
    /// hace andar quince minutos aunque la de 30 s sea perfectamente alcanzable.
    @Test("Una parada alcanzable en una ronda posterior no se pierde por la poda del objetivo")
    func laterRoundIsNotPrunedByAnEarlierCandidatesWalk() throws {
        let n = farThenCloseTimetable()
        let query = RaptorQuery(access: [StopWalk(stop: Int32(n.s0), seconds: 0)],
                                egress: [StopWalk(stop: Int32(n.s1), seconds: 900),
                                         StopWalk(stop: Int32(n.s2), seconds: 30)],
                                departure: at(9, 0), horizon: 3 * 3_600)
        let result = RaptorEngine().run(n.timetable, query)

        #expect(result.roundsRun == 2)
        #expect(result.arrival(round: 2, stop: n.s2) == at(9, 30))

        let candidates = JourneyReconstruction.egressCandidates(
            upTo: result.roundsRun, result: result, query: query, limit: 3)
        #expect(candidates.count == 2, "la parada de 900 s y la de 30 s, ninguna descartada")
        #expect(Set(candidates.map(\.stop)) == Set([n.s1, n.s2]))
    }

    /// Una parada que llega más tarde **y** deja más lejos no compra nada, y el frente no está
    /// para llenarse de basura: cada sitio que ocupa se lo quita a un candidato bueno.
    @Test("Una parada peor en los dos ejes no entra en el frente")
    func dominatedStopsAreExcluded() throws {
        let n = try network()
        // B a 300 s (llega 08:15), C a 60 s (llega 08:21) y B otra vez no se puede repetir, así
        // que la dominada es C con una caminata larga: llega después que B y anda más.
        let q = query(n, egress: [StopWalk(stop: Int32(n.b), seconds: 300),
                                  StopWalk(stop: Int32(n.c), seconds: 900)])
        let result = RaptorEngine().run(n.timetable, q)

        let front = JourneyReconstruction.egressCandidates(
            upTo: 1, result: result, query: q, limit: 3)

        try #require(front.count == 1)
        #expect(front[0].stop == n.b)
    }

    /// El corte del frente por su cabeza tiraría justo la cola —la de menos caminata—, que es
    /// para lo que existe todo esto.
    ///
    /// Hacen falta **tres** en el frente para que se note: con dos, recortar por la cabeza y
    /// recortar por los dos extremos dan lo mismo, y la mutación pasa desapercibida. Es la misma
    /// trampa que este proyecto lleva anotada desde la Fase 3 — un dato de prueba cómodo no
    /// expone el fallo.
    ///
    /// En ronda 1, saliendo de A a las 07:00: B a las 08:10 (L1), C a las 08:20 (L1) y D a las
    /// 09:40 (L6, que sale de A a las 09:00). Con caminatas de 500, 120 y 30 segundos, las
    /// llegadas a la puerta crecen y las caminatas decrecen: los tres están en el frente.
    @Test("Al recortar el frente se conservan los dos extremos, no los primeros")
    func trimKeepsBothEnds() throws {
        let n = try network()
        let timetable = n.timetable
        let d = PlannerFixture.index(of: "1005", in: timetable)
        let q = query(n, egress: [StopWalk(stop: Int32(n.b), seconds: 500),
                                  StopWalk(stop: Int32(n.c), seconds: 120),
                                  StopWalk(stop: Int32(d), seconds: 30)])
        let result = RaptorEngine().run(timetable, q)

        let whole = JourneyReconstruction.egressCandidates(
            upTo: 1, result: result, query: q, limit: 3)
        try #require(whole.count == 3, "los tres se compran unos a otros")

        let two = JourneyReconstruction.egressCandidates(
            upTo: 1, result: result, query: q, limit: 2)
        try #require(two.count == 2)
        #expect(Set(two.map(\.stop)) == Set([n.b, d]),
                "el más rápido y el que menos anda; recortar por la cabeza se quedaría con B y C")

        let one = JourneyReconstruction.egressCandidates(
            upTo: 1, result: result, query: q, limit: 1)
        #expect(one.map(\.stop) == [n.b], "con sitio para uno, el más rápido")
    }

    /// Un sitio al que se llega sin coger nada es la respuesta a pie, y `reconstruct` no puede
    /// describirlo: todo lo que hace a partir de ahí supone al menos un autobús, empezando por
    /// `rides[rides.count - 1]`. Pasa de verdad cuando origen y destino están cerca, porque
    /// entonces una misma parada está en las dos listas.
    @Test("Un candidato al que se llega sin coger ningún autobús no produce trayecto")
    func candidatesWithoutARideAreDropped() throws {
        let n = try network()
        // A es a la vez el acceso y una supuesta salida, a un paso del destino.
        let q = query(n, egress: [StopWalk(stop: Int32(n.a), seconds: 30),
                                  StopWalk(stop: Int32(n.c), seconds: 60)])
        let result = RaptorEngine().run(n.timetable, q)

        let journeys = JourneyReconstruction.alternatives(
            timetable: n.timetable, result: result, query: q,
            origin: Self.origin, destination: Self.destination, options: PlannerOptions())

        // Ni revienta ni inventa un trayecto en autobús sin autobuses.
        #expect(journeys.allSatisfy { $0.transfers >= 0 })
        for journey in journeys {
            #expect(journey.legs.contains { if case .ride = $0 { true } else { false } },
                    "un trayecto reconstruido siempre lleva al menos un autobús")
        }
    }

    /// Una línea de doce paradas, cada una 120 s después que la anterior y cada una un poco
    /// más cerca del destino: las doce se compran unas a otras (llegada creciente, caminata
    /// decreciente) y ninguna domina a otra, así que el frente entero tiene doce candidatos.
    private func longLineTimetable(stops count: Int) -> (timetable: Timetable, egressStops: [Int]) {
        var stops: [Stop] = [PlannerFixture.stop("LL0", name: "Origen")]
        for index in 1...count {
            stops.append(PlannerFixture.stop("LL\(index)", eastMetres: Double(index) * 300, name: "P\(index)"))
        }
        var stopIndexByID: [StopID: Int32] = [:]
        for (index, stop) in stops.enumerated() { stopIndexByID[stop.id] = Int32(index) }

        let times: [Int32] = (0...count).map { at(9, 0) + Int32($0) * 120 }
        let timetable = Timetable(
            stops: stops, stopIndexByID: stopIndexByID,
            patternStopsOffset: [0, Int32(count + 1)], patternStops: (0...count).map(Int32.init),
            patternTripsOffset: [0, 1],
            tripRefs: [TripRef(tripID: TripID("L1#0"), serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                               dayOffsetSeconds: 0, headsign: nil)],
            patternTimesOffset: [0],
            tripArrival: times, tripDeparture: times,
            patternRouteID: [RouteID("RL1")], patternRouteShortName: ["L1"],
            stopPatternsOffset: (0...(count + 1)).map(Int32.init),
            stopPatternPattern: Array(repeating: Int32(0), count: count + 1),
            stopPatternPosition: (0...count).map(Int32.init),
            footpathOffset: Array(repeating: Int32(0), count: count + 2),
            footpathTarget: [], footpathSeconds: [],
            anchorDay: ServiceDate(yyyymmdd: 20_260_101), anchorMidnight: Date(timeIntervalSince1970: 0),
            coveredDays: [ServiceDate(yyyymmdd: 20_260_101)], coveredDaySources: [.observed],
            feedFingerprint: nil)
        return (timetable, Array(1...count))
    }

    /// H-04: `alternatives` terminaba con `.sorted { $0.arrival < $1.arrival }.prefix(maxCandidates)`
    /// — el mismo sesgo por llegada que la Fase 10 existe para quitar, solo que un nivel más
    /// abajo. Con doce candidatos y `maxCandidates = 8`, ese `prefix` se queda con las ocho
    /// paradas que antes llegan y tira las cuatro que menos andan — exactamente las que
    /// `egressCandidates` se ha esforzado en generar.
    @Test("El corte de alternatives conserva el óptimo de caminata, no solo los primeros por llegada")
    func alternativesCutDoesNotFavourArrival() throws {
        let n = longLineTimetable(stops: 12)
        let options = PlannerOptions(maxEgressCandidates: 12)
        // La parada 1 anda 1200 s, la 12 anda 100 s: decreciente al revés de la llegada.
        let egress = n.egressStops.map { StopWalk(stop: Int32($0), seconds: Int32((13 - $0) * 100)) }
        let query = RaptorQuery(access: [StopWalk(stop: 0, seconds: 0)],
                                egress: egress, departure: at(9, 0), horizon: 3 * 3_600)
        let result = RaptorEngine(options: options).run(n.timetable, query)

        let front = JourneyReconstruction.egressCandidates(
            upTo: result.roundsRun, result: result, query: query, limit: options.maxEgressCandidates)
        try #require(front.count == 12, "las doce se compran unas a otras: nada domina a nada")

        var cutOptions = options
        cutOptions.maxCandidates = 8
        let journeys = JourneyReconstruction.alternatives(
            timetable: n.timetable, result: result, query: query,
            origin: Self.origin, destination: Self.destination, options: cutOptions)

        #expect(journeys.count == 8)
        #expect(journeys.map(JourneyOrdering.egressWalkSeconds).min() == 100,
                "la parada que menos anda tiene que sobrevivir al corte; un prefix por llegada la habría tirado")
    }

    /// H-18: three independent one-hop patterns arrive three different exits at the exact
    /// same instant, each with the exact same walk out — tied on both axes at once, so
    /// nothing in the dominance filter or the sort's own comparator breaks the tie.
    /// `Array.sorted` is not documented as stable, and without an explicit tiebreak `trim`'s
    /// choice of which two of the three survive would rest on an implementation detail.
    private func tiedThreeWaysTimetable() -> (timetable: Timetable, exits: [Int]) {
        let stops = (0..<6).map { PlannerFixture.stop("TT\($0)", eastMetres: Double($0) * 200) }
        var stopIndexByID: [StopID: Int32] = [:]
        for (index, stop) in stops.enumerated() { stopIndexByID[stop.id] = Int32(index) }
        // Patterns 0..2: access stop 2k boards straight onto exit stop 2k+1, all arriving
        // at the same instant.
        var patternStopsOffset: [Int32] = [0]
        var patternStops: [Int32] = []
        var patternTripsOffset: [Int32] = [0]
        var tripRefs: [TripRef] = []
        var patternTimesOffset: [Int32] = []
        var tripArrival: [Int32] = []
        var tripDeparture: [Int32] = []
        var patternRouteID: [RouteID] = []
        var patternRouteShortName: [String] = []
        var stopPatternPattern: [Int32] = Array(repeating: 0, count: 6)
        var stopPatternPosition: [Int32] = Array(repeating: 0, count: 6)
        for pattern in 0..<3 {
            let access = pattern * 2, exit = pattern * 2 + 1
            patternStops.append(contentsOf: [Int32(access), Int32(exit)])
            patternStopsOffset.append(Int32(patternStops.count))
            patternTimesOffset.append(Int32(tripArrival.count))
            tripRefs.append(TripRef(tripID: TripID("T\(pattern)"), serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                                    dayOffsetSeconds: 0, headsign: nil))
            tripArrival.append(contentsOf: [at(9, 0), at(9, 10)])
            tripDeparture.append(contentsOf: [at(9, 0), at(9, 10)])
            patternTripsOffset.append(Int32(tripRefs.count))
            patternRouteID.append(RouteID("R\(pattern)")); patternRouteShortName.append("L\(pattern)")
            stopPatternPattern[access] = Int32(pattern); stopPatternPosition[access] = 0
            stopPatternPattern[exit] = Int32(pattern); stopPatternPosition[exit] = 1
        }
        let timetable = Timetable(
            stops: stops, stopIndexByID: stopIndexByID,
            patternStopsOffset: patternStopsOffset, patternStops: patternStops,
            patternTripsOffset: patternTripsOffset, tripRefs: tripRefs,
            patternTimesOffset: patternTimesOffset, tripArrival: tripArrival, tripDeparture: tripDeparture,
            patternRouteID: patternRouteID, patternRouteShortName: patternRouteShortName,
            stopPatternsOffset: (0...6).map(Int32.init),
            stopPatternPattern: stopPatternPattern, stopPatternPosition: stopPatternPosition,
            footpathOffset: Array(repeating: 0, count: 7), footpathTarget: [], footpathSeconds: [],
            anchorDay: ServiceDate(yyyymmdd: 20_260_101), anchorMidnight: Date(timeIntervalSince1970: 0),
            coveredDays: [ServiceDate(yyyymmdd: 20_260_101)], coveredDaySources: [.observed],
            feedFingerprint: nil)
        return (timetable, [1, 3, 5])
    }

    @Test("A three-way tie on both axes is broken the same way every time")
    func tiedFrontIsBrokenDeterministically() throws {
        let n = tiedThreeWaysTimetable()
        let query = RaptorQuery(
            access: [StopWalk(stop: 0, seconds: 0), StopWalk(stop: 2, seconds: 0), StopWalk(stop: 4, seconds: 0)],
            egress: n.exits.map { StopWalk(stop: Int32($0), seconds: 500) },
            departure: at(9, 0), horizon: 3 * 3_600)
        let result = RaptorEngine().run(n.timetable, query)

        let front = JourneyReconstruction.egressCandidates(upTo: 1, result: result, query: query, limit: 3)
        try #require(front.count == 3, "all three tie on arrival and on walk, so none dominates the others")

        let trimmed = JourneyReconstruction.egressCandidates(upTo: 1, result: result, query: query, limit: 2)
        #expect(trimmed.map(\.stop) == [1, 5],
                "lowest and highest stop index, the documented tiebreak — not whatever order the sort left them in")
    }
}
