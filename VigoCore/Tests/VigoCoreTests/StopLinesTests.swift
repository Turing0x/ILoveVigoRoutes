import Foundation
import Testing
@testable import VigoCore

/// Las líneas de una parada, cada una con su siguiente autobús.
@Suite("Líneas de una parada")
struct StopLinesTests {

    private let day = ServiceDate(yyyymmdd: 20_260_905)

    private func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Fixture.date(2026, 9, 5, hour, minute).addingTimeInterval(TimeInterval(second))
    }

    private func route(_ name: String) -> Route {
        Route(id: RouteID("r\(name)"), shortName: name, longName: "LÍNEA \(name)",
              routeType: 3, colorHex: nil, textColorHex: nil)
    }

    private func departure(_ line: String, _ hour: Int, _ minute: Int,
                           to destination: String = "CENTRO") -> ScheduledDeparture {
        ScheduledDeparture(
            tripID: TripID("t\(line)\(hour)\(minute)"),
            routeID: RouteID("r\(line)"), routeShortName: line,
            routeLongName: "LÍNEA \(line)", headsign: destination,
            departure: ServiceTime(seconds: hour * 3_600 + minute * 60),
            serviceDate: day,
            absoluteDate: at(hour, minute))
    }

    private func arrival(_ line: String, _ minutes: Int, to destination: String = "SAMIL*") -> Arrival {
        Arrival(rawLine: line, destination: destination, minutes: minutes, metres: 1_000)
    }

    // MARK: - Minutos descontados

    @Test("Los minutos en vivo descuentan la edad de la respuesta, en minutos enteros")
    func discountsAge() {
        let fetched = at(10, 0)
        let bus = arrival("15A", 7)
        #expect(bus.minutes(at: at(10, 0, 59), fetchedAt: fetched) == 7)
        #expect(bus.minutes(at: at(10, 1), fetchedAt: fetched) == 6)
        #expect(bus.minutes(at: at(10, 3, 30), fetchedAt: fetched) == 4)
    }

    @Test("Nunca por debajo de cero, y un reloj atrasado no suma tiempo")
    func discountFloors() {
        let fetched = at(10, 0)
        #expect(arrival("15A", 2).minutes(at: at(10, 9), fetchedAt: fetched) == 0)
        #expect(arrival("15A", 2).minutes(at: at(9, 55), fetchedAt: fetched) == 2)
    }

    // MARK: - Siguiente

    @Test("Con tiempo real, el siguiente es el vivo más próximo y sale descontado")
    func liveWins() throws {
        let lines = StopLines.build(
            routes: [route("15A")],
            arrivals: [arrival("15A", 40), arrival("15A", 7)],
            fetchedAt: at(10, 0),
            scheduled: [departure("15A", 10, 2)],
            now: at(10, 2))
        let line = try #require(lines.first)
        guard case .live(let bus, let minutes) = line.next else {
            Issue.record("esperaba tiempo real, no horario"); return
        }
        #expect(bus.minutes == 7)
        #expect(minutes == 5)
        #expect(line.live.map(\.minutes) == [5, 38])
    }

    @Test("Sin tiempo real de esa línea, el siguiente viene del horario y lo dice")
    func scheduledFallback() throws {
        let lines = StopLines.build(
            routes: [route("15A"), route("31")],
            arrivals: [arrival("15A", 7)],
            fetchedAt: at(10, 0),
            scheduled: [departure("31", 10, 20)],
            now: at(10, 0))
        let line = try #require(lines.first { $0.name == "31" })
        guard case .scheduled(let dep, let minutes) = line.next else {
            Issue.record("esperaba horario"); return
        }
        #expect(dep.departure.clockDescription == departure("31", 10, 20).departure.clockDescription)
        #expect(minutes == 20)
    }

    @Test("El siguiente del horario es el primero posterior a ahora, no el primero de la lista")
    func nextIsAfterNow() throws {
        let lines = StopLines.build(
            routes: [route("11")],
            arrivals: [], fetchedAt: nil,
            scheduled: [departure("11", 6, 0), departure("11", 20, 30), departure("11", 20, 10)],
            now: at(20, 0))
        let next = try #require(lines.first?.nextScheduled)
        #expect(next.absoluteDate == at(20, 10))
    }

    @Test("El horario de otra línea no cuenta para esta")
    func scheduledIsPerLine() {
        let lines = StopLines.build(
            routes: [route("11")],
            arrivals: [], fetchedAt: nil,
            scheduled: [departure("15C", 10, 5)],
            now: at(10, 0))
        #expect(lines.first?.next == nil)
    }

    // MARK: - Emparejado y orden

    @Test("El emparejado pliega el punto final del GTFS")
    func foldsTrailingDot() {
        let lines = StopLines.build(
            routes: [route("9B.")],
            arrivals: [arrival("9B", 3)], fetchedAt: at(10, 0),
            scheduled: [], now: at(10, 0))
        #expect(lines.count == 1)
        #expect(lines.first?.live.count == 1)
    }

    @Test("Una llegada real sin ruta en el GTFS se conserva como fila propia")
    func keepsUnmatchedLive() throws {
        let lines = StopLines.build(
            routes: [route("PSA1")],
            arrivals: [arrival("PSA", 12), arrival("PSA", 50)], fetchedAt: at(10, 0),
            scheduled: [], now: at(10, 0))
        #expect(lines.count == 2)
        let orphan = try #require(lines.first { $0.route == nil })
        #expect(orphan.name == "PSA")
        #expect(orphan.live.count == 2)
        #expect(orphan.next?.minutes == 12)
    }

    @Test("Orden: primero lo que pasa antes; las líneas sin paso, al final por nombre")
    func ordering() {
        let lines = StopLines.build(
            routes: [route("A"), route("31"), route("15A"), route("4C")],
            arrivals: [arrival("31", 18), arrival("15A", 7)], fetchedAt: at(10, 0),
            scheduled: [], now: at(10, 0))
        #expect(lines.map(\.name) == ["15A", "31", "4C", "A"])
    }
}
