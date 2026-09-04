import Foundation
import Testing
@testable import ILoveVigoRoutes
import VigoCore
import GRDB

/// Regression coverage for the staleness bug this store exists to fix: before
/// `FavouritesStore`, `StopDetailModel.isFavourite` was a snapshot and `FavouritesModel`
/// kept its own `[Stop]`, so toggling a star in one screen left another screen wrong until
/// it happened to reload. Every test here reads through a second, independent path after
/// mutating through a first.
@Suite("FavouritesStore")
@MainActor
struct FavouritesStoreTests {

    private func makeStore(stops: [Stop] = []) throws -> (FavouritesStore, TransitRepository) {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            for stop in stops { try stop.insert(db) }
        }
        let repository = TransitRepository(database: database)
        return (FavouritesStore(repository: repository), repository)
    }

    private func stop(_ id: String, name: String = "Parada") -> Stop {
        Stop(id: StopID(id), gtfsStopCode: "P\(id)", vitrasaCode: VitrasaStopCode(Int(id) ?? 0),
             name: name, searchName: name.lowercased(),
             latitude: 42.23, longitude: -8.72, wheelchairBoarding: nil)
    }

    @Test("Una favorita marcada por un lector aparece de inmediato para otro")
    func toggleIsVisibleToAnyReader() throws {
        let a = stop("1", name: "Gran Vía")
        let (store, _) = try makeStore(stops: [a])
        #expect(!store.contains(a.id))

        store.toggle(a)

        // Two independent readers: the raw `contains` check and the resolved `stops` list.
        #expect(store.contains(a.id))
        #expect(store.stops.map(\.id) == [a.id])

        store.toggle(a)
        #expect(!store.contains(a.id))
        #expect(store.stops.isEmpty)
    }

    @Test("Un segundo store sobre la misma base ve el cambio tras recargar")
    func mutationThroughOneStoreIsVisibleAfterReloadOnAnother() throws {
        let a = stop("1", name: "Gran Vía")
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in try a.insert(db) }
        let repository = TransitRepository(database: database)

        let writer = FavouritesStore(repository: repository)
        let reader = FavouritesStore(repository: repository)
        #expect(!reader.contains(a.id))

        writer.toggle(a)
        // Simulates what `StopDetailView`'s star and `FavouritesView`'s list now share:
        // the same repository, observed independently, agreeing once each has reloaded.
        reader.reload()
        #expect(reader.contains(a.id))
        #expect(reader.stops.map(\.id) == [a.id])
    }

    @Test("Quitar por índice persiste y sobrevive a una recarga")
    func removeAtOffsetsPersists() throws {
        let a = stop("1", name: "Gran Vía")
        let b = stop("2", name: "Urzáiz")
        let (store, repository) = try makeStore(stops: [a, b])
        store.toggle(a)
        store.toggle(b)
        #expect(store.stops.map(\.id) == [a.id, b.id])

        store.remove(atOffsets: IndexSet(integer: 0))
        #expect(store.stops.map(\.id) == [b.id])

        // Independent of the store's own cache: ask the repository directly.
        #expect(try repository.favouriteStopIDs() == [b.id])
    }

    @Test("Reordenar persiste y sobrevive a una recarga")
    func movePersists() throws {
        let a = stop("1", name: "Gran Vía")
        let b = stop("2", name: "Urzáiz")
        let (store, repository) = try makeStore(stops: [a, b])
        store.toggle(a)
        store.toggle(b)
        #expect(store.stops.map(\.id) == [a.id, b.id])

        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(store.stops.map(\.id) == [b.id, a.id])

        store.reload()
        #expect(store.stops.map(\.id) == [b.id, a.id])
        #expect(try repository.favouriteStopIDs() == [b.id, a.id])
    }

    @Test("Una favorita cuya parada ya no existe en el feed queda en unresolvedIDs, no en stops")
    func vanishedStopIsUnresolvedNotHidden() throws {
        // A GTFS reimport deletes and rewrites `stop` wholesale, so a favourite can point
        // at a stop_id the current feed no longer has. Simulated here without ever
        // inserting the stop, rather than deleting it — same end state, and it keeps this
        // test on the repository's public API instead of reaching for GRDB directly.
        let vanished = StopID("999")
        let (store, repository) = try makeStore()
        try repository.setFavourite(vanished, true)
        store.reload()

        #expect(store.stops.isEmpty)
        #expect(store.unresolvedIDs == [vanished])
        #expect(store.contains(vanished), "sigue siendo favorita aunque no se pueda resolver")
    }
}
