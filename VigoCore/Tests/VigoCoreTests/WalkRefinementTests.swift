import Testing
import Foundation
@testable import VigoCore

@Suite("Caminata medida en los dos extremos")
struct WalkRefinementTests {

    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    /// Un enrutador de mentira que devuelve lo que se le diga, incluido "no sé".
    private struct StubRouter: WalkRouter {
        let seconds: Int?
        func walkSeconds(from: Coordinate, to: Coordinate) async -> Int? { seconds }
    }

    private func stop(_ id: String) -> Stop { PlannerFixture.stop(id) }

    /// Caminata de acceso, un autobús, caminata de salida.
    private func journey(access: Int, egress: Int, boardIn: Int = 10) -> Journey {
        let board = now.addingTimeInterval(TimeInterval(boardIn * 60))
        let alight = board.addingTimeInterval(20 * 60)
        return Journey(legs: [
            .walk(from: .coordinate(Coordinate(latitude: 42.23, longitude: -8.72), label: "O"),
                  to: .stop(stop("A")), seconds: access, metres: Double(access)),
            .ride(routeID: RouteID("r1"), routeShortName: "C1", headsign: nil,
                  tripID: TripID("t1"), board: stop("A"), alight: stop("B"),
                  departure: board, arrival: alight, intermediateStops: []),
            .walk(from: .stop(stop("B")),
                  to: .coordinate(Coordinate(latitude: 42.24, longitude: -8.71), label: "D"),
                  seconds: egress, metres: Double(egress)),
        ], departure: board.addingTimeInterval(-TimeInterval(access)),
           arrival: alight.addingTimeInterval(TimeInterval(egress)), transfers: 0)
    }

    private func refinement(access: Int?, egress: Int?, of journey: Journey)
        -> WalkRefinement.Refinement {
        WalkRefinement.Refinement(
            accessSeconds: access, egressSeconds: egress,
            estimatedAccessSeconds: WalkRefinement.estimatedAccessSeconds(journey),
            estimatedEgressSeconds: WalkRefinement.estimatedEgressSeconds(journey))
    }

    // MARK: - Degradar sin romperse

    /// El contrato entero de `WalkRouter`: `nil` es «no lo sé», nunca «no hay caminata». Sin
    /// red, la app tiene que comportarse exactamente como antes de que existiera esto.
    @Test("Un enrutador que no sabe nada no cambia nada")
    func silentRouterChangesNothing() async {
        let trip = journey(access: 300, egress: 180)
        let measured = await WalkRefinement.measure(trip, using: StubRouter(seconds: nil))
        #expect(measured.isEmpty)
        #expect(WalkRefinement.outcome(for: trip, refinement: measured, now: now) == nil)
    }

