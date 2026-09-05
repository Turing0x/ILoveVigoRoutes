import Foundation
import Testing
@testable import VigoCore

/// Los tres criterios de ordenación y el conjunto entre el que eligen.
///
/// `Journey` y `JourneyLeg` son públicos, así que estos tests construyen los trayectos a mano:
/// no hace falta ni `Timetable` ni base de datos para fijar un orden.
@Suite("Ordenación de alternativas")
struct JourneyOrderingTests {

    private let base = Date(timeIntervalSince1970: 1_757_000_000)

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private var origin: Place { .coordinate(Coordinate(latitude: 42.2, longitude: -8.7), label: "O") }
    private var destination: Place { .coordinate(Coordinate(latitude: 42.3, longitude: -8.6), label: "D") }

    /// Un trayecto con acceso a pie, uno o dos buses y salida a pie.
    ///
    /// - Parameters:
    ///   - access: segundos andando hasta la parada de subida.
    ///   - board: minuto en que sale el primer autobús.
    ///   - arrive: minuto de llegada puerta a puerta.
    ///   - egress: segundos andando desde la bajada hasta el destino.
    private func journey(access: Int = 120, board: Double, arrive: Double,
                         egress: Int, transfers: Int = 0, line: String = "15") -> Journey {
        let a = PlannerFixture.stop("A\(line)\(board)")
        let b = PlannerFixture.stop("B\(line)\(arrive)", northMetres: 1_000)
        var legs: [JourneyLeg] = [
            .walk(from: origin, to: .stop(a), seconds: access, metres: Double(access)),
            .ride(routeID: RouteID("r\(line)"), routeShortName: line, headsign: nil,
                  tripID: TripID("t\(line)\(board)"), board: a, alight: b,
                  departure: at(board), arrival: at(arrive - Double(egress) / 60),
                  intermediateStops: [])
        ]
        if transfers > 0 {
            let c = PlannerFixture.stop("C\(line)\(board)", northMetres: 1_500)
            legs.append(.ride(routeID: RouteID("r2\(line)"), routeShortName: "\(line)B",
                              headsign: nil, tripID: TripID("t2\(line)\(board)"),
                              board: b, alight: c,
                              departure: at(board + 1), arrival: at(arrive - Double(egress) / 60),
                              intermediateStops: []))
        }
        legs.append(.walk(from: .stop(b), to: destination,
                          seconds: egress, metres: Double(egress)))
        return Journey(legs: legs, departure: at(board) - Double(access),
                       arrival: at(arrive), transfers: transfers)
    }

    private func walkOnly(minutes: Double) -> Journey {
        Journey(legs: [.walk(from: origin, to: destination,
                             seconds: Int(minutes * 60), metres: minutes * 80)],
                departure: base, arrival: at(minutes), transfers: 0)
    }

    // MARK: - Menos caminata

    /// La ingenua es ordenar por duración, que pasa cualquier test descuidado y no es el
    /// criterio que se pidió.
    @Test("«Menos caminata» no coincide con «llega antes» cuando el que menos anda llega más tarde")
    func leastWalkIsNotDuration() throws {
        let rapido = journey(board: 2, arrive: 20, egress: 900)      // llega antes, 15 min a pie
        let cercano = journey(board: 5, arrive: 26, egress: 120)     // llega después, 2 min a pie

        let byWalk = JourneyOrdering.leastWalkAtEnd.apply([rapido, cercano], limit: 2)
        #expect(byWalk == [cercano, rapido])

        let byArrival = JourneyOrdering.earliestArrival.apply([rapido, cercano], limit: 2)
        #expect(byArrival == [rapido, cercano], "los dos criterios dan órdenes distintos")
    }

