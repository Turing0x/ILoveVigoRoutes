import Testing
import Foundation
@testable import VigoCore

@Suite("Planificar desde el autobús en el que ya se va")
struct OnboardPlannerTests {

    private struct Fixture {
        let repository: TransitRepository
        let planner: JourneyPlanner
        let timetable: Timetable
        let pattern: Int

        init(options: PlannerOptions = PlannerOptions()) throws {
            repository = try OnboardFixture.repository()
            planner = OnboardFixture.planner(repository: repository, options: options)
            timetable = try TimetableBuilder(repository: repository, options: options,
                                             footpaths: .empty).build(anchor: OnboardFixture.anchor)
            pattern = OnboardFixture.pattern("9B.", startingAt: OnboardFixture.a, in: timetable)
        }

        func now(_ hour: Int, _ minute: Int) -> Date {
            OnboardFixture.at(hour, minute, calendar: repository.calendar)
        }

        func ride(currentPosition: Int, delaySeconds: Int = 0, trip: String = "T1_0800",
                  at now: Date) -> OnboardRide {
            OnboardFixture.ride(pattern: pattern, trip: trip, currentPosition: currentPosition,
                                delaySeconds: delaySeconds, in: timetable, now: now)
        }
    }

    private func journeys(_ outcome: PlanOutcome) -> [Journey] {
        if case .journeys(let journeys) = outcome { return journeys }
        return []
    }

    // MARK: - N1: ¿me sirve este autobús?

    @Test("Si este autobús llega, la respuesta directa va la primera y sin transbordos")
    func directAnswerComesFirst() async throws {
        let fixture = try Fixture()
        let now = fixture.now(8, 12)
        let result = try await fixture.planner.planOnboard(OnboardQuery(
            ride: fixture.ride(currentPosition: 1, at: now),
            destination: .stop(OnboardFixture.d), now: now))

        let journeys = journeys(result.outcome)
        guard let first = journeys.first else {
            Issue.record("se esperaban alternativas, llegó \(result.outcome)"); return
        }
        #expect(first.transfers == 0)
        guard case .ride(_, let line, _, _, let board, let alight, _, let arrival, _) =
                first.legs.first else {
            Issue.record("la primera pata tiene que ser el autobús en el que ya se va"); return
        }
        #expect(line == "9B.")
        #expect(board.id == OnboardFixture.b.id, "se sube donde está ahora, no en la cabecera")
        #expect(alight.id == OnboardFixture.d.id)
        #expect(arrival == fixture.timetable.date(forAxisSeconds: 8 * 3_600 + 30 * 60))
    }