    @Test("Una medición idéntica a la estimación no mueve las horas")
    func exactMeasurementIsANoOp() throws {
        let trip = journey(access: 300, egress: 180)
        let outcome = try #require(WalkRefinement.outcome(
            for: trip, refinement: refinement(access: 300, egress: 180, of: trip), now: now))
        #expect(outcome.departure == trip.departure)
        #expect(outcome.arrival == trip.arrival)
    }

    // MARK: - A qué extremo va cada diferencia

    /// La parte que es fácil confundir. Una caminata de acceso más larga **no** retrasa la
    /// llegada: el autobús sale cuando sale, así que la diferencia entera sale del tiempo del
    /// viajero y mueve la salida hacia atrás.
    @Test("Un acceso más largo adelanta la salida y deja la llegada donde estaba")
    func accessMovesDepartureOnly() throws {
        let trip = journey(access: 300, egress: 180)
        let outcome = try #require(WalkRefinement.outcome(
            for: trip, refinement: refinement(access: 480, egress: nil, of: trip), now: now))

        #expect(abs(outcome.departure.timeIntervalSince(trip.departure) + 180) < 1,
                "tres minutos más de caminata: hay que salir tres minutos antes")
        #expect(outcome.arrival == trip.arrival, "el autobús no llega más tarde por eso")
    }

    @Test("Una salida más larga retrasa la llegada y deja la salida donde estaba")
    func egressMovesArrivalOnly() throws {
        let trip = journey(access: 300, egress: 180)
        let outcome = try #require(WalkRefinement.outcome(
            for: trip, refinement: refinement(access: nil, egress: 400, of: trip), now: now))

        #expect(outcome.departure == trip.departure)
        #expect(abs(outcome.arrival.timeIntervalSince(trip.arrival) - 220) < 1)
    }

    @Test("Una caminata más corta de lo estimado también cuenta")
    func shorterIsAlsoAnAnswer() throws {
        let trip = journey(access: 300, egress: 180)
        let outcome = try #require(WalkRefinement.outcome(
            for: trip, refinement: refinement(access: 120, egress: nil, of: trip), now: now))
        #expect(outcome.departure > trip.departure, "se puede salir más tarde")
    }

    // MARK: - El fallo que motivó todo esto

    /// El caso que abre la auditoría: el modelo en línea recta subestima el acceso y la app
    /// ofrece un autobús que no se puede coger. Ahora lo dice.
    @Test("Si la caminata real no cabe antes de que salga el bus, se avisa")
    func unreachableBoardingIsFlagged() throws {
        // El bus sale dentro de 10 min; la caminata real son 13.
        let trip = journey(access: 300, egress: 180, boardIn: 10)
        let outcome = try #require(WalkRefinement.outcome(
            for: trip, refinement: refinement(access: 780, egress: nil, of: trip), now: now))

        #expect(outcome.boardingUnreachable)
        let spare = try #require(outcome.secondsToSpare)
        #expect(spare < 0)
        #expect(abs(spare + 180) < 2, "faltan tres minutos")
    }

    @Test("Si cabe, no se avisa — y se dice cuánto margen queda")
    func reachableReportsItsMargin() throws {
        let trip = journey(access: 300, egress: 180, boardIn: 10)
        let outcome = try #require(WalkRefinement.outcome(
            for: trip, refinement: refinement(access: 420, egress: nil, of: trip), now: now))
        #expect(!outcome.boardingUnreachable)
        #expect(abs(try #require(outcome.secondsToSpare) - 180) < 2)
    }

    /// Llegar justo cuando sale no es «no llegas». Decirle a alguien que no puede coger un
    /// autobús que sale exactamente cuando aparece es peor error que decirle que va justo, y
    /// la fila ya enseña los segundos que quedan.
    @Test("Llegar justo a tiempo no es no llegar")
    func exactlyOnTimeIsNotUnreachable() throws {
        let trip = journey(access: 300, egress: 180, boardIn: 10)
        let outcome = try #require(WalkRefinement.outcome(
            for: trip, refinement: refinement(access: 600, egress: nil, of: trip), now: now))
        #expect(!outcome.boardingUnreachable)
        #expect(outcome.secondsToSpare == 0)
    }

    /// Sin reloj no se afirma nada sobre coger un autobús. Es lo que corresponde a una
    /// consulta para mañana: la caminata sigue midiéndose, pero «no llegas» sería absurdo.
    @Test("Sin reloj no se opina sobre si se coge el autobús")
    func noClockNoVerdict() throws {
        let trip = journey(access: 300, egress: 180)
        let outcome = try #require(WalkRefinement.outcome(
            for: trip, refinement: refinement(access: 900, egress: nil, of: trip), now: nil))
        #expect(!outcome.boardingUnreachable)
        #expect(outcome.secondsToSpare == nil)
        #expect(outcome.departure < trip.departure, "las horas sí se corrigen")
    }

    // MARK: - Qué se mide y qué no

    @Test("Se miden los dos extremos, y sólo esos")
    func measuresBothOpenAirWalks() async {
        let trip = journey(access: 300, egress: 180)
        let measured = await WalkRefinement.measure(trip, using: StubRouter(seconds: 250))
        #expect(measured.accessSeconds == 250)
        #expect(measured.egressSeconds == 250)
        #expect(measured.estimatedAccessSeconds == 300)
        #expect(measured.estimatedEgressSeconds == 180)
        #expect(measured.accessError == -50)
        #expect(measured.egressError == 70)
    }

    /// Un trayecto sólo a pie no tiene extremos que refinar en este sentido: es una única
    /// caminata, no el acceso a una red. Refinarla como «acceso» daría un `estimatedAccess`
    /// de quince minutos y un error enorme contra una caminata que nadie va a cronometrar
    /// contra un autobús.
    @Test("Un trayecto sólo a pie no se trata como acceso a nada")
    func walkOnlyHasNoAccessLeg() async {
        let walk = Journey(legs: [
            .walk(from: .coordinate(Coordinate(latitude: 42.23, longitude: -8.72), label: "O"),
                  to: .coordinate(Coordinate(latitude: 42.24, longitude: -8.71), label: "D"),
                  seconds: 900, metres: 1_000),
        ], departure: now, arrival: now.addingTimeInterval(900), transfers: 0)

        #expect(WalkRefinement.estimatedAccessSeconds(walk) == 0)
        let measured = await WalkRefinement.measure(walk, using: StubRouter(seconds: 700))
        #expect(measured.isEmpty, "una sola pierna no es ni acceso ni salida")
    }

    /// `estimatedEgressSeconds` comparte respuesta con la ordenación, para que las dos no
    /// puedan discrepar sobre qué es «la caminata del final».
    @Test("La caminata final es la misma que usa la ordenación")
    func egressAgreesWithOrdering() {
        let trip = journey(access: 300, egress: 180)
        #expect(WalkRefinement.estimatedEgressSeconds(trip)
                == JourneyOrdering.egressWalkSeconds(trip))
    }
}