    /// Decisión del propietario: evita premiar al que ahorra 200 m al final y añade 600 m al
    /// principio.
    @Test("A igualdad de caminata final desempata la caminata total")
    func totalWalkBreaksTheTie() throws {
        let corto = journey(access: 120, board: 2, arrive: 30, egress: 300)
        let largo = journey(access: 900, board: 3, arrive: 28, egress: 300)

        let order = JourneyOrdering.leastWalkAtEnd.apply([largo, corto], limit: 2)
        #expect(order == [corto, largo],
                "misma caminata final; gana el que anda menos en total, no el que llega antes")
    }

    /// El corte antes de ordenar es el fallo silencioso de esta fase: deja fuera justo al que
    /// el criterio buscaba.
    @Test("Se ordena y después se corta, no al revés")
    func sortsBeforeCutting() throws {
        var journeys: [Journey] = []
        for index in 0..<6 {
            // El que menos anda es el quinto por llegada.
            journeys.append(journey(board: Double(index), arrive: Double(20 + index),
                                    egress: index == 4 ? 60 : 600, line: "L\(index)"))
        }
        let top = JourneyOrdering.leastWalkAtEnd.apply(journeys, limit: 1)
        try #require(top.count == 1)
        #expect(JourneyOrdering.egressWalkSeconds(top[0]) == 60)
    }

    // MARK: - Sale antes

    /// `Journey.departure` es el momento de empezar a andar, anterior por toda la caminata de
    /// acceso y distinta en cada alternativa. Lo que se pidió es el autobús.
    @Test("«Sale antes» mira el embarque, no la hora de salir de casa")
    func boardingIsNotDeparture() throws {
        // El que embarca antes sale de casa después, porque su caminata de acceso es corta.
        let embarcaAntes = journey(access: 60, board: 10, arrive: 40, egress: 120, line: "A")
        let saleDeCasaAntes = journey(access: 900, board: 12, arrive: 38, egress: 120, line: "B")

        #expect(saleDeCasaAntes.departure < embarcaAntes.departure, "la premisa del caso")

        let order = JourneyOrdering.earliestBoarding.apply([saleDeCasaAntes, embarcaAntes], limit: 2)
        #expect(order == [embarcaAntes, saleDeCasaAntes])
    }

    @Test("Un trayecto solo a pie no embarca nada, y se va al final")
    func walkOnlySortsLastByBoarding() throws {
        let aPie = walkOnly(minutes: 12)
        let enBus = journey(board: 30, arrive: 50, egress: 120)

        let order = JourneyOrdering.earliestBoarding.apply([aPie, enBus], limit: 2)
        #expect(order == [enBus, aPie], "encabezar la lista se leería como «este es el primer bus»")
    }

    @Test("La caminata final de un trayecto solo a pie es el trayecto entero")
    func walkOnlyIsAllEgress() {
        #expect(JourneyOrdering.egressWalkSeconds(walkOnly(minutes: 12)) == 12 * 60)
    }

    // MARK: - Llega antes

    /// Si se elige el criterio antiguo, la app se comporta como antes de la fase. Este test es
    /// lo que lo garantiza.
    @Test("«Llega antes» reproduce el orden que existía antes de la Fase 10")
    func earliestArrivalReproducesTheOldOrder() throws {
        // A igualdad de llegada ganaba el que salía **más tarde**: menos rato en la parada.
        let saleAntes = journey(access: 120, board: 2, arrive: 40, egress: 120, line: "A")
        let saleDespues = journey(access: 120, board: 9, arrive: 40, egress: 120, line: "B")

        let order = JourneyOrdering.earliestArrival.apply([saleAntes, saleDespues], limit: 2)
        #expect(order == [saleDespues, saleAntes])
    }

    // MARK: - El conjunto del que se elige

    /// El caso literal del §10.3 del plan: sin el eje de la caminata, Y domina a X en los tres
    /// ejes de siempre y X —que era la respuesta bajo «menos caminata»— desaparece.
    @Test("Con cuatro ejes, el que anda menos sobrevive al filtro de dominadas")
    func walkingAxisKeepsTheCloseOne() throws {
        let x = journey(access: 120, board: 0, arrive: 40, egress: 120, transfers: 1, line: "X")
        let y = journey(access: 120, board: 5, arrive: 38, egress: 900, transfers: 0, line: "Y")

        let front = JourneyShortlist.undominated([x, y])
        #expect(front.count == 2, "ninguno domina al otro: Y llega antes, X deja más cerca")
        #expect(Set(front) == Set([x, y]))
    }

    @Test("Un trayecto peor en los cuatro ejes sí se descarta")
    func strictlyWorseIsDropped() throws {
        let bueno = journey(access: 120, board: 5, arrive: 30, egress: 120, line: "OK")
        let malo = journey(access: 120, board: 2, arrive: 45, egress: 900, transfers: 1, line: "NO")

        let front = JourneyShortlist.undominated([bueno, malo])
        #expect(front == [bueno])
    }

    /// El sesgo por la puerta de atrás: cortar por llegada deja el conjunto elegido por
    /// rapidez, y el óptimo de los otros criterios ni siquiera entra.
    @Test("El corte reparte entre criterios y conserva el óptimo de cada uno")
    func cutKeepsEveryCriterionsBest() throws {
        var journeys: [Journey] = []
        // Doce candidatos donde el que menos anda y el que antes embarca son de los últimos
        // por llegada.
        for index in 0..<12 {
            journeys.append(journey(access: 120 + index, board: Double(20 - index),
                                    arrive: Double(30 + index),
                                    egress: 900 - index * 10, line: "L\(index)"))
        }
        let bestWalk = try #require(JourneyOrdering.leastWalkAtEnd.apply(journeys, limit: 1).first)
        let bestBoarding = try #require(JourneyOrdering.earliestBoarding.apply(journeys, limit: 1).first)
        let bestArrival = try #require(JourneyOrdering.earliestArrival.apply(journeys, limit: 1).first)

        let shortlist = JourneyShortlist.cut(journeys, to: 8)
        #expect(shortlist.count == 8)
        #expect(shortlist.contains(bestWalk), "el óptimo por caminata tiene que entrar")
        #expect(shortlist.contains(bestBoarding), "y el óptimo por embarque también")
        #expect(shortlist.contains(bestArrival))
    }

    @Test("Un conjunto que ya cabe se devuelve entero, ordenado por llegada")
    func smallSetIsKeptWhole() throws {
        let a = journey(board: 2, arrive: 40, egress: 120, line: "A")
        let b = journey(board: 3, arrive: 30, egress: 120, line: "B")
        #expect(JourneyShortlist.cut([a, b], to: 8) == [b, a])
    }
}
