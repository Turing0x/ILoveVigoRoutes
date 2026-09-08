import Foundation
import Testing
import GRDB
@testable import VigoCore

/// The stored side of the onboard ride: written through the repository, read back through a
/// second, independent path — the raw row — so a write that only half happened is visible.
@Suite("Bus en marcha, guardado")
struct OnboardRidePersistenceTests {

    private let base = Date(timeIntervalSince1970: 1_757_000_000)

    private func ride(position: Int = 1, delay: Int = 0, name: String = "Areal") -> OnboardRide {
        let stop = PlannerFixture.stop("8002", northMetres: 600, name: name)
        return OnboardRide(
            routeShortName: "9B.", headsign: "Navia",
            patternStopIDs: [StopID("8001"), StopID("8002"), StopID("8003")],
            tripID: TripID("T1_0800"),
            boardStop: .from(PlannerFixture.stop("8001", name: "Colón")), boardPosition: 0,
            currentStop: .from(stop), currentPosition: position,
            scheduledAtCurrent: base, observedDelaySeconds: delay,
            declaredAt: base, updatedAt: base, confidence: .inferred)
    }

    private func journey() -> Journey {
        let a = PlannerFixture.stop("8002", northMetres: 600, name: "Areal")
        let b = PlannerFixture.stop("8003", northMetres: 1_200, name: "Policarpo Sanz")
        return Journey(
            legs: [.ride(routeID: RouteID("R1"), routeShortName: "9B.", headsign: "Navia",
                         tripID: TripID("T1_0800"), board: a, alight: b,
                         departure: base, arrival: base.addingTimeInterval(600),
                         intermediateStops: [])],
            departure: base, arrival: base.addingTimeInterval(600), transfers: 0)
    }

    @Test("Se guarda y se lee entero, y las columnas planas dicen lo mismo que el JSON")
    func roundTripAndFlatColumnsAgree() throws {
        let database = try AppDatabase.inMemory()
        let repository = TransitRepository(database: database)
        try repository.startOnboardRide(ride())

        #expect(try repository.onboardRide() == ride())

        let row = try database.writer.read {
            try OnboardRideRow.fetchOne($0, key: OnboardRideRow.currentID)
        }
        let stored = try #require(row)
        #expect(stored.normalizedLine == "9B")
        #expect(stored.currentStopName == "Areal")
        #expect(stored.currentPosition == 1)
    }

    @Test("Avanzar reescribe las columnas planas y el JSON en la misma escritura")
    func updateKeepsColumnsAndPayloadInStep() throws {
        let database = try AppDatabase.inMemory()
        let repository = TransitRepository(database: database)
        try repository.startOnboardRide(ride())

        let moved = ride(position: 2, delay: 180, name: "Policarpo Sanz")
        try repository.updateOnboardRide(moved)

        let row = try #require(try database.writer.read {
            try OnboardRideRow.fetchOne($0, key: OnboardRideRow.currentID)
        })
        let decoded = try JSONDecoder().decode(OnboardRide.self, from: row.payload)
        #expect(row.currentPosition == 2)
        #expect(row.observedDelaySeconds == 180)
        #expect(decoded.currentPosition == row.currentPosition)
        #expect(decoded.observedDelaySeconds == row.observedDelaySeconds)
        #expect(decoded.currentStop.name == row.currentStopName)
    }

    @Test("Declarar un segundo autobús deja exactamente uno, el segundo")
    func secondDeclarationReplacesTheFirst() throws {
        let database = try AppDatabase.inMemory()
        let repository = TransitRepository(database: database)
        try repository.startOnboardRide(ride())
        try repository.startOnboardRide(ride(position: 2, name: "Policarpo Sanz"))

        #expect(try database.writer.read { try OnboardRideRow.fetchCount($0) } == 1)
        #expect(try repository.onboardRide()?.currentStop.name == "Policarpo Sanz")
    }

    @Test("Ir montado y seguir un trayecto activo son estados excluyentes")
    func onboardAndActiveJourneyAreMutuallyExclusive() throws {
        let database = try AppDatabase.inMemory()
        let repository = TransitRepository(database: database)
        let snapshot = ActiveJourneySnapshot(journey(), originLabel: "Areal",
                                             destinationLabel: "Biblioteca")
        try repository.startActiveJourney(snapshot)

        try repository.startOnboardRide(ride())
        #expect(try repository.activeJourney() == nil, "declarar un autobús termina el plan")
        #expect(try repository.onboardRide() != nil)

        try repository.acceptOnboardRide(as: snapshot)
        #expect(try repository.onboardRide() == nil, "aceptar un plan cierra el autobús suelto")
        #expect(try repository.activeJourney() != nil)
    }

    @Test("Actualizar sin autobús declarado no crea uno de la nada")
    func updateWithoutARideIsANoOp() throws {
        let database = try AppDatabase.inMemory()
        let repository = TransitRepository(database: database)
        try repository.updateOnboardRide(ride())
        #expect(try repository.onboardRide() == nil)
    }

    @Test("Bajarse borra la fila")
    func endDeletesTheRow() throws {
        let database = try AppDatabase.inMemory()
        let repository = TransitRepository(database: database)
        try repository.startOnboardRide(ride())
        try repository.endOnboardRide()
        #expect(try database.writer.read { try OnboardRideRow.fetchCount($0) } == 0)
    }
}
