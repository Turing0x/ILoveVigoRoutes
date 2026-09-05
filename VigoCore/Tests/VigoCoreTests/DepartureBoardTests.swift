import Foundation
import Testing
@testable import VigoCore

/// Cómo se ordena un día de horarios de una línea en una parada.
@Suite("Tabla de horarios de una línea")
struct DepartureBoardTests {

    private let day = ServiceDate(yyyymmdd: 20_260_905)

    private func at(_ hour: Int, _ minute: Int) -> Date {
        Fixture.date(2026, 9, 5, hour, minute)
    }

    private func departure(_ hour: Int, _ minute: Int, to destination: String,
                           line: String = "15A") -> ScheduledDeparture {
        ScheduledDeparture(
            tripID: TripID("t\(hour)\(minute)\(destination)"),
            routeID: RouteID("r"), routeShortName: line,
            routeLongName: "LÍNEA LARGA", headsign: destination,
            departure: ServiceTime(seconds: hour * 3_600 + minute * 60),
            serviceDate: day,
            absoluteDate: at(hour, minute))
    }

    /// Una parada servida en los dos sentidos: mezclarlos en una columna da una tabla que no
    /// significa nada.
    @Test("Los dos sentidos son dos secciones, no una columna mezclada")
    func directionsAreSeparate() throws {
        let board = DepartureBoard.build([
            departure(8, 0, to: "ALCAMPO"),
            departure(8, 10, to: "CENTRO"),
            departure(8, 30, to: "ALCAMPO"),
            departure(8, 40, to: "CENTRO")
        ], now: at(7, 0))

        try #require(board.directions.count == 2)
        #expect(board.directions[0].destination == "ALCAMPO", "orden por primera salida")
        #expect(board.directions[0].departures.count == 2)
        #expect(board.directions[1].destination == "CENTRO")
        #expect(board.directions[1].departures.count == 2)
    }

    /// A las 20:00 la cabeza de la lista es el autobús de las 6 de la mañana. Señalarlo sería
    /// señalar el de ayer.
    @Test("La siguiente es la primera posterior a ahora, no la primera de la lista")
    func nextIsTheFirstStillToCome() throws {
        let board = DepartureBoard.build([
            departure(6, 0, to: "ALCAMPO"),
            departure(12, 0, to: "ALCAMPO"),
            departure(20, 30, to: "ALCAMPO")
        ], now: at(13, 0))

        let direction = try #require(board.directions.first)
        #expect(direction.nextIndex == 2)
        // Sobre el instante y no sobre `ServiceTime`: `.seconds` ahí son los segundos del
        // minuto, no los del día, y asertarlo compila igual de bien diciendo otra cosa.
        #expect(direction.next?.absoluteDate == at(20, 30))
    }

    @Test("Una salida justo a la hora de ahora todavía cuenta como siguiente")
    func exactlyNowStillCounts() throws {
        let board = DepartureBoard.build([departure(12, 0, to: "ALCAMPO")], now: at(12, 0))
        #expect(board.directions.first?.nextIndex == 0)
    }

    /// El caso de la última hora del día, que nadie prueba a mano.
    @Test("Pasada la última salida no hay siguiente, y no revienta")
    func afterTheLastOneThereIsNoNext() throws {
        let board = DepartureBoard.build([
            departure(6, 0, to: "ALCAMPO"),
            departure(22, 45, to: "ALCAMPO")
        ], now: at(23, 30))

        let direction = try #require(board.directions.first)
        #expect(direction.nextIndex == nil)
        #expect(direction.next == nil)
        #expect(direction.departures.count == 2, "la tabla del día sigue entera")
    }

    /// Cada sentido tiene su propio "siguiente": uno puede haber terminado el servicio y el
    /// otro no.
    @Test("Cada sentido lleva su propia cuenta de la siguiente")
    func nextIsPerDirection() throws {
        let board = DepartureBoard.build([
            departure(8, 0, to: "ALCAMPO"),
            departure(9, 0, to: "CENTRO"),
            departure(21, 0, to: "CENTRO")
        ], now: at(10, 0))

        try #require(board.directions.count == 2)
        #expect(board.directions[0].nextIndex == nil, "hacia Alcampo ya no queda ninguno")
        #expect(board.directions[1].nextIndex == 1)
    }

    @Test("Sin salidas, la tabla está vacía")
    func emptyBoard() {
        #expect(DepartureBoard.build([], now: at(10, 0)).isEmpty)
    }
}
