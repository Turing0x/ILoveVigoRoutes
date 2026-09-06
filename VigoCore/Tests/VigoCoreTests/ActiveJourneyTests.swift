import Foundation
import Testing
import GRDB
@testable import VigoCore

/// `Journey`/`JourneyLeg` are public, so these tests build journeys by hand — no
/// `Timetable` or GTFS fixture needed except for the one test that exercises a real
/// reimport.
@Suite("Trayecto activo")
struct ActiveJourneyTests {

    private let base = Date(timeIntervalSince1970: 1_757_000_000)

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private var origin: Place { .coordinate(Coordinate(latitude: 42.2, longitude: -8.7), label: "O") }
    private var destination: Place { .coordinate(Coordinate(latitude: 42.3, longitude: -8.6), label: "D") }

    /// One ride with an access and an egress walk, plus an optional second ride so the
    /// round-trip test can cover a transfer with intermediate stops.
    private func journey(transfers: Int = 0) -> Journey {
        let a = PlannerFixture.stop("A1")
        let b = PlannerFixture.stop("B1", northMetres: 1_000)
        var legs: [JourneyLeg] = [
            .walk(from: origin, to: .stop(a), seconds: 120, metres: 120),
            .ride(routeID: RouteID("r1"), routeShortName: "15", headsign: "Centro",
                  tripID: TripID("t1"), board: a, alight: b,
                  departure: at(0), arrival: at(15),
                  intermediateStops: [PlannerFixture.stop("M1", northMetres: 500)]),
        ]
        if transfers > 0 {
            let c = PlannerFixture.stop("C1", northMetres: 1_500)
            legs.append(.ride(routeID: RouteID("r2"), routeShortName: "15B", headsign: "Playa",
                              tripID: TripID("t2"), board: b, alight: c,
                              departure: at(16), arrival: at(30),
                              intermediateStops: [PlannerFixture.stop("M2", northMetres: 1_200)]))
            legs.append(.walk(from: .stop(c), to: destination, seconds: 180, metres: 180))
        } else {
            legs.append(.walk(from: .stop(b), to: destination, seconds: 180, metres: 180))
        }
        return Journey(legs: legs, departure: at(0).addingTimeInterval(-120),
                       arrival: at(transfers > 0 ? 30 : 15).addingTimeInterval(180),
                       transfers: transfers)
    }

    private func repository() throws -> TransitRepository {
        TransitRepository(database: try AppDatabase.inMemory())
    }

    // MARK: - Round trip

