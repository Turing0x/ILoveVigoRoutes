import Testing
import Foundation
@testable import VigoCore

@Suite("Lo que el tiempo real implica para el resto del trayecto")
struct LiveJourneyAdjustmentTests {

    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func stop(_ id: String) -> Stop { PlannerFixture.stop(id) }

    /// Directo: caminata, un autobús, caminata.
    private func direct(boardIn: Int, rideMinutes: Int, egress: Int = 180) -> Journey {
        let board = now.addingTimeInterval(TimeInterval(boardIn * 60))
        let alight = board.addingTimeInterval(TimeInterval(rideMinutes * 60))
        return Journey(legs: [
            .walk(from: .coordinate(Coordinate(latitude: 42.23, longitude: -8.72), label: "O"),
                  to: .stop(stop("A")), seconds: 120, metres: 150),
            .ride(routeID: RouteID("r1"), routeShortName: "C1", headsign: nil,
                  tripID: TripID("t1"), board: stop("A"), alight: stop("B"),
                  departure: board, arrival: alight, intermediateStops: []),
            .walk(from: .stop(stop("B")),
                  to: .coordinate(Coordinate(latitude: 42.24, longitude: -8.71), label: "D"),
                  seconds: egress, metres: Double(egress)),
        ], departure: board.addingTimeInterval(-120),
           arrival: alight.addingTimeInterval(TimeInterval(egress)), transfers: 0)
    }

    /// Con transbordo: el segundo autobús sale `slack` segundos después de bajarse del
    /// primero, con `transferWalk` segundos de caminata entre medias.
    private func withTransfer(boardIn: Int, slack: Int, transferWalk: Int = 0) -> Journey {
        let board = now.addingTimeInterval(TimeInterval(boardIn * 60))
        let alight = board.addingTimeInterval(20 * 60)
        let secondBoard = alight.addingTimeInterval(TimeInterval(slack))
        let secondAlight = secondBoard.addingTimeInterval(15 * 60)
        var legs: [JourneyLeg] = [
            .walk(from: .coordinate(Coordinate(latitude: 42.23, longitude: -8.72), label: "O"),
                  to: .stop(stop("A")), seconds: 120, metres: 150),
            .ride(routeID: RouteID("r1"), routeShortName: "C1", headsign: nil,
                  tripID: TripID("t1"), board: stop("A"), alight: stop("B"),
                  departure: board, arrival: alight, intermediateStops: []),
        ]
        if transferWalk > 0 {
            legs.append(.walk(from: .stop(stop("B")), to: .stop(stop("C")),
                              seconds: transferWalk, metres: Double(transferWalk)))
        }
        legs.append(.ride(routeID: RouteID("r2"), routeShortName: "7", headsign: nil,
                          tripID: TripID("t2"), board: stop("C"), alight: stop("D"),
                          departure: secondBoard, arrival: secondAlight, intermediateStops: []))
        legs.append(.walk(from: .stop(stop("D")),
                          to: .coordinate(Coordinate(latitude: 42.25, longitude: -8.70), label: "D"),
                          seconds: 120, metres: 150))
        return Journey(legs: legs, departure: board.addingTimeInterval(-120),
                       arrival: secondAlight.addingTimeInterval(120), transfers: 1)
    }

    private func live(minutes: Int) -> Arrival {
        Arrival(rawLine: "C1", destination: "Destino", minutes: minutes, metres: 400)
    }

    // MARK: - Cuándo no hay nada que decir

