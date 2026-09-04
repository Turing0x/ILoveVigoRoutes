import Foundation
import Testing
@testable import ILoveVigoRoutes
import VigoCore

@Suite("SavedPlacesStore")
@MainActor
struct SavedPlacesStoreTests {

    private func makeStore() throws -> (SavedPlacesStore, TransitRepository) {
        let repository = TransitRepository(database: try AppDatabase.inMemory())
        return (SavedPlacesStore(repository: repository), repository)
    }

    /// A template only prefills name and icon — there is no template column, no
    /// uniqueness, and two places built from the same template must coexist with
    /// independent names, same as any other pair of saved places.
    @Test("Two places from the same template coexist independently")
    func templatesAreNotSingletons() throws {
        let (store, _) = try makeStore()
        let home1 = store.createPlace(
            name: "Casa", symbolName: "house.fill",
            anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        let home2 = store.createPlace(
            name: "Casa de mis padres", symbolName: "house.fill",
            anchor: .coordinate(.init(latitude: 2, longitude: 2)))

        #expect(store.places.count == 2)
        #expect(store.places.first { $0.id == home1?.id }?.name == "Casa")
        #expect(store.places.first { $0.id == home2?.id }?.name == "Casa de mis padres")
        #expect(store.places.allSatisfy { $0.symbolName == "house.fill" })
    }

    @Test("Full CRUD loop: create, rename, re-icon, re-anchor, delete, reorder")
    func fullCRUDLoop() throws {
        let (store, _) = try makeStore()

        // Create
        let a = try #require(store.createPlace(
            name: "A", symbolName: "mappin", anchor: .coordinate(.init(latitude: 1, longitude: 1))))
        let b = try #require(store.createPlace(
            name: "B", symbolName: "mappin", anchor: .coordinate(.init(latitude: 2, longitude: 2))))
        #expect(store.places.map(\.id) == [a.id, b.id])

        // Rename
        store.updatePlace(id: a.id, SavedPlaceEdit(name: "A renombrada"))
        #expect(store.places.first { $0.id == a.id }?.name == "A renombrada")

        // Re-icon
        store.updatePlace(id: a.id, SavedPlaceEdit(symbolName: "star.fill"))
        #expect(store.places.first { $0.id == a.id }?.symbolName == "star.fill")

        // Re-anchor
        let newCoordinate = Coordinate(latitude: 9, longitude: 9)
        store.updatePlace(id: a.id, SavedPlaceEdit(anchor: .coordinate(newCoordinate)))
        #expect(store.places.first { $0.id == a.id }?.coordinate == newCoordinate)

        // Reorder
        store.movePlaces(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(store.places.map(\.id) == [b.id, a.id])

        // Delete
        store.deletePlace(id: b.id)
        #expect(store.places.map(\.id) == [a.id])
    }

    @Test("removePlaces(atOffsets:) deletes by list position and persists")
    func removePlacesAtOffsets() throws {
        let (store, repository) = try makeStore()
        let a = try #require(store.createPlace(name: "A", symbolName: "mappin", anchor: .coordinate(.init(latitude: 1, longitude: 1))))
        _ = store.createPlace(name: "B", symbolName: "mappin", anchor: .coordinate(.init(latitude: 2, longitude: 2)))

        store.removePlaces(atOffsets: IndexSet(integer: 0))
        #expect(store.places.map(\.name) == ["B"])
        #expect(try repository.savedPlace(id: a.id) == nil)
    }

    @Test("Full journey CRUD loop through the store")
    func journeyCRUDLoop() throws {
        let (store, _) = try makeStore()
        let home = try #require(store.createPlace(name: "Casa", symbolName: "house.fill", anchor: .coordinate(.init(latitude: 1, longitude: 1))))
        let work = try #require(store.createPlace(name: "Trabajo", symbolName: "briefcase.fill", anchor: .coordinate(.init(latitude: 2, longitude: 2))))

        let journey = try #require(store.createJourney(
            customLabel: nil, origin: .savedPlace(home), destination: .savedPlace(work)))
        #expect(store.journeys.map(\.id) == [journey.id])
        #expect(journey.displayLabel == "Casa → Trabajo")

        store.updateJourney(id: journey.id, SavedJourneyEdit(label: .custom("Ida al curro")))
        #expect(store.journeys.first?.displayLabel == "Ida al curro")

        store.deleteJourney(id: journey.id)
        #expect(store.journeys.isEmpty)
    }

    @Test("reload() picks up mutations made through a different repository instance")
    func reloadPicksUpExternalMutations() throws {
        let database = try AppDatabase.inMemory()
        let repository = TransitRepository(database: database)
        let store = SavedPlacesStore(repository: repository)
        #expect(store.places.isEmpty)

        try repository.createSavedPlace(
            name: "Gimnasio", symbolName: "figure.run", anchor: .coordinate(.init(latitude: 3, longitude: 3)))
        #expect(store.places.isEmpty, "no observa la base directamente")

        store.reload()
        #expect(store.places.map(\.name) == ["Gimnasio"])
    }
}