    @Test("Round trip JSON con 2 transbordos y paradas intermedias")
    func roundTripWithTransfersAndIntermediateStops() throws {
        let snapshot = ActiveJourneySnapshot(journey(transfers: 1), originLabel: "Casa",
                                             destinationLabel: "Trabajo")
        #expect(snapshot.rides.count == 2)
        #expect(snapshot.rides[0].intermediate.map(\.name) == ["Parada M1"])
        #expect(snapshot.rides[1].intermediate.map(\.name) == ["Parada M2"])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ActiveJourneySnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    // MARK: - At most one row

    @Test("Iniciar un segundo trayecto sin terminar el primero deja exactamente uno, el segundo")
    func onlyOneActiveJourneyEver() throws {
        let repository = try repository()
        let first = ActiveJourneySnapshot(journey(), originLabel: "Casa", destinationLabel: "Uno")
        let second = ActiveJourneySnapshot(journey(), originLabel: "Casa", destinationLabel: "Dos")

        try repository.startActiveJourney(first)
        try repository.startActiveJourney(second)

        let count = try repository.database.writer.read { try ActiveJourneyRow.fetchCount($0) }
        #expect(count == 1)
        #expect(try repository.activeJourney()?.destination.name == "Dos")
    }

    // MARK: - Staleness

    @Test("staleness con now == scheduledArrival + 60 s es .active")
    func activeJustInsideGrace() throws {
        let snapshot = ActiveJourneySnapshot(journey(), originLabel: "Casa", destinationLabel: "D")
        let now = snapshot.scheduledArrival.addingTimeInterval(60)
        #expect(snapshot.staleness(now: now, grace: 90 * 60) == .active)
    }

    @Test("staleness con now == scheduledArrival + grace + 1 s es .stale")
    func staleJustPastGrace() throws {
        let snapshot = ActiveJourneySnapshot(journey(), originLabel: "Casa", destinationLabel: "D")
        let grace: TimeInterval = 90 * 60
        let now = snapshot.scheduledArrival.addingTimeInterval(grace + 1)
        guard case .stale = snapshot.staleness(now: now, grace: grace) else {
            Issue.record("expected .stale")
            return
        }
    }

    // MARK: - CRUD

    @Test("extendActiveJourney vuelve a .active y mueve la ventana")
    func extendReturnsToActiveAndMovesWindow() throws {
        let repository = try repository()
        let snapshot = ActiveJourneySnapshot(journey(), originLabel: "Casa", destinationLabel: "D")
        try repository.startActiveJourney(snapshot)
        try repository.markActiveJourneyStale()

        let extended = snapshot.scheduledArrival.addingTimeInterval(90 * 60)
        try repository.extendActiveJourney(to: extended)

        let reloaded = try #require(try repository.activeJourney())
        #expect(reloaded.scheduledArrival == extended)
        // Not stale one instant after the *original* deadline any more.
        let now = snapshot.scheduledArrival.addingTimeInterval(90 * 60 + 1)
        #expect(reloaded.staleness(now: now, grace: 90 * 60) == .active)
    }

    @Test("endActiveJourney sin trayecto activo no lanza")
    func endWithoutActiveJourneyDoesNotThrow() throws {
        let repository = try repository()
        try repository.endActiveJourney()
        #expect(try repository.activeJourney() == nil)
    }

    @Test("endActiveJourney borra la fila")
    func endRemovesTheRow() throws {
        let repository = try repository()
        try repository.startActiveJourney(
            ActiveJourneySnapshot(journey(), originLabel: "Casa", destinationLabel: "D"))
        try repository.endActiveJourney()
        #expect(try repository.activeJourney() == nil)
    }

    // MARK: - Survives a reimport

    @Test("Un trayecto guardado sigue leyéndose, con destino resoluble por coordenada, tras perder su parada")
    func survivesStopVanishingFromFeed() throws {
        let database = try Fixture.importedDatabase()
        let repository = TransitRepository(database: database)
        let stop = try #require(try repository.stop(id: StopID("3493")))

        let destinationRef = ActiveJourneySnapshot.StopRef(
            stopID: stop.id, name: stop.name, latitude: stop.latitude, longitude: stop.longitude)
        let ride = ActiveJourneySnapshot.Ride(
            routeShortName: "15", headsign: "Centro", tripID: TripID("t1"),
            board: destinationRef, alight: destinationRef, intermediate: [],
            scheduledDeparture: base, scheduledArrival: at(15))
        let snapshot = ActiveJourneySnapshot(
            originName: "Casa", destination: destinationRef, rides: [ride],
            egressWalkSeconds: 120, scheduledDeparture: base, scheduledArrival: at(15), transfers: 0)
        try repository.startActiveJourney(snapshot)

        // Simulates what a reimport does to `stop`: the importer clears and rewrites the
        // table wholesale on every refresh.
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM stop WHERE id = ?", arguments: [stop.id.rawValue])
        }

        let reloaded = try #require(try repository.activeJourney())
        #expect(reloaded.destination.stopID == stop.id, "el id se conserva aunque ya no resuelva")
        #expect(reloaded.destination.coordinate == Coordinate(stop),
                "sigue siendo dibujable por la coordenada de respaldo")
        #expect(try repository.stop(id: stop.id) == nil, "la parada ya no está en el feed")
    }
}
