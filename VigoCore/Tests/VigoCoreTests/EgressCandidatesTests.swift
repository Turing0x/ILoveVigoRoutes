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
}
