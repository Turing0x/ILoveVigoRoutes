import Foundation
import Testing
@testable import VigoCore

/// El cruce entre el primer embarque de un trayecto y lo que dice el tiempo real.
///
/// Es una heurística, y lo que estos tests fijan es justo dónde deja de creerse a sí misma.
@Suite("Primer embarque en vivo")
struct FirstBoardingMatchTests {

    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func arrival(_ line: String, minutes: Int, metres: Int? = nil) -> Arrival {
        Arrival(rawLine: line, destination: "Destino", minutes: minutes, metres: metres)
    }

    private func match(_ arrivals: [Arrival], line: String = "15",
                       departureInMinutes: Double) -> Arrival? {
        FirstBoardingMatch.match(
            arrivals: arrivals, routeShortName: line,
            scheduledDeparture: now.addingTimeInterval(departureInMinutes * 60), now: now)
    }

    @Test("Sin llegadas, o sin ninguna de esa línea, no hay nada que anotar")
    func nothingToMatch() {
        #expect(match([], departureInMinutes: 8) == nil)
        #expect(match([arrival("9", minutes: 8), arrival("C1", minutes: 9)],
                      departureInMinutes: 8) == nil)
    }

    @Test("Gana la llegada cuya hora implícita cae más cerca de la salida prevista")
    func closestWins() throws {
        // Tres autobuses de la misma línea. La salida prevista es dentro de 12 min.
        let chosen = try #require(match(
            [arrival("15", minutes: 3), arrival("15", minutes: 11), arrival("15", minutes: 20)],
            departureInMinutes: 12))
        #expect(chosen.minutes == 11)
    }

    /// El límite es lo que impide confundir el autobús que se busca con el siguiente de la
    /// misma línea. Sin él, una salida dentro de una hora "casaría" con el que llega ahora.
    @Test("Fuera de la tolerancia no se anota nada")
    func toleranceRefusesDistantBuses() {
        // Salida dentro de 30 min, único autobús dentro de 2: 28 min de diferencia.
        #expect(match([arrival("15", minutes: 2)], departureInMinutes: 30) == nil)
        // Justo en el borde de 15 min, se acepta.
        #expect(match([arrival("15", minutes: 0)], departureInMinutes: 15)?.minutes == 0)
        // Un minuto más allá, no.
        #expect(match([arrival("15", minutes: 0)], departureInMinutes: 16) == nil)
    }

    /// El caso más frecuente en la práctica con este feed: consultar un día futuro. El tiempo
    /// real no sabe nada de un autobús que aún no está por llegar, y decir lo contrario sería
    /// exactamente la deshonestía que el proyecto prohíbe.
    @Test("Una consulta a fecha futura nunca casa")
    func futureQueriesNeverMatch() {
        #expect(match([arrival("15", minutes: 5)], departureInMinutes: 24 * 60) == nil)
    }

    @Test("Los nombres de línea se comparan normalizados")
    func lineNamesAreNormalised() throws {
        // La API y el GTFS no escriben las líneas igual; comparar en crudo perdería la mitad.
        let raw = "  c1  "
        let chosen = try #require(FirstBoardingMatch.match(
            arrivals: [Arrival(rawLine: raw, destination: "X", minutes: 6, metres: 120)],
            routeShortName: "C1",
            scheduledDeparture: now.addingTimeInterval(6 * 60), now: now))
        #expect(chosen.confidence.hasTrackedVehicle)
    }

    @Test("El primer tramo en bus es el primero, no el último")
    func firstRideIsTheFirstOne() throws {
        let a = PlannerFixture.stop("A")
        let b = PlannerFixture.stop("B", northMetres: 1_000)
        let c = PlannerFixture.stop("C", northMetres: 2_000)
        let origin = Place.coordinate(Coordinate(latitude: 42.2, longitude: -8.7), label: "O")
        let destination = Place.coordinate(Coordinate(latitude: 42.3, longitude: -8.6), label: "D")

        let journey = Journey(legs: [
            .walk(from: origin, to: .stop(a), seconds: 120, metres: 150),
            .ride(routeID: RouteID("r1"), routeShortName: "15", headsign: nil, tripID: TripID("t1"),
                  board: a, alight: b, departure: now, arrival: now.addingTimeInterval(600),
                  intermediateStops: []),
            .ride(routeID: RouteID("r2"), routeShortName: "9", headsign: nil, tripID: TripID("t2"),
                  board: b, alight: c, departure: now.addingTimeInterval(900),
                  arrival: now.addingTimeInterval(1_500), intermediateStops: []),
            .walk(from: .stop(c), to: destination, seconds: 90, metres: 100)
        ], departure: now, arrival: now.addingTimeInterval(1_590), transfers: 1)

        let ride = try #require(FirstBoardingMatch.firstRide(of: journey))
        #expect(ride.routeShortName == "15", "el tiempo real solo cubre la parada donde se espera")
        #expect(ride.board == a)
        #expect(ride.departure == now)
    }

    @Test("Un trayecto solo a pie no tiene primer embarque")
    func walkOnlyHasNoRide() {
        let origin = Place.coordinate(Coordinate(latitude: 42.2, longitude: -8.7), label: "O")
        let destination = Place.coordinate(Coordinate(latitude: 42.21, longitude: -8.69), label: "D")
        let journey = Journey(
            legs: [.walk(from: origin, to: destination, seconds: 600, metres: 800)],
            departure: now, arrival: now.addingTimeInterval(600), transfers: 0)
        #expect(FirstBoardingMatch.firstRide(of: journey) == nil)
    }

    // MARK: - Se ha ido el autobús

    /// Un trayecto con **cinco minutos de caminata de acceso**: `Journey.departure` es cinco
    /// minutos anterior al embarque, y ahí es donde está la diferencia. Comparar contra
    /// `departure` daría el trayecto por perdido mientras el autobús sigue sin pasar.
    private func journeyWithAccessWalk() -> Journey {
        let a = PlannerFixture.stop("A")
        let b = PlannerFixture.stop("B", northMetres: 1_000)
        let origin = Place.coordinate(Coordinate(latitude: 42.2, longitude: -8.7), label: "O")
        let destination = Place.coordinate(Coordinate(latitude: 42.3, longitude: -8.6), label: "D")
        return Journey(legs: [
            .walk(from: origin, to: .stop(a), seconds: 300, metres: 400),
            .ride(routeID: RouteID("r1"), routeShortName: "15", headsign: nil, tripID: TripID("t1"),
                  board: a, alight: b,
                  departure: now.addingTimeInterval(300), arrival: now.addingTimeInterval(900),
                  intermediateStops: []),
            .walk(from: .stop(b), to: destination, seconds: 120, metres: 150)
        ], departure: now, arrival: now.addingTimeInterval(1_020), transfers: 0)
    }

    @Test("«Ya ha salido» se mide contra el embarque, no contra la hora de empezar a andar")
    func departureIsTheBoardingNotTheWalk() {
        let journey = journeyWithAccessWalk()
        // Un segundo después de `Journey.departure`, que es cuando habría que echar a andar.
        // El autobús aún tarda cinco minutos: no se ha ido nada.
        #expect(FirstBoardingMatch.hasDeparted(journey, now: now.addingTimeInterval(1)) == false)
        // Justo en el embarque tampoco: la puerta todavía está abierta.
        #expect(FirstBoardingMatch.hasDeparted(journey, now: now.addingTimeInterval(300)) == false)
        // Un segundo después del embarque, sí.
        #expect(FirstBoardingMatch.hasDeparted(journey, now: now.addingTimeInterval(301)))
    }

    @Test("Un trayecto solo a pie no se escapa nunca")
    func walkOnlyNeverDeparts() {
        let origin = Place.coordinate(Coordinate(latitude: 42.2, longitude: -8.7), label: "O")
        let destination = Place.coordinate(Coordinate(latitude: 42.21, longitude: -8.69), label: "D")
        let journey = Journey(
            legs: [.walk(from: origin, to: destination, seconds: 600, metres: 800)],
            departure: now, arrival: now.addingTimeInterval(600), transfers: 0)
        #expect(FirstBoardingMatch.hasDeparted(journey, now: now.addingTimeInterval(86_400)) == false)
    }
}
