import Foundation
import Testing
@testable import VigoCore

@Suite("Traza del trayecto en curso")
struct RideTracePlanTests {

    private let base = Date(timeIntervalSince1970: 1_757_000_000)
    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private let a = PlannerFixture.stop("A1")
    private let m1 = PlannerFixture.stop("M1", northMetres: 500)
    private let b = PlannerFixture.stop("B1", northMetres: 1_000)
    private let m2 = PlannerFixture.stop("M2", northMetres: 1_200)
    private let c = PlannerFixture.stop("C1", northMetres: 1_500)
    private let there = Coordinate(latitude: 42.3, longitude: -8.6)

    private func ride(_ from: Stop, _ to: Stop, via: [Stop], trip: String, dep: Double, arr: Double) -> JourneyLeg {
        .ride(routeID: RouteID("r"), routeShortName: "15", headsign: nil, tripID: TripID(trip),
              board: from, alight: to, departure: at(dep), arrival: at(arr), intermediateStops: via)
    }

    @Test("Con transbordo: dos tramos en orden y la caminata final hasta el destino")
    func snapshotWithTransfer() {
        let journey = Journey(legs: [
            .walk(from: .coordinate(Coordinate(latitude: 42.2, longitude: -8.7), label: "O"),
                  to: .stop(a), seconds: 120, metres: 120),
            ride(a, b, via: [m1], trip: "t1", dep: 0, arr: 15),
            ride(b, c, via: [m2], trip: "t2", dep: 16, arr: 30),
            .walk(from: .stop(c), to: .coordinate(there, label: "D"), seconds: 180, metres: 180),
        ], departure: at(-2), arrival: at(33), transfers: 1)
        let plan = RideTracePlan(ActiveJourneySnapshot(journey, originLabel: "Casa", destinationLabel: "Trabajo"))

        #expect(plan.rides.map(\.tripID) == [TripID("t1"), TripID("t2")])
        #expect(plan.rides[0].stopPath == [Coordinate(a), Coordinate(m1), Coordinate(b)])
        #expect(plan.rides[1].stopPath == [Coordinate(b), Coordinate(m2), Coordinate(c)])
        #expect(plan.egressWalk == RideTracePlan.Walk(from: Coordinate(c), to: there))
        #expect(plan.destination == there)
        #expect(plan.keyCoordinates.contains(there))
        #expect(plan.keyCoordinates.contains(Coordinate(a)))
    }

    @Test("Si el destino es la parada de bajada no hay caminata final ni bandera aparte")
    func snapshotEndingAtStop() {
        let journey = Journey(legs: [ride(a, b, via: [m1], trip: "t1", dep: 0, arr: 15)],
                              departure: at(0), arrival: at(15), transfers: 0)
        let plan = RideTracePlan(ActiveJourneySnapshot(journey, originLabel: "Aquí", destinationLabel: "B"))
        #expect(plan.egressWalk == nil)
        #expect(plan.destination == nil)
    }

    private func onboard(pattern: [Stop], current: Int, board: Int = 0) -> OnboardRide {
        OnboardRide(routeShortName: "9B", headsign: nil, patternStopIDs: pattern.map(\.id),
                    tripID: TripID("t9"),
                    boardStop: .from(pattern[board]), boardPosition: board,
                    currentStop: .from(pattern[current]), currentPosition: current,
                    scheduledAtCurrent: base, observedDelaySeconds: 0,
                    declaredAt: base, updatedAt: base, confidence: .inferred)
    }

    private var six: [Stop] {
        (0..<6).map { PlannerFixture.stop("P\($0)", northMetres: Double($0) * 300) }
    }

    @Test("Bus declarado: solo lo que queda desde la parada actual hasta el final")
    func onboardRemaining() throws {
        let stops = six
        let plan = try #require(RideTracePlan(onboard(pattern: stops, current: 3),
                                              stops: { id in stops.first { $0.id == id } }))
        #expect(plan.rides.count == 1)
        #expect(plan.rides[0].stopPath == stops[3...].map { Coordinate($0) })
        #expect(plan.rides[0].board == Coordinate(stops[3]))
        #expect(plan.rides[0].alight == Coordinate(stops[5]))
        #expect(plan.egressWalk == nil)
    }

    @Test("Una parada que ya no existe se salta; con menos de dos no hay traza")
    func onboardMissingStops() throws {
        let stops = six
        let missing = stops[4].id
        let plan = try #require(RideTracePlan(onboard(pattern: stops, current: 3),
                                              stops: { id in id == missing ? nil : stops.first { $0.id == id } }))
        #expect(plan.rides[0].stopPath == [Coordinate(stops[3]), Coordinate(stops[5])])

        #expect(RideTracePlan(onboard(pattern: stops, current: 5),
                              stops: { id in stops.first { $0.id == id } }) == nil)
    }
}
