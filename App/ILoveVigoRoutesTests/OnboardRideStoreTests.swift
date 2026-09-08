import Foundation
import Testing
@testable import ILoveVigoRoutes
import VigoCore
import GRDB

/// The store side of "voy en este autobús". Every test mutates through the store and reads
/// back through the repository — a second, independent path — the same contract
/// `FavouritesStoreTests` states: a write that only half happened has to be visible.
@Suite("OnboardRideStore")
@MainActor
struct OnboardRideStoreTests {

    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func makeStore() throws -> (OnboardRideStore, TransitRepository) {
        let database = try AppDatabase.inMemory()
        let repository = TransitRepository(database: database)
        let store = OnboardRideStore(repository: repository,
                                     timetableStore: TimetableStore(repository: repository))
        return (store, repository)
    }

    private func ride(position: Int = 1, updatedAt: Date? = nil) -> OnboardRide {
        let stop = OnboardRide.StopRef(stopID: StopID("8002"), name: "Areal",
                                       latitude: 42.23, longitude: -8.72)
        return OnboardRide(
            routeShortName: "11", headsign: "Navia",
            patternStopIDs: [StopID("8001"), StopID("8002"), StopID("8003")],
            tripID: TripID("T1"),
            boardStop: stop, boardPosition: 0,
            currentStop: stop, currentPosition: position,
            scheduledAtCurrent: now, observedDelaySeconds: 0,
            declaredAt: now, updatedAt: updatedAt ?? now, confidence: .inferred)
    }

    private func journey() -> Journey {
        let a = Stop(id: StopID("8002"), gtfsStopCode: "P8002", vitrasaCode: VitrasaStopCode(8002),
                     name: "Areal", searchName: "areal", latitude: 42.23, longitude: -8.72,
                     wheelchairBoarding: nil)
        let b = Stop(id: StopID("8003"), gtfsStopCode: "P8003", vitrasaCode: VitrasaStopCode(8003),
                     name: "Policarpo Sanz", searchName: "policarpo sanz",
                     latitude: 42.24, longitude: -8.73, wheelchairBoarding: nil)
        return Journey(
            legs: [.ride(routeID: RouteID("R1"), routeShortName: "11", headsign: "Navia",
                         tripID: TripID("T1"), board: a, alight: b,
                         departure: now, arrival: now.addingTimeInterval(600),
                         intermediateStops: [])],
            departure: now, arrival: now.addingTimeInterval(600), transfers: 0)
    }

    @Test("Declarar un autobús lo deja visible para cualquier lector")
    func declareIsVisibleToAnyReader() throws {
        let (store, repository) = try makeStore()
        #expect(store.ride == nil)

        store.declare(ride())

        #expect(store.ride?.routeShortName == "11")
        #expect(try repository.onboardRide()?.currentStop.name == "Areal")
    }

    @Test("Bajarse lo borra por las dos vías")
    func endClearsIt() throws {
        let (store, repository) = try makeStore()
        store.declare(ride())
        store.end()

        #expect(store.ride == nil)
        #expect(try repository.onboardRide() == nil)
    }

    @Test("Aceptar un plan convierte el autobús suelto en trayecto activo, sin dejar los dos")
    func acceptPromotesToActiveJourney() throws {
        let (store, repository) = try makeStore()
        store.declare(ride())

        let snapshot = store.accept(journey(), destinationLabel: "Biblioteca")

        #expect(snapshot?.originName == "En el 11")
        #expect(store.ride == nil)
        #expect(try repository.onboardRide() == nil)
        #expect(try repository.activeJourney()?.destination.name == "Biblioteca")
    }

    @Test("Un autobús sin posición nueva en media hora pasa a preguntarse")
    func stalenessFollowsTheLastFix() throws {
        let (store, _) = try makeStore()
        store.declare(ride(updatedAt: now.addingTimeInterval(-40 * 60)))

        store.reload(now: now)

        guard case .stale = store.staleness else {
            Issue.record("se esperaba que hubiera caducado, llegó \(store.staleness)"); return
        }
    }
}
