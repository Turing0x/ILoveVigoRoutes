import Foundation
import Testing
@testable import VigoCore

/// One translation of `PlanOutcome`, checked case by case.
///
/// These tests are mostly about what the strings must *contain*, not their exact wording:
/// asserting the whole sentence would make every copy edit a red suite, while asserting the
/// radius, the dates and the day is asserting the part that is actually load-bearing — the
/// facts the user needs to do something about the failure.
@Suite("Mensajes de PlanOutcome")
struct PlanOutcomeMessageTests {

    private let window = ServiceDate(yyyymmdd: 20_260_905)...ServiceDate(yyyymmdd: 20_260_911)

    private func journey() -> Journey {
        let a = Place.coordinate(Coordinate(latitude: 42.23, longitude: -8.72), label: "A")
        let b = Place.coordinate(Coordinate(latitude: 42.24, longitude: -8.71), label: "B")
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        return Journey(legs: [.walk(from: a, to: b, seconds: 600, metres: 800)],
                       departure: now, arrival: now.addingTimeInterval(600), transfers: 0)
    }

    /// The contract that keeps a successful search from apologising for itself.
    @Test("Un resultado con trayectos no produce mensaje de fallo")
    func successesHaveNoMessage() {
        #expect(PlanOutcomeMessage.failure(.journeys([journey()])) == nil)
        #expect(PlanOutcomeMessage.failure(.walkOnly(journey())) == nil)
    }

    @Test("Los ocho casos están cubiertos y los siete fallos hablan")
    func everyFailureSpeaks() {
        let failures: [PlanOutcome] = [
            .noStopsNearOrigin(radiusMetres: 800),
            .noStopsNearDestination(radiusMetres: 800),
            .outsideFeedWindow(window),
            .noServiceOnDay(ServiceDate(yyyymmdd: 20_260_907)),
            .noJourneyFound(horizon: 3 * 3_600),
            .noData
        ]
        for outcome in failures {
            let text = PlanOutcomeMessage.failure(outcome)
            #expect(text?.isEmpty == false, "un fallo sin texto es un fallo silencioso")
        }
    }

    /// El radio es lo único accionable del mensaje: sin él, "no hay paradas cerca" no dice
    /// si el problema es de metros o de cobertura.
    @Test("Los dos casos de 'sin paradas cerca' llevan el radio y nombran el extremo")
    func nearbyFailuresNameTheEndAndTheRadius() {
        let origin = PlanOutcomeMessage.failure(.noStopsNearOrigin(radiusMetres: 800)) ?? ""
        #expect(origin.contains("800"))
        #expect(origin.contains("origen"))
        #expect(!origin.contains("destino"))

        let destination = PlanOutcomeMessage.failure(.noStopsNearDestination(radiusMetres: 800)) ?? ""
        #expect(destination.contains("800"))
        #expect(destination.contains("destino"))
    }

    @Test("Un trayecto guardado dice que el extremo es el guardado")
    func savedJourneyNamesTheStoredEnd() {
        let text = PlanOutcomeMessage.failure(.noStopsNearOrigin(radiusMetres: 800),
                                              context: .savedJourney) ?? ""
        #expect(text.contains("origen guardado"),
                "el arreglo es editar el trayecto guardado, no la consulta de ahora")
    }

    /// La regresión que motivó este paso: la copia de `SavedJourneyPlanModel` decía
    /// "los horarios importados no cubren esta fecha" **sin las fechas**, que es justo el
    /// único dato con el que el usuario puede hacer algo, dado que el feed solo cubre 7 días.
    @Test("Fuera de ventana dice qué días sí cubre el feed")
    func outsideWindowNamesTheCoveredDays() {
        let text = PlanOutcomeMessage.failure(.outsideFeedWindow(window)) ?? ""
        #expect(text.contains("05/09/2026"))
        #expect(text.contains("11/09/2026"))
    }

    @Test("Sin servicio ese día nombra el día")
    func noServiceNamesTheDay() {
        let text = PlanOutcomeMessage.failure(.noServiceOnDay(ServiceDate(yyyymmdd: 20_260_907))) ?? ""
        #expect(text.contains("07/09/2026"))
    }

    @Test("El horizonte se cuenta en horas, con singular y plural")
    func horizonWording() {
        #expect(PlanOutcomeMessage.failure(.noJourneyFound(horizon: 3 * 3_600))?
            .contains("próximas 3 horas") == true)
        #expect(PlanOutcomeMessage.failure(.noJourneyFound(horizon: 3_600))?
            .contains("próxima hora") == true)
    }

    /// `MapNavigationState` pliega una lista vacía de alternativas a `noJourneyFound(horizon: 0)`.
    /// Sin este caso, el mensaje sería "en las próximas 0 horas".
    @Test("Un horizonte de cero no produce 'en las próximas 0 horas'")
    func zeroHorizonReadsAsNow() {
        let text = PlanOutcomeMessage.failure(.noJourneyFound(horizon: 0)) ?? ""
        #expect(!text.contains("0 horas"))
        #expect(text.contains("ahora mismo"))
    }

    /// El plegado del paso 1 y el mensaje del paso 2 tienen que encajar de verdad, no solo
    /// por separado: este es el único test que los cruza.
    @Test("Una lista vacía de alternativas acaba en un mensaje legible")
    func emptyAlternativesProduceAReadableMessage() {
        var state = MapNavigationState()
        state.planningFinished(.journeys([]))
        let outcome = try? #require(state.route.failure)
        let text = PlanOutcomeMessage.failure(outcome ?? .noData) ?? ""
        #expect(text.contains("ahora mismo"))
    }

    @Test("ServiceDate.humanReadable rellena con ceros")
    func humanReadablePads() {
        #expect(ServiceDate(yyyymmdd: 20_260_905).humanReadable == "05/09/2026")
        #expect(ServiceDate(yyyymmdd: 20_261_231).humanReadable == "31/12/2026")
    }

    @Test("El aviso de parada cercana redondea la caminata hacia arriba y la ganancia hacia abajo")
    func nearbyStopHintWording() {
        let n = PlannerFixture.stop("N", northMetres: 200, name: "Rúa da Travesía de Vigo  7")
        let t0 = Date(timeIntervalSince1970: 0)
        let journey = Journey(legs: [], departure: t0, arrival: t0, transfers: 0)
        let better = NearbyStopHint(stop: n, walkSeconds: 283, arrivesEarlierBy: 719, journey: journey)
        #expect(PlanOutcomeMessage.nearbyStopHint(better)
                == "Andando 5 min hasta Rúa da Travesía de Vigo  7 llegarías 11 min antes.")
        let only = NearbyStopHint(stop: n, walkSeconds: 283, arrivesEarlierBy: nil, journey: journey)
        #expect(PlanOutcomeMessage.nearbyStopHint(only).contains("no sale nada a tiempo"))
    }
}