    @Test("Un autobús en hora no genera ningún aviso")
    func onTimeSaysNothing() {
        // Sale dentro de 10 minutos y el tiempo real dice 10 minutos.
        #expect(LiveJourneyAdjustment.adjust(direct(boardIn: 10, rideMinutes: 20),
                                             live: live(minutes: 10), now: now) == nil)
    }

    /// La fuente informa en minutos enteros y las estimaciones de caminata son eso,
    /// estimaciones. Un aviso que salte con el ruido es un aviso que nadie lee.
    @Test("Un minuto de desvío está dentro del ruido")
    func smallDeviationIsNoise() {
        #expect(LiveJourneyAdjustment.adjust(direct(boardIn: 10, rideMinutes: 20),
                                             live: live(minutes: 11), now: now) == nil)
    }

    @Test("Un trayecto sin autobús no tiene primer embarque que ajustar")
    func walkOnlyHasNothingToAdjust() {
        let walk = Journey(legs: [
            .walk(from: .coordinate(Coordinate(latitude: 42.23, longitude: -8.72), label: "O"),
                  to: .coordinate(Coordinate(latitude: 42.24, longitude: -8.71), label: "D"),
                  seconds: 900, metres: 1_000),
        ], departure: now, arrival: now.addingTimeInterval(900), transfers: 0)
        #expect(LiveJourneyAdjustment.adjust(walk, live: live(minutes: 30), now: now) == nil)
    }

    // MARK: - Directo: el retraso se traslada

    @Test("En un trayecto directo el retraso se lleva a la hora de llegada")
    func directCarriesTheDelay() throws {
        let journey = direct(boardIn: 10, rideMinutes: 20)
        let adjustment = try #require(
            LiveJourneyAdjustment.adjust(journey, live: live(minutes: 18), now: now))

        #expect(abs(adjustment.delay - 8 * 60) < 1)
        let arrival = try #require(adjustment.adjustedArrival)
        #expect(abs(arrival.timeIntervalSince(journey.arrival) - 8 * 60) < 1)
        #expect(!adjustment.connectionAtRisk, "no hay transbordo que romper")
        #expect(adjustment.worstConnectionSlack == nil)
    }

    @Test("Un autobús adelantado también se cuenta, y con signo")
    func earlyIsNegative() throws {
        let adjustment = try #require(
            LiveJourneyAdjustment.adjust(direct(boardIn: 10, rideMinutes: 20),
                                         live: live(minutes: 5), now: now))
        #expect(adjustment.delay < 0)
        #expect(!adjustment.connectionAtRisk, "ir adelantado deja más margen, no menos")
    }

    // MARK: - Con transbordo: se avisa, no se inventa

    /// El límite honesto. Pasado un transbordo la llegada no es «más tarde», es
    /// **desconocida**: el siguiente autobús puede estar veinte minutos por detrás.
    @Test("Con transbordo no se inventa una hora de llegada")
    func transfersGetNoAdjustedArrival() throws {
        let adjustment = try #require(
            LiveJourneyAdjustment.adjust(withTransfer(boardIn: 10, slack: 600),
                                         live: live(minutes: 18), now: now))
        #expect(abs(adjustment.delay - 8 * 60) < 1)
        #expect(adjustment.adjustedArrival == nil)
    }

    @Test("Un retraso que se come el margen del transbordo se avisa")
    func eatingTheSlackIsFlagged() throws {
        // Diez minutos de margen, ocho de retraso: aún llega, pero justo.
        let comfortable = try #require(
            LiveJourneyAdjustment.adjust(withTransfer(boardIn: 10, slack: 600),
                                         live: live(minutes: 18), now: now))
        #expect(!comfortable.connectionAtRisk)
        #expect(comfortable.worstConnectionSlack == 600)

        // Cinco minutos de margen, ocho de retraso: lo pierde.
        let doomed = try #require(
            LiveJourneyAdjustment.adjust(withTransfer(boardIn: 10, slack: 300),
                                         live: live(minutes: 18), now: now))
        #expect(doomed.connectionAtRisk)
        #expect(doomed.worstConnectionSlack == 300)
    }

    /// El margen es el hueco **menos la caminata**: contar el hueco entero diría que hay
    /// cinco minutos de margen cuando cuatro de ellos se van andando entre andenes.
    @Test("La caminata del transbordo sale del margen")
    func transferWalkComesOutOfTheSlack() throws {
        let adjustment = try #require(
            LiveJourneyAdjustment.adjust(withTransfer(boardIn: 10, slack: 600, transferWalk: 240),
                                         live: live(minutes: 18), now: now))
        #expect(adjustment.worstConnectionSlack == 360, "600 s de hueco menos 240 s andando")
        #expect(adjustment.connectionAtRisk, "ocho minutos de retraso se comen seis de margen")
    }

    @Test("Ir adelantado nunca pone un transbordo en riesgo")
    func earlyNeverRisksAConnection() throws {
        let adjustment = try #require(
            LiveJourneyAdjustment.adjust(withTransfer(boardIn: 10, slack: 120),
                                         live: live(minutes: 4), now: now))
        #expect(adjustment.delay < 0)
        #expect(!adjustment.connectionAtRisk)
    }

    @Test("Con varios transbordos manda el más justo")
    func theTightestConnectionWins() {
        let board = now.addingTimeInterval(600)
        let a1 = board.addingTimeInterval(600)
        let b0 = a1.addingTimeInterval(900)          // 15 min de margen
        let b1 = b0.addingTimeInterval(600)
        let c0 = b1.addingTimeInterval(120)          // 2 min de margen: éste manda
        let c1 = c0.addingTimeInterval(600)
        let journey = Journey(legs: [
            .ride(routeID: RouteID("r1"), routeShortName: "C1", headsign: nil, tripID: TripID("t1"),
                  board: stop("A"), alight: stop("B"), departure: board, arrival: a1,
                  intermediateStops: []),
            .ride(routeID: RouteID("r2"), routeShortName: "7", headsign: nil, tripID: TripID("t2"),
                  board: stop("B"), alight: stop("C"), departure: b0, arrival: b1,
                  intermediateStops: []),
            .ride(routeID: RouteID("r3"), routeShortName: "9", headsign: nil, tripID: TripID("t3"),
                  board: stop("C"), alight: stop("D"), departure: c0, arrival: c1,
                  intermediateStops: []),
        ], departure: board, arrival: c1, transfers: 2)

        #expect(LiveJourneyAdjustment.worstSlack(journey) == 120)
    }
}
