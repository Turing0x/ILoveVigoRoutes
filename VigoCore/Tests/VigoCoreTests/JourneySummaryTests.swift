import Foundation
import Testing
@testable import VigoCore

/// Lo que VoiceOver lee de una alternativa.
@Suite("Resumen hablado de un trayecto")
struct JourneySummaryTests {

    /// Reloj y zona fijos: si el texto dependiera de la zona de quien ejecuta la suite, este
    /// fichero pasaría o fallaría según la máquina.
    private let utc = TimeZone(identifier: "UTC")!
    private let base = Date(timeIntervalSince1970: 1_757_000_000)   // 2025-09-04 15:33:20 UTC

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private func stop(_ id: String) -> Stop { PlannerFixture.stop(id) }

    private func ride(_ line: String, from: Stop, to: Stop,
                      departure: Date, arrival: Date) -> JourneyLeg {
        .ride(routeID: RouteID("r\(line)"), routeShortName: line, headsign: nil,
              tripID: TripID("t\(line)"), board: from, alight: to,
              departure: departure, arrival: arrival, intermediateStops: [])
    }

    private var origin: Place { .coordinate(Coordinate(latitude: 42.2, longitude: -8.7), label: "O") }
    private var destination: Place { .coordinate(Coordinate(latitude: 42.3, longitude: -8.6), label: "D") }

    private func direct() -> Journey {
        Journey(legs: [
            .walk(from: origin, to: .stop(stop("A")), seconds: 120, metres: 150),
            ride("17", from: stop("A"), to: stop("B"), departure: at(2), arrival: at(15)),
            .walk(from: .stop(stop("B")), to: destination, seconds: 180, metres: 200)
        ], departure: base, arrival: at(18), transfers: 0)
    }

    private func spoken(_ journey: Journey, live: Arrival? = nil) -> String {
        JourneySummary.spoken(journey, live: live, timeZone: utc)
    }

    @Test("Dice horas, duración, transbordos y línea")
    func directJourneyReadsAsASentence() {
        let text = spoken(direct())
        #expect(text.contains("15:33"), "hora de salida")
        #expect(text.contains("15:51"), "hora de llegada")
        #expect(text.contains("18 minutos"))
        #expect(text.contains("directo"))
        // Una insignia de línea sola se lee como un número suelto; el sustantivo delante es
        // la mitad del sentido de la frase.
        #expect(text.contains("línea 17"))
        #expect(text.hasSuffix("."))
    }

    @Test("Con transbordo nombra las dos líneas")
    func transfersNameEveryLine() {
        let journey = Journey(legs: [
            .walk(from: origin, to: .stop(stop("A")), seconds: 60, metres: 80),
            ride("17", from: stop("A"), to: stop("B"), departure: at(2), arrival: at(10)),
            ride("C1", from: stop("B"), to: stop("C"), departure: at(12), arrival: at(25)),
            .walk(from: .stop(stop("C")), to: destination, seconds: 120, metres: 150)
        ], departure: base, arrival: at(27), transfers: 1)

        let text = spoken(journey)
        #expect(text.contains("1 transbordo"))
        #expect(!text.contains("transbordos"), "uno solo no lleva plural")
        #expect(text.contains("líneas 17, C1"))
    }

    @Test("Dos transbordos llevan plural")
    func twoTransfersArePlural() {
        #expect(JourneySummary.transfersText(2) == "2 transbordos")
        #expect(JourneySummary.transfersText(1) == "1 transbordo")
        #expect(JourneySummary.transfersText(0) == "directo")
    }

    @Test("Un trayecto a pie no habla de horas de autobús ni de líneas")
    func walkOnlyIsSaidAsSuch() {
        let journey = Journey(
            legs: [.walk(from: origin, to: destination, seconds: 720, metres: 900)],
            departure: base, arrival: at(12), transfers: 0)
        let text = spoken(journey)
        #expect(text.hasPrefix("A pie"))
        #expect(text.contains("12 minutos"))
        #expect(!text.contains("línea"))
        #expect(!text.contains("directo"), "no hay nada de lo que ser directo")
    }

    /// La insignia que enseña la procedencia no tiene texto propio, así que si la frase no la
    /// dice, quien usa VoiceOver no puede distinguir un vehículo seguido de una estimación.
    @Test("La anotación en vivo dice su procedencia")
    func liveAnnotationCarriesItsProvenance() {
        let tracked = Arrival(rawLine: "17", destination: "X", minutes: 3, metres: 400)
        #expect(spoken(direct(), live: tracked).contains("en vivo, sale en 3 minutos"))

        let estimated = Arrival(rawLine: "17", destination: "X", minutes: 3, metres: nil)
        #expect(spoken(direct(), live: estimated).contains("estimado, sale en 3 minutos"))
    }

    @Test("Sin anotación en vivo no se insinúa que la haya")
    func noLiveMeansNoMention() {
        let text = spoken(direct())
        #expect(!text.contains("sale en"))
        #expect(!text.contains("en vivo"))
        #expect(!text.contains("estimado"))
    }

    @Test("Un minuto va en singular")
    func singularMinute() {
        #expect(JourneySummary.minutesText(1) == "1 minuto")
        #expect(JourneySummary.minutesText(0) == "0 minutos")
        #expect(JourneySummary.minutesText(-5) == "0 minutos", "una duración negativa no se lee")
    }
}
