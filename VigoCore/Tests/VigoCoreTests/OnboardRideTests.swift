import Testing
import Foundation
@testable import VigoCore

@Suite("El bus en marcha, guardado y reencontrado")
struct OnboardRideTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    private func fixture() throws -> (Timetable, OnboardRide, Date) {
        let timetable = try OnboardFixture.timetable()
        let now = OnboardFixture.at(8, 12, calendar: calendar)
        let pattern = OnboardFixture.pattern("9B.", startingAt: OnboardFixture.a, in: timetable)
        let ride = OnboardFixture.ride(pattern: pattern, trip: "T1_0800", currentPosition: 1,
                                       in: timetable, now: now)
        return (timetable, ride, now)
    }

    @Test("Ida y vuelta por JSON sin perder nada")
    func codableRoundTrip() throws {
        let (_, ride, _) = try fixture()
        let data = try JSONEncoder().encode(ride)
        #expect(try JSONDecoder().decode(OnboardRide.self, from: data) == ride)
    }

    @Test("El viaje se reencuentra en un horario reconstruido desde cero")
    func resolvesAgainstAFreshTimetable() throws {
        let (_, ride, now) = try fixture()
        // Un horario nuevo, construido en otra pasada: los índices de patrón y de viaje son
        // suyos, no los de aquel contra el que se declaró.
        let rebuilt = try OnboardFixture.timetable()
        guard case .success(let resolved) = OnboardRideResolution.resolve(ride, in: rebuilt,
                                                                          now: now) else {
            Issue.record("se esperaba resolver el viaje"); return
        }
        #expect(resolved.currentPosition == 1)
        #expect(rebuilt.tripRef(pattern: resolved.pattern, trip: resolved.trip).tripID
                == TripID("T1_0800"))
    }

    @Test("Sin el trip_id, la hora guardada basta para reencontrar el mismo servicio")
    func resolvesWithoutATripID() throws {
        let (timetable, stored, now) = try fixture()
        let withoutID = OnboardRide(
            routeShortName: stored.routeShortName, headsign: stored.headsign,
            patternStopIDs: stored.patternStopIDs, tripID: nil,
            boardStop: stored.boardStop, boardPosition: stored.boardPosition,
            currentStop: stored.currentStop, currentPosition: stored.currentPosition,
            scheduledAtCurrent: stored.scheduledAtCurrent,
            observedDelaySeconds: 0, declaredAt: stored.declaredAt,
            updatedAt: stored.updatedAt, confidence: .inferred)

        guard case .success(let resolved) = OnboardRideResolution.resolve(withoutID,
                                                                          in: timetable,
                                                                          now: now) else {
            Issue.record("se esperaba resolver el viaje por la hora"); return
        }
        #expect(timetable.tripRef(pattern: resolved.pattern, trip: resolved.trip).tripID
                == TripID("T1_0800"), "el de las 08:00, no el de las 09:00")
    }

    @Test("Si la línea cambió de recorrido, se dice; no se engancha al parecido")
    func patternGoneAfterAReimport() throws {
        let (timetable, stored, now) = try fixture()
        let reshaped = OnboardRide(
            routeShortName: stored.routeShortName, headsign: stored.headsign,
            // Una parada menos: el recorrido guardado ya no existe en el feed.
            patternStopIDs: Array(stored.patternStopIDs.dropLast()), tripID: stored.tripID,
            boardStop: stored.boardStop, boardPosition: stored.boardPosition,
            currentStop: stored.currentStop, currentPosition: stored.currentPosition,
            scheduledAtCurrent: stored.scheduledAtCurrent, observedDelaySeconds: 0,
            declaredAt: stored.declaredAt, updatedAt: stored.updatedAt, confidence: .inferred)

        guard case .failure(.patternGone) = OnboardRideResolution.resolve(reshaped,
                                                                          in: timetable,
                                                                          now: now) else {
            Issue.record("se esperaba .patternGone"); return
        }
    }

    @Test("En la última parada no queda trayecto que planificar")
    func rideFinished() throws {
        let timetable = try OnboardFixture.timetable()
        let now = OnboardFixture.at(8, 31, calendar: calendar)
        let pattern = OnboardFixture.pattern("9B.", startingAt: OnboardFixture.a, in: timetable)
        let ride = OnboardFixture.ride(pattern: pattern, trip: "T1_0800", currentPosition: 3,
                                       in: timetable, now: now)
        guard case .failure(.rideFinished(let stop)) = OnboardRideResolution.resolve(
            ride, in: timetable, now: now) else {
            Issue.record("se esperaba .rideFinished"); return
        }
        #expect(stop == "D")
    }

    @Test("La caducidad se mide desde la última posición confirmada, no desde la declaración")
    func stalenessIsMeasuredFromTheLastFix() throws {
        let (_, ride, now) = try fixture()
        let moved = ride.advanced(to: ride.currentStop, position: ride.currentPosition,
                                  scheduledAtCurrent: ride.scheduledAtCurrent,
                                  observedDelaySeconds: 0,
                                  at: now.addingTimeInterval(25 * 60))
        #expect(moved.staleness(now: now.addingTimeInterval(50 * 60)) == .active,
                "veinticinco minutos después de moverse sigue vigente")
        guard case .stale = ride.staleness(now: now.addingTimeInterval(50 * 60)) else {
            Issue.record("la que no se movió sí ha caducado"); return
        }
    }

    @Test("Un sentido confirmado a mano no se degrada al avanzar")
    func confirmationSurvivesProgress() throws {
        let (_, ride, now) = try fixture()
        let confirmed = OnboardRide(
            routeShortName: ride.routeShortName, headsign: ride.headsign,
            patternStopIDs: ride.patternStopIDs, tripID: ride.tripID,
            boardStop: ride.boardStop, boardPosition: ride.boardPosition,
            currentStop: ride.currentStop, currentPosition: ride.currentPosition,
            scheduledAtCurrent: ride.scheduledAtCurrent, observedDelaySeconds: 0,
            declaredAt: ride.declaredAt, updatedAt: ride.updatedAt,
            confidence: .confirmedByUser)
        let moved = confirmed.advanced(to: ride.currentStop, position: 2,
                                       scheduledAtCurrent: ride.scheduledAtCurrent,
                                       observedDelaySeconds: 60, at: now)
        #expect(moved.confidence == .confirmedByUser)
    }
}
