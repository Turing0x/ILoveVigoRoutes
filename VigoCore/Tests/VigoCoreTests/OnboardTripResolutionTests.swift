import Testing
import Foundation
@testable import VigoCore

@Suite("Reconocer el autobús en el que se va")
struct OnboardTripResolutionTests {

    private func timetable() throws -> Timetable { try OnboardFixture.timetable() }

    private func input(_ line: String, at stop: Stop, hour: Int, minute: Int,
                       timetable: Timetable, previous: OnboardTripResolution.Input.Previous? = nil)
        -> OnboardTripResolution.Input {
        OnboardTripResolution.Input(
            declaredLine: line, coordinate: Coordinate(stop),
            now: OnboardFixture.at(hour, minute, calendar: repositoryCalendar(timetable)),
            previous: previous)
    }

    /// El calendario con el que se construyó el eje del horario. Los `Date` del test tienen que
    /// nacer en el mismo o las horas no querrían decir lo mismo.
    private func repositoryCalendar(_ timetable: Timetable) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    @Test("Una línea que el feed escribe «9B.» se reconoce escribiendo «9b»")
    func normalizesTheLineName() throws {
        let timetable = try timetable()
        let outcome = OnboardTripResolution.resolve(
            input("9b", at: OnboardFixture.b, hour: 8, minute: 10, timetable: timetable),
            timetable: timetable)
        guard case .resolved(let candidate) = outcome else {
            Issue.record("se esperaba un viaje resuelto, llegó \(outcome)"); return
        }
        #expect(candidate.routeShortName == "9B.")
    }

    @Test("Una línea que no existe se dice, no se aproxima")
    func unknownLine() throws {
        let timetable = try timetable()
        let outcome = OnboardTripResolution.resolve(
            input("Z99", at: OnboardFixture.b, hour: 8, minute: 10, timetable: timetable),
            timetable: timetable)
        guard case .noPatternForLine(let line) = outcome else {
            Issue.record("se esperaba .noPatternForLine, llegó \(outcome)"); return
        }
        #expect(line == "Z99")
    }

    @Test("Lejos del recorrido no se resuelve nada, y se dice a qué distancia está")
    func farFromTheLine() throws {
        let timetable = try timetable()
        let far = PlannerFixture.stop("9999", northMetres: 20_000, name: "Lejos")
        let outcome = OnboardTripResolution.resolve(
            input("9B.", at: far, hour: 8, minute: 10, timetable: timetable),
            timetable: timetable)
        guard case .tooFarFromLine(let metres) = outcome else {
            Issue.record("se esperaba .tooFarFromLine, llegó \(outcome)"); return
        }
        #expect(metres > 10_000)
    }

    @Test("En el recorrido pero a una hora sin servicio, no se inventa un viaje")
    func noTripAtThisHour() throws {
        let timetable = try timetable()
        let outcome = OnboardTripResolution.resolve(
            input("9B.", at: OnboardFixture.b, hour: 4, minute: 0, timetable: timetable),
            timetable: timetable)
        guard case .noTripRunningNow = outcome else {
            Issue.record("se esperaba .noTripRunningNow, llegó \(outcome)"); return
        }
    }

    @Test("Los dos sentidos de una línea son una pregunta para el usuario, no una suposición")
    func bothDirectionsAreAmbiguous() throws {
        let timetable = try timetable()
        // La ida pasa por B a las 08:10 y la vuelta a las 08:20. A las 08:15 las dos están a
        // cinco minutos: misma parada, misma distancia en el horario, sentidos opuestos.
        // Nada salvo el pasajero puede decir cuál de las dos es.
        let outcome = OnboardTripResolution.resolve(
            input("9B.", at: OnboardFixture.b, hour: 8, minute: 15, timetable: timetable),
            timetable: timetable)
        guard case .ambiguous(let candidates) = outcome else {
            Issue.record("se esperaba .ambiguous, llegó \(outcome)"); return
        }
        #expect(candidates.count == 2)
        #expect(Set(candidates.map(\.headsign)) == ["D", "A"])
    }

    /// El mismo instante que el test anterior deja ambiguo: lo único que cambia es que hay un
    /// fix previo más atrás en el recorrido, y con eso ya no hay que preguntar.
    @Test("Un fix anterior más atrás en el recorrido decide el sentido")
    func previousFixResolvesTheDirection() throws {
        let timetable = try timetable()
        let calendar = repositoryCalendar(timetable)
        let outcome = OnboardTripResolution.resolve(
            OnboardTripResolution.Input(
                declaredLine: "9B.", coordinate: Coordinate(OnboardFixture.b),
                now: OnboardFixture.at(8, 15, calendar: calendar),
                previous: .init(coordinate: Coordinate(OnboardFixture.a),
                                at: OnboardFixture.at(8, 5, calendar: calendar))),
            timetable: timetable)
        guard case .resolved(let candidate) = outcome else {
            Issue.record("se esperaba un viaje resuelto, llegó \(outcome)"); return
        }
        #expect(candidate.headsign == "D", "venía de A, así que va hacia D")
        #expect(candidate.position == 1)
    }

    @Test("En una línea circular, la posición la decide la hora y no la primera coincidencia")
    func loopIsResolvedByTime() throws {
        let timetable = try timetable()
        // G aparece dos veces en el patrón de L7: al salir (08:00) y al volver (08:40). A las
        // 08:38 la respuesta correcta es la segunda visita, no la primera.
        let outcome = OnboardTripResolution.resolve(
            input("L7", at: OnboardFixture.g, hour: 8, minute: 38, timetable: timetable),
            timetable: timetable)
        guard case .resolved(let candidate) = outcome else {
            Issue.record("se esperaba un viaje resuelto, llegó \(outcome)"); return
        }
        #expect(candidate.position == 2, "la vuelta del bucle, no la salida")
    }

    @Test("Las líneas que se ofrecen son las que pasan cerca, no las cuarenta y cinco del feed")
    func nearbyLines() throws {
        let timetable = try timetable()
        #expect(OnboardTripResolution.linesNearby(coordinate: Coordinate(OnboardFixture.g),
                                                  timetable: timetable) == ["L7"])
        #expect(OnboardTripResolution.linesNearby(coordinate: Coordinate(OnboardFixture.b),
                                                  timetable: timetable) == ["9B."])
    }
}
