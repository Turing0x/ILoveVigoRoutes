import Testing
import Foundation
@testable import VigoCore

@Suite("Coste generalizado y poda de alternativas")
struct GeneralizedCostTests {

    private let clock = Date(timeIntervalSince1970: 1_757_000_000)

    /// `board` y `arrive` en minutos desde `clock`; `access` es la caminata inicial.
    private func journey(board: Double, arrive: Double, egress: Int,
                         transfers: Int = 0, access: Int = 120, line: String = "L") -> Journey {
        let a = PlannerFixture.stop("A\(line)\(Int(board))")
        let b = PlannerFixture.stop("B\(line)\(Int(board))", northMetres: 1_000)
        let departure = clock.addingTimeInterval(board * 60 - Double(access))
        return Journey(legs: [
            .walk(from: .coordinate(Coordinate(latitude: 42.23, longitude: -8.72), label: "O"),
                  to: .stop(a), seconds: access, metres: Double(access)),
            .ride(routeID: RouteID("r\(line)"), routeShortName: line, headsign: nil,
                  tripID: TripID("t\(line)\(Int(board))"), board: a, alight: b,
                  departure: clock.addingTimeInterval(board * 60),
                  arrival: clock.addingTimeInterval(arrive * 60 - Double(egress)),
                  intermediateStops: []),
            .walk(from: .stop(b),
                  to: .coordinate(Coordinate(latitude: 42.24, longitude: -8.71), label: "D"),
                  seconds: egress, metres: Double(egress)),
        ], departure: departure,
           arrival: clock.addingTimeInterval(arrive * 60), transfers: transfers)
    }

    // MARK: - El coste

