import Testing
import Foundation
@testable import VigoCore

@Suite("Seguir el bus mientras se va en él")
struct OnboardProgressTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    private func resolved(_ timetable: Timetable, position: Int,
                          delaySeconds: Int32 = 0) -> ResolvedOnboardRide {
        let pattern = OnboardFixture.pattern("9B.", startingAt: OnboardFixture.a, in: timetable)
        return ResolvedOnboardRide(
            pattern: pattern,
            trip: OnboardFixture.trip("T1_0800", ofPattern: pattern, in: timetable),
            currentPosition: position, delaySeconds: delaySeconds)
    }

    @Test("Pasar una parada mueve la posición y mide el retraso de verdad")
    func passingAStopMeasuresTheDelay() throws {
        let timetable = try OnboardFixture.timetable()
        // El horario pone este viaje en C a las 08:20. Llegar allí a las 08:23 es tres minutos
        // de retraso, medido y no supuesto.
        let update = OnboardProgress.advance(
            resolved(timetable, position: 1), in: timetable,
            to: Coordinate(OnboardFixture.c),
            now: OnboardFixture.at(8, 23, calendar: calendar))

        #expect(update.position == 2)
        #expect(update.passedStop)
        #expect(update.delaySeconds == 180)
        #expect(!update.looksOffRide)
    }

    @Test("Entre paradas, el retraso medido se conserva en vez de crecer solo")
    func delayIsNotRecomputedBetweenStops() throws {
        let timetable = try OnboardFixture.timetable()
        let update = OnboardProgress.advance(
            resolved(timetable, position: 2, delaySeconds: 180), in: timetable,
            // Sin moverse de C, cinco minutos después.
            to: Coordinate(OnboardFixture.c),
            now: OnboardFixture.at(8, 28, calendar: calendar))

        #expect(update.position == 2)
        #expect(!update.passedStop)
        #expect(update.delaySeconds == 180,
                "«ahora menos el horario de la última parada» crecería un segundo por segundo")
    }

    @Test("La posición nunca retrocede, ni con un fix que cae más cerca de una parada anterior")
    func positionNeverGoesBackwards() throws {
        let timetable = try OnboardFixture.timetable()
        let update = OnboardProgress.advance(
            resolved(timetable, position: 2), in: timetable,
            to: Coordinate(OnboardFixture.a),
            now: OnboardFixture.at(8, 22, calendar: calendar))

        #expect(update.position == 2)
        #expect(update.looksOffRide, "A está a 1,2 km del tramo que queda: eso hay que preguntarlo")
    }

    @Test("Lejos del recorrido no se mueve nada y se marca para preguntar")
    func farFromTheRouteAsksInsteadOfGuessing() throws {
        let timetable = try OnboardFixture.timetable()
        let far = PlannerFixture.stop("9998", northMetres: 5_000, name: "Lejos")
        let update = OnboardProgress.advance(
            resolved(timetable, position: 1, delaySeconds: 60), in: timetable,
            to: Coordinate(far), now: OnboardFixture.at(8, 25, calendar: calendar))

        #expect(update.position == 1)
        #expect(update.looksOffRide)
        #expect(update.delaySeconds == 60)
    }
}