    @Test("La salida del trayecto es el momento a bordo, no la medianoche del eje")
    func departureIsTheMomentOnBoard() async throws {
        let fixture = try Fixture()
        let now = fixture.now(8, 12)
        let result = try await fixture.planner.planOnboard(OnboardQuery(
            ride: fixture.ride(currentPosition: 1, at: now),
            destination: .stop(OnboardFixture.d), now: now))

        guard let first = journeys(result.outcome).first else {
            Issue.record("se esperaban alternativas"); return
        }
        #expect(first.departure == fixture.timetable.date(forAxisSeconds: 8 * 3_600 + 10 * 60),
                "cuando este autobús pasó por donde va el pasajero")
    }

    @Test("El retraso observado desplaza la llegada de este autobús")
    func delayShiftsTheArrival() async throws {
        let fixture = try Fixture()
        let now = fixture.now(8, 15)
        let result = try await fixture.planner.planOnboard(OnboardQuery(
            ride: fixture.ride(currentPosition: 1, delaySeconds: 180, at: now),
            destination: .stop(OnboardFixture.d), now: now))

        guard let first = journeys(result.outcome).first else {
            Issue.record("se esperaban alternativas"); return
        }
        #expect(first.arrival == fixture.timetable.date(forAxisSeconds: 8 * 3_600 + 33 * 60),
                "tres minutos tarde en cada parada que le queda")
    }

    // MARK: - N2: bajarse y seguir

    @Test("Si no llega, dice dónde bajarse y qué coger, y eso cuenta como un transbordo")
    func transferAnswer() async throws {
        let fixture = try Fixture()
        let now = fixture.now(8, 12)
        let result = try await fixture.planner.planOnboard(OnboardQuery(
            ride: fixture.ride(currentPosition: 1, at: now),
            destination: .stop(OnboardFixture.f), now: now))

        guard let first = journeys(result.outcome).first else {
            Issue.record("se esperaba una alternativa con transbordo, llegó \(result.outcome)")
            return
        }
        #expect(first.transfers == 1)
        let rides = first.legs.compactMap { leg -> (String, Stop, Stop)? in
            guard case .ride(_, let line, _, _, let board, let alight, _, _, _) = leg else {
                return nil
            }
            return (line, board, alight)
        }
        #expect(rides.count == 2)
        #expect(rides.first?.0 == "9B.")
        #expect(rides.first?.2.id == OnboardFixture.c.id, "bajarse en C")
        #expect(rides.last?.0 == "L2")
        #expect(first.arrival == fixture.timetable.date(forAxisSeconds: 8 * 3_600 + 40 * 60))
    }

    @Test("El enlace se ajusta al último servicio que aún encaja; este autobús no se toca")
    func theConnectionIsFittedButTheBoardedBusIsNot() async throws {
        let fixture = try Fixture()
        let now = fixture.now(8, 12)
        let result = try await fixture.planner.planOnboard(OnboardQuery(
            ride: fixture.ride(currentPosition: 1, at: now),
            destination: .stop(OnboardFixture.f), now: now))

        guard let first = journeys(result.outcome).first else {
            Issue.record("se esperaba una alternativa"); return
        }
        let tripIDs = first.legs.compactMap { leg -> TripID? in
            guard case .ride(_, _, _, let tripID, _, _, _, _, _) = leg else { return nil }
            return tripID
        }
        #expect(tripIDs.first == TripID("T1_0800"),
                "no se puede cambiar de autobús el que ya se está ocupando")
        #expect(tripIDs.last == TripID("T2_0825"))
    }

    @Test("Un destino que solo queda por detrás no se ofrece: este autobús ya pasó")
    func destinationBehindIsNotOffered() async throws {
        let fixture = try Fixture()
        let now = fixture.now(8, 22)
        // Ya en C, con A por detrás. Nada de este autobús vuelve allí.
        let result = try await fixture.planner.planOnboard(OnboardQuery(
            ride: fixture.ride(currentPosition: 2, at: now),
            destination: .stop(OnboardFixture.a), now: now))

        for journey in journeys(result.outcome) {
            for leg in journey.legs {
                guard case .ride(_, let line, _, _, _, let alight, _, _, _) = leg else { continue }
                #expect(!(line == "9B." && alight.id == OnboardFixture.a.id),
                        "este autobús no vuelve a A")
            }
        }
    }

    // MARK: - Bajarse y andar

    @Test("Sin parada cerca del destino, la respuesta es bajarse en la mejor y andar")
    func alightAndWalk() async throws {
        // Cinco minutos de caminata de acceso: un radio de unos 266 m, dentro del cual no cae
        // ninguna parada del feed desde el portal. RAPTOR no encuentra salida ninguna, y aun
        // así el autobús sigue acercando al pasajero — que es la respuesta que hay que dar.
        let fixture = try Fixture(options: PlannerOptions(maxAccessWalkMinutes: 5))
        let now = fixture.now(8, 12)
        let doorstep = PlannerFixture.stop("9997", northMetres: 700, eastMetres: 1_800,
                                           name: "Portal")
        let result = try await fixture.planner.planOnboard(OnboardQuery(
            ride: fixture.ride(currentPosition: 1, at: now),
            destination: .coordinate(Coordinate(doorstep), label: "Portal"), now: now))

        guard let only = journeys(result.outcome).first else {
            Issue.record("se esperaba bajarse y andar"); return
        }
        #expect(only.transfers == 0)
        guard case .ride(_, _, _, _, _, let alight, _, _, _) = only.legs.first,
              case .walk = only.legs.last else {
            Issue.record("se esperaba autobús y luego caminata"); return
        }
        // C, no D: D queda 200 m más cerca del portal, pero el autobús tarda diez minutos más
        // en llegar allí. Lo que se minimiza es la hora de estar en la puerta, no los metros.
        #expect(alight.id == OnboardFixture.c.id)
    }

    // MARK: - Cuando el autobús ya no se puede identificar

    @Test("Si el recorrido guardado ya no existe, se pide volver a decir el autobús")
    func unresolvableRideIsItsOwnAnswer() async throws {
        let fixture = try Fixture()
        let now = fixture.now(8, 12)
        let stored = fixture.ride(currentPosition: 1, at: now)
        let reshaped = OnboardRide(
            routeShortName: stored.routeShortName, headsign: stored.headsign,
            patternStopIDs: Array(stored.patternStopIDs.dropLast()), tripID: stored.tripID,
            boardStop: stored.boardStop, boardPosition: stored.boardPosition,
            currentStop: stored.currentStop, currentPosition: stored.currentPosition,
            scheduledAtCurrent: stored.scheduledAtCurrent, observedDelaySeconds: 0,
            declaredAt: stored.declaredAt, updatedAt: stored.updatedAt, confidence: .inferred)

        let result = try await fixture.planner.planOnboard(OnboardQuery(
            ride: reshaped, destination: .stop(OnboardFixture.d), now: now))

        guard case .onboardRideUnresolvable(.patternGone) = result.outcome else {
            Issue.record("se esperaba .onboardRideUnresolvable, llegó \(result.outcome)"); return
        }
        #expect(PlanOutcomeMessage.failure(result.outcome)?.contains("9B.") == true)
    }

    // MARK: - Lo que significa cada pata

    @Test("La siguiente subida es la segunda pata, no la del autobús que ya se ocupa")
    func nextBoardingIsTheSecondRide() async throws {
        let fixture = try Fixture()
        let now = fixture.now(8, 12)
        let direct = try await fixture.planner.planOnboard(OnboardQuery(
            ride: fixture.ride(currentPosition: 1, at: now),
            destination: .stop(OnboardFixture.d), now: now))
        let withTransfer = try await fixture.planner.planOnboard(OnboardQuery(
            ride: fixture.ride(currentPosition: 1, at: now),
            destination: .stop(OnboardFixture.f), now: now))

        let straight = try #require(journeys(direct.outcome).first)
        #expect(OnboardJourneyFacts.nextBoarding(straight) == nil,
                "sin transbordo no queda ninguna subida por hacer")
        #expect(OnboardJourneyFacts.alighting(straight)?.stop.id == OnboardFixture.d.id)

        let connecting = try #require(journeys(withTransfer.outcome).first)
        let next = try #require(OnboardJourneyFacts.nextBoarding(connecting))
        #expect(next.routeShortName == "L2")
        #expect(next.board.id == OnboardFixture.c.id)
        #expect(OnboardJourneyFacts.connectionSlack(connecting) == 300,
                "se baja a las 08:20 y el enlace sale a las 08:25")
    }

    @Test("Ninguna alternativa propone abandonar el autobús y hacer todo el camino a pie")
    func noWalkOnlyAlternative() async throws {
        let fixture = try Fixture()
        let now = fixture.now(8, 12)
        let result = try await fixture.planner.planOnboard(OnboardQuery(
            ride: fixture.ride(currentPosition: 1, at: now),
            destination: .stop(OnboardFixture.d), now: now))

        for journey in journeys(result.outcome) {
            #expect(journey.legs.contains { if case .ride = $0 { true } else { false } },
                    "en modo a bordo, toda alternativa empieza por el autobús que se ocupa")
        }
    }
}