    /// Lo que hace que el filtro no borre "el siguiente autobús": el coste mide el trayecto
    /// desde su propia salida, no desde el reloj de la consulta. Dos salidas idénticas
    /// separadas media hora tienen que costar exactamente lo mismo.
    @Test("Salir más tarde no encarece un trayecto idéntico")
    func latenessIsNotACost() {
        let now = journey(board: 10, arrive: 40, egress: 60)
        let later = journey(board: 40, arrive: 70, egress: 60)
        for criterion in JourneyOrdering.allCases {
            #expect(criterion.generalizedCostSeconds(now)
                    == criterion.generalizedCostSeconds(later))
        }
    }

    @Test("Un trayecto más lento cuesta más")
    func slowerCostsMore() {
        let quick = journey(board: 10, arrive: 40, egress: 60)
        let slow = journey(board: 10, arrive: 55, egress: 60)
        for criterion in JourneyOrdering.allCases {
            #expect(criterion.generalizedCostSeconds(slow)
                    > criterion.generalizedCostSeconds(quick))
        }
    }

    @Test("Cada transbordo cuesta cinco minutos percibidos")
    func transfersCost() {
        let direct = journey(board: 10, arrive: 40, egress: 60, transfers: 0)
        let oneChange = journey(board: 10, arrive: 40, egress: 60, transfers: 1)
        for criterion in JourneyOrdering.allCases {
            let delta = criterion.generalizedCostSeconds(oneChange)
                - criterion.generalizedCostSeconds(direct)
            #expect(abs(delta - JourneyOrdering.transferPenaltySeconds) < 0.001)
        }
    }

    /// «Menos caminata» tiene que penalizar la caminata final más que los otros criterios, o
    /// no sería un criterio distinto — y el trayecto que te deja en la puerta se caería del
    /// filtro por lento.
    @Test("Menos caminata castiga la caminata final más que los demás")
    func egressWalkWeighsMoreForItsOwnCriterion() {
        let atTheDoor = journey(board: 10, arrive: 40, egress: 0)
        let farOff = journey(board: 10, arrive: 40, egress: 600)

        let walkGap = JourneyOrdering.leastWalkAtEnd.generalizedCostSeconds(farOff)
            - JourneyOrdering.leastWalkAtEnd.generalizedCostSeconds(atTheDoor)
        let arrivalGap = JourneyOrdering.earliestArrival.generalizedCostSeconds(farOff)
            - JourneyOrdering.earliestArrival.generalizedCostSeconds(atTheDoor)
        #expect(walkGap > arrivalGap)
    }

    // MARK: - La poda

    /// Por qué hace falta la poda: el frente de Pareto **no puede** quitar esto.
    ///
    /// El segundo llega 22 minutos más tarde, cambia de autobús una vez más y no camina
    /// menos. Sobrevive sólo porque sale después, y «salir más tarde» es un eje de la
    /// dominancia (H-05, menos rato de pie en la parada) que no tiene tope: por muy tarde
    /// que sea, sigue puntuando. La forma medida de este caso está en `ScanDiagnosticTests`,
    /// contra el feed real.
    @Test("La dominancia no puede descartar al que sólo gana por salir más tarde")
    func paretoCannotDropTheLaterAndWorse() {
        let good = journey(board: 31, arrive: 68, egress: 0, transfers: 1, line: "C3i")
        let later = journey(board: 46, arrive: 90, egress: 0, transfers: 2, line: "5B")
        #expect(JourneyShortlist.undominated([good, later]).count == 2)
    }

    /// Y la poda sí.
    ///
    /// El pool tiene el tamaño que tiene por un motivo: la poda es relativa al mejor de cada
    /// criterio, así que con sólo dos trayectos el peor siempre cabe en la holgura del mejor
    /// y el test pasaría por el motivo equivocado.
    @Test("La poda descarta al que llega tarde, cambia más y no camina menos")
    func prunesTheLaterAndWorse() {
        let best = journey(board: 31, arrive: 68, egress: 0, transfers: 1, line: "C3i")
        let earliest = journey(board: 22, arrive: 68, egress: 0, transfers: 1, line: "13")
        let nextBus = journey(board: 91, arrive: 128, egress: 0, transfers: 1, line: "13b")
        let junk = journey(board: 46, arrive: 105, egress: 0, transfers: 3, line: "5B")

        let kept = Set(JourneyShortlist.plausible([best, earliest, nextBus, junk], slack: 900))
        #expect(!kept.contains(junk))
        #expect(kept.contains(best))
        #expect(kept.contains(earliest), "es la respuesta de «sale antes»")
        #expect(kept.contains(nextBus), "el siguiente autobús es una alternativa, no basura")
    }

    /// La regresión que más importa: el borrador anterior medía el coste desde el reloj de la
    /// consulta y dejaba una búsqueda de cinco opciones en una sola, porque las cuatro que
    /// tiraba eran las cuatro salidas siguientes. Una lista de alternativas sin las
    /// siguientes salidas no es una lista de alternativas.
    @Test("No se borran las salidas sucesivas")
    func keepsSuccessiveDepartures() {
        // Príncipe → Cunqueiro, medido contra el feed real: autobuses seguidos, sin
        // caminata final, con tiempos de viaje parecidos.
        let pool = [
            journey(board: 17, arrive: 40, egress: 0, line: "H2"),
            journey(board: 39, arrive: 69, egress: 0, line: "12B"),
            journey(board: 50, arrive: 80, egress: 0, line: "6"),
            journey(board: 61, arrive: 88, egress: 0, line: "H1"),
        ]
        #expect(JourneyShortlist.plausible(pool, slack: 900).count == 4)
    }

    /// El invariante duro. La poda corre **antes** de que el usuario elija criterio, así que
    /// tirar el óptimo de cualquiera de ellos dejaría a ese criterio ordenando un conjunto
    /// del que falta su propia respuesta — el fallo de H-04 y H-05, reintroducido un paso
    /// antes.
    @Test("Ningún criterio pierde nunca a su propio ganador")
    func everyCriterionKeepsItsWinner() {
        let pool = [
            journey(board: 22, arrive: 68, egress: 0, transfers: 1, line: "13"),   // sale antes
            journey(board: 31, arrive: 68, egress: 0, transfers: 1, line: "C3i"),  // llega antes
            journey(board: 25, arrive: 75, egress: 0, transfers: 0, line: "10"),   // menos caminata
            journey(board: 46, arrive: 95, egress: 500, transfers: 2, line: "5B"), // basura
            journey(board: 50, arrive: 99, egress: 480, transfers: 2, line: "14"), // basura
        ]
        let kept = Set(JourneyShortlist.plausible(pool, slack: 900))
        for criterion in JourneyOrdering.allCases {
            let winner = criterion.apply(pool, limit: 1).first!
            #expect(kept.contains(winner), "«\(criterion.label)» perdió su propia respuesta")
        }
        #expect(kept.count < pool.count, "la poda tiene que podar algo")
    }

    /// Una holgura enorme no debe descartar nada, y una de cero no debe vaciar la lista.
    @Test("Los extremos de la holgura se comportan")
    func slackExtremes() {
        let pool = [
            journey(board: 10, arrive: 40, egress: 0),
            journey(board: 20, arrive: 80, egress: 400, transfers: 2, line: "X"),
        ]
        #expect(JourneyShortlist.plausible(pool, slack: 86_400).count == 2)
        #expect(!JourneyShortlist.plausible(pool, slack: 0).isEmpty)
        #expect(JourneyShortlist.plausible([], slack: 900).isEmpty)
        #expect(JourneyShortlist.plausible([pool[0]], slack: 0).count == 1)
    }

    /// La poda no reordena: `cut` cuenta con recibir un frente y devolver algo ordenado por
    /// llegada, y una poda que barajase haría que dos ejecuciones difirieran.
    @Test("La poda conserva el orden que recibe")
    func preservesOrder() {
        let pool = (0..<6).map { journey(board: Double(10 + $0 * 12),
                                         arrive: Double(40 + $0 * 12), egress: $0 * 30,
                                         line: "L\($0)") }
        let kept = JourneyShortlist.plausible(pool, slack: 900)
        #expect(kept == pool.filter { kept.contains($0) })
    }
}
