import Testing
import Foundation
@testable import VigoCore

@Suite("Búsquedas recientes")
struct RecentSearchTests {

    // MARK: - RecentSearchKey (pura)

    @Test("Mi ubicación, un lugar guardado y un POI no se recuerdan")
    func excludedOrigins() throws {
        #expect(RecentSearchKey.candidate(for: .currentLocation(Coordinate(latitude: 42.22, longitude: -8.73))) == nil)
        let saved = SavedPlace(id: SavedPlaceID("p1"), name: "Casa", symbolName: "house.fill",
                               anchor: .coordinate(Coordinate(latitude: 42.22, longitude: -8.73)),
                               createdAt: Date(), sortIndex: 0)
        #expect(RecentSearchKey.candidate(for: .savedPlace(saved)) == nil)
        let poi = MapPlace(place: .coordinate(Coordinate(latitude: 42.22, longitude: -8.73), label: "Cafetería"),
                           subtitle: nil, origin: .pointOfInterest)
        #expect(RecentSearchKey.candidate(for: poi) == nil)
    }

    @Test("Una parada usa su stopID, no su coordenada")
    func stopCandidate() throws {
        let stop = try #require(try TransitRepository(database: Fixture.importedDatabase())
            .stop(id: StopID("3493")))
        let candidate = try #require(RecentSearchKey.candidate(for: .stop(stop)))
        #expect(candidate.dedupKey == "stop:3493")
        #expect(candidate.originKind == "stop")
    }

    @Test("Dos puntos a 3 m con el mismo nombre coinciden; a 40 m no")
    func pointRoundingDistinguishesFarPointsOnly() {
        let base = MapPlace.droppedPin(Coordinate(latitude: 42.220000, longitude: -8.730000), name: "Sitio")
        // ~3 m north: rounds to the same 4-decimal (~11 m) bucket as `base`.
        let near = MapPlace.droppedPin(Coordinate(latitude: 42.220030, longitude: -8.730000), name: "Sitio")
        // ~40 m north: outside it.
        let far = MapPlace.droppedPin(Coordinate(latitude: 42.220360, longitude: -8.730000), name: "Sitio")

        let baseKey = RecentSearchKey.candidate(for: base)?.dedupKey
        #expect(baseKey == RecentSearchKey.candidate(for: near)?.dedupKey)
        #expect(baseKey != RecentSearchKey.candidate(for: far)?.dedupKey)
    }

    @Test("Acentos y mayúsculas distintas en el mismo punto dan la misma clave")
    func nameFoldingCollapsesAccents() {
        let coordinate = Coordinate(latitude: 42.24, longitude: -8.71)
        let a = MapPlace(place: .coordinate(coordinate, label: "Rúa Príncipe"), subtitle: nil, origin: .address)
        let b = MapPlace(place: .coordinate(coordinate, label: "RUA PRINCIPE"), subtitle: nil, origin: .address)
        #expect(RecentSearchKey.candidate(for: a)?.dedupKey == RecentSearchKey.candidate(for: b)?.dedupKey)
    }

    // MARK: - TransitRepository CRUD

    @Test("Registrar una parada la deja legible, con nombre, subtítulo e icono")
    func recordsAndReadsAStop() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let stop = try #require(try repository.stop(id: StopID("3493")))
        try repository.recordRecentSearch(.stop(stop))

        let recents = try repository.recentSearches()
        #expect(recents.count == 1)
        let recent = try #require(recents.first)
        #expect(recent.dedupKey == "stop:3493")
        #expect(recent.name == stop.name)
        #expect(recent.stopID == stop.id)
        #expect(recent.place == .stop(stop))
    }

    @Test("Elegir la misma parada dos veces deja una fila, con lastUsedAt actualizado")
    func reselectingUpdatesLastUsedAtInsteadOfInserting() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let stop = try #require(try repository.stop(id: StopID("3493")))
        let first = Fixture.date(2026, 9, 4, 8, 0)
        let second = Fixture.date(2026, 9, 5, 9, 0)

        try repository.recordRecentSearch(.stop(stop), at: first)
        try repository.recordRecentSearch(.stop(stop), at: second)

        let recents = try repository.recentSearches()
        #expect(recents.count == 1)
        #expect(recents.first?.lastUsedAt == second)
    }

    @Test("Borrar una fila la quita; borrar todas vacía la lista")
    func deleteOneAndClearAll() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let stop3493 = try #require(try repository.stop(id: StopID("3493")))
        let stop3885 = try #require(try repository.stop(id: StopID("3885")))
        try repository.recordRecentSearch(.stop(stop3493))
        try repository.recordRecentSearch(.stop(stop3885))
        #expect(try repository.recentSearches().count == 2)

        try repository.deleteRecentSearch(dedupKey: "stop:3493")
        let afterOne = try repository.recentSearches()
        #expect(afterOne.count == 1)
        #expect(afterOne.first?.dedupKey == "stop:3885")

        try repository.clearRecentSearches()
        #expect(try repository.recentSearches().isEmpty)
    }

    @Test("Un stopID huérfano tras la reimportación sigue usable, con el nombre guardado")
    func orphanedStopStaysUsable() throws {
        let database = try Fixture.importedDatabase()
        let repository = TransitRepository(database: database)
        let stop = try #require(try repository.stop(id: StopID("3493")))
        let fallback = Coordinate(stop)
        try repository.recordRecentSearch(.stop(stop))

        let withoutStop = Self.fixtureWithoutStop3493()
        _ = try GTFSImporter(database: database).import(feed: try GTFSParser().parse(from: withoutStop).feed)

        let recents = try repository.recentSearches()
        let reloaded = try #require(recents.first)
        #expect(reloaded.anchor.isOrphaned)
        #expect(reloaded.coordinate == fallback)
        #expect(reloaded.name == stop.name, "no se borra en silencio: sigue con el nombre guardado")
        #expect(reloaded.place == .coordinate(fallback, label: stop.name))
    }

    /// Same shape as `SavedPlacesTests.fixtureWithoutStop3493()` — kept local rather than
    /// shared, matching how that file already does it.
    private static func fixtureWithoutStop3493() -> GTFSInMemory {
        let stopsWithout3493 = """
        stop_id,stop_code,stop_name,stop_lat,stop_lon,wheelchair_boarding
        3885,P0014264,Rúa de Urzáiz - Príncipe,42.2358735452815,-8.72008331665535,1
        4856,PA20113,Praza de América  3 (Dirección Hospital),42.2208765659118,-8.73336764352841,0
        9999,,Parada sen código,42.2300000000000,-8.72000000000000,0
        """
        let stopTimesWithout3493 = """
        trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
        T_DAY_1,08:12:00,08:12:00,3885,2,0,0
        T_NIGHT_1,25:22:00,25:22:00,3885,2,0,0
        T_SUN_1,10:00:00,10:00:00,4856,1,0,0
        T_SUN_1,10:20:00,10:20:00,3885,2,0,0
        """
        return GTFSInMemory(texts: [
            "agency.txt": Fixture.agency,
            "stops.txt": stopsWithout3493,
            "routes.txt": Fixture.routes,
            "trips.txt": Fixture.trips,
            "stop_times.txt": stopTimesWithout3493,
            "calendar.txt": Fixture.calendar,
            "calendar_dates.txt": Fixture.calendarDates,
            "shapes.txt": Fixture.shapes,
        ])
    }
}
