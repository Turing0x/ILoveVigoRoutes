import Foundation
import Testing
@testable import VigoCore

/// La geometría a pie de un trayecto: lo que el mapa no dibujaba.
///
/// Hasta la Fase 8, `JourneyTraceBuilder` se saltaba todo tramo que no fuera `.ride`, así que
/// el trazado del autobús flotaba sin nada que lo uniera a los dos extremos y un trayecto
/// `walkOnly` no dibujaba absolutamente nada.
@Suite("Tramos a pie de un trayecto")
struct JourneyWalkSegmentsTests {

    private let base = Date(timeIntervalSince1970: 1_757_000_000)

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private var origin: Place {
        .coordinate(Coordinate(latitude: 42.20, longitude: -8.75), label: "Origen")
    }

    private var destination: Place {
        .coordinate(Coordinate(latitude: 42.25, longitude: -8.70), label: "Destino")
    }

    private func ride(_ line: String, from: Stop, to: Stop) -> JourneyLeg {
        .ride(routeID: RouteID("r\(line)"), routeShortName: line, headsign: nil,
              tripID: TripID("t\(line)"), board: from, alight: to,
              departure: at(2), arrival: at(15), intermediateStops: [])
    }

    /// El caso peor del defecto: sin ningún tramo en bus no había trazas, así que el mapa
    /// enseñaba dos marcadores y un hueco entre ellos.
    @Test("Un trayecto solo a pie produce un segmento, no ninguno")
    func walkOnlyDrawsSomething() throws {
        let journey = Journey(
            legs: [.walk(from: origin, to: destination, seconds: 600, metres: 800)],
            departure: base, arrival: at(10), transfers: 0)

        let segments = journey.walkSegments
        // `#require` y no `#expect`: con una cuenta equivocada, indexar debajo reventaría la
        // suite entera en vez de dar un test rojo, y un `crash` se lee mucho peor que un fallo.
        try #require(segments.count == 1)
        let only = try #require(segments.first)
        #expect(only.from == origin.coordinate)
        #expect(only.to == destination.coordinate)
    }

    /// El orden y el sentido importan aunque una recta se dibuje igual del derecho que del
    /// revés: con transbordo hay un tramo a pie *entre paradas*, y ahí invertirlo une los dos
    /// puntos equivocados.
    @Test("Acceso, transbordo y salida salen en orden y con el sentido correcto")
    func segmentsKeepOrderAndDirection() throws {
        let a = PlannerFixture.stop("A")
        let b = PlannerFixture.stop("B", northMetres: 1_000)
        let c = PlannerFixture.stop("C", northMetres: 1_200)
        let d = PlannerFixture.stop("D", northMetres: 2_000)

        let journey = Journey(legs: [
            .walk(from: origin, to: .stop(a), seconds: 120, metres: 150),
            ride("15", from: a, to: b),
            .walk(from: .stop(b), to: .stop(c), seconds: 200, metres: 220),
            ride("9", from: c, to: d),
            .walk(from: .stop(d), to: destination, seconds: 180, metres: 200)
        ], departure: base, arrival: at(30), transfers: 1)

        let segments = journey.walkSegments
        try #require(segments.count == 3, "acceso, transbordo y salida")

        #expect(segments[0].from == origin.coordinate)
        #expect(segments[0].to == Coordinate(a))

        #expect(segments[1].from == Coordinate(b), "el transbordo sale de donde se baja")
        #expect(segments[1].to == Coordinate(c))

        #expect(segments[2].from == Coordinate(d))
        #expect(segments[2].to == destination.coordinate, "la salida termina en el destino")
    }

    /// La reconstrucción emite igualmente el tramo de acceso cuando el origen *es* la parada,
    /// con cero segundos. Una raya de longitud cero bajo el pin es ruido, no información.
    @Test("Un tramo a pie de longitud cero no produce segmento")
    func zeroLengthWalksAreNotDrawn() {
        let a = PlannerFixture.stop("A")
        let b = PlannerFixture.stop("B", northMetres: 1_000)

        let journey = Journey(legs: [
            .walk(from: .stop(a), to: .stop(a), seconds: 0, metres: 0),
            ride("15", from: a, to: b),
            .walk(from: .stop(b), to: destination, seconds: 180, metres: 200)
        ], departure: base, arrival: at(20), transfers: 0)

        let segments = journey.walkSegments
        #expect(segments.count == 1, "solo la salida; el acceso no tiene longitud")
        #expect(segments.first?.from == Coordinate(b))
    }
}
