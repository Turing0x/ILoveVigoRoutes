import Testing
import Foundation
@testable import VigoCore

@Suite("Saved places and journeys")
struct SavedPlacesTests {

    // MARK: - Places: create / read

    @Test("Creates and reads a coordinate-anchored place")
    func createCoordinatePlace() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let coordinate = Coordinate(latitude: 42.24, longitude: -8.71)
        let created = try repository.createSavedPlace(
            name: "Gimnasio", symbolName: "figure.run", anchor: .coordinate(coordinate))

        #expect(created.name == "Gimnasio")
        #expect(created.symbolName == "figure.run")
        #expect(created.anchor == .coordinate(coordinate))
        #expect(created.sortIndex == 0)

        // Not a full-struct `==`: `createdAt` round-trips through SQLite's datetime
        // storage, which is not guaranteed to preserve sub-millisecond precision.
        let fetched = try #require(try repository.savedPlace(id: created.id))
        #expect(fetched.id == created.id)
        #expect(fetched.name == created.name)
        #expect(fetched.symbolName == created.symbolName)
        #expect(fetched.anchor == created.anchor)
        #expect(fetched.sortIndex == created.sortIndex)
    }

    @Test("Creates and reads a stop-anchored place, resolved to the live stop")
    func createStopPlace() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let stop = try #require(try repository.stop(id: StopID("3493")))
        let created = try repository.createSavedPlace(
            name: "Casa", symbolName: "house.fill", anchor: .stop(stop))

        #expect(created.anchor.resolvedStop == stop)
        #expect(!created.anchor.isOrphaned)
        #expect(created.coordinate == Coordinate(stop))
    }

    @Test("sortIndex is assigned monotonically")
    func sortIndexIsMonotonic() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let a = try repository.createSavedPlace(name: "A", symbolName: "mappin", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        let b = try repository.createSavedPlace(name: "B", symbolName: "mappin", anchor: .coordinate(.init(latitude: 2, longitude: 2)))
        let c = try repository.createSavedPlace(name: "C", symbolName: "mappin", anchor: .coordinate(.init(latitude: 3, longitude: 3)))
        let indices = [a.sortIndex, b.sortIndex, c.sortIndex]
        #expect(indices == [0, 1, 2])
        #expect(try repository.savedPlaces().map(\.id) == [a.id, b.id, c.id])
    }

    /// Casa, Trabajo, Hospital and Centro de salud are templates that prefill a name and an
    /// icon and nothing else — never singleton slots. Two places from the same template
    /// must coexist with independent names, same as any other pair of saved places.
    @Test("Two places created from the same template coexist independently")
    func templatesAreNotSingletons() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let home1 = try repository.createSavedPlace(
            name: "Casa", symbolName: "house.fill", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        let home2 = try repository.createSavedPlace(
            name: "Casa de mis padres", symbolName: "house.fill", anchor: .coordinate(.init(latitude: 2, longitude: 2)))
        let places = try repository.savedPlaces()
        #expect(places.map(\.id).contains(home1.id))
        #expect(places.map(\.id).contains(home2.id))
        #expect(places.first { $0.id == home1.id }?.name == "Casa")
        #expect(places.first { $0.id == home2.id }?.name == "Casa de mis padres")
    }

    // MARK: - Places: update

    @Test("Renaming only touches the name")
    func renameOnly() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let original = try repository.createSavedPlace(
            name: "Casa", symbolName: "house.fill", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        try repository.updateSavedPlace(id: original.id, SavedPlaceEdit(name: "Piso nuevo"))
        let updated = try #require(try repository.savedPlace(id: original.id))
        #expect(updated.name == "Piso nuevo")
        #expect(updated.symbolName == original.symbolName)
        #expect(updated.anchor == original.anchor)
    }

    @Test("Changing the icon only touches the icon")
    func iconOnly() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let original = try repository.createSavedPlace(
            name: "Casa", symbolName: "house.fill", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        try repository.updateSavedPlace(id: original.id, SavedPlaceEdit(symbolName: "house.circle"))
        let updated = try #require(try repository.savedPlace(id: original.id))
        #expect(updated.symbolName == "house.circle")
        #expect(updated.name == original.name)
        #expect(updated.anchor == original.anchor)
    }

    @Test("Re-anchoring from a stop to a coordinate leaves name and icon untouched")
    func reanchorStopToCoordinate() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let stop = try #require(try repository.stop(id: StopID("3493")))
        let original = try repository.createSavedPlace(name: "Casa", symbolName: "house.fill", anchor: .stop(stop))
        let newCoordinate = Coordinate(latitude: 42.25, longitude: -8.70)
        try repository.updateSavedPlace(id: original.id, SavedPlaceEdit(anchor: .coordinate(newCoordinate)))
        let updated = try #require(try repository.savedPlace(id: original.id))
        #expect(updated.anchor == .coordinate(newCoordinate))
        #expect(updated.name == "Casa")
        #expect(updated.symbolName == "house.fill")
    }

    @Test("Re-anchoring from a coordinate to a stop resolves the live stop")
    func reanchorCoordinateToStop() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let original = try repository.createSavedPlace(
            name: "Casa", symbolName: "house.fill", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        let stop = try #require(try repository.stop(id: StopID("3885")))
        try repository.updateSavedPlace(id: original.id, SavedPlaceEdit(anchor: .stop(stop)))
        let updated = try #require(try repository.savedPlace(id: original.id))
        #expect(updated.anchor.resolvedStop == stop)
    }

    // MARK: - Places: delete / reorder

    @Test("Deleting a place removes only that row")
    func deleteRemovesOneRow() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let a = try repository.createSavedPlace(name: "A", symbolName: "mappin", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        let b = try repository.createSavedPlace(name: "B", symbolName: "mappin", anchor: .coordinate(.init(latitude: 2, longitude: 2)))
        try repository.deleteSavedPlace(id: a.id)
        #expect(try repository.savedPlaces().map(\.id) == [b.id])
        #expect(try repository.savedPlace(id: a.id) == nil)
    }

    @Test("Reordering persists and survives a fresh repository")
    func reorderPersists() throws {
        let database = try Fixture.importedDatabase()
        let repository = TransitRepository(database: database)
        let a = try repository.createSavedPlace(name: "A", symbolName: "mappin", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        let b = try repository.createSavedPlace(name: "B", symbolName: "mappin", anchor: .coordinate(.init(latitude: 2, longitude: 2)))
        let c = try repository.createSavedPlace(name: "C", symbolName: "mappin", anchor: .coordinate(.init(latitude: 3, longitude: 3)))
        try repository.reorderSavedPlaces([c.id, a.id, b.id])

        let fresh = TransitRepository(database: database)
        #expect(try fresh.savedPlaces().map(\.id) == [c.id, a.id, b.id])
    }

    // MARK: - Places: stay live across a reimport, or degrade honestly

    @Test("A stop-anchored place resolves to the live stop, not a persisted snapshot")
    func resolvesLiveStopAcrossReimport() throws {
        let database = try Fixture.importedDatabase()
        let repository = TransitRepository(database: database)
        let stop = try #require(try repository.stop(id: StopID("3493")))
        let place = try repository.createSavedPlace(name: "Casa", symbolName: "house.fill", anchor: .stop(stop))
        #expect(place.anchor.resolvedStop?.name == "Praza de América  1")

        let renamed = Self.fixtureRenamingStop3493(to: "Praza Renombrada")
        _ = try GTFSImporter(database: database).import(feed: try GTFSParser().parse(from: renamed).feed)

        let reloaded = try #require(try repository.savedPlace(id: place.id))
        #expect(reloaded.anchor.resolvedStop?.name == "Praza Renombrada",
                "no debe haberse persistido un Stop congelado")
        #expect(reloaded.name == "Casa", "el nombre es del usuario, no depende del feed")
    }

    @Test("A stop-anchored place degrades to orphaned, still usable, when its stop vanishes")
    func orphansWhenStopVanishesFromFeed() throws {
        let database = try Fixture.importedDatabase()
        let repository = TransitRepository(database: database)
        let stop = try #require(try repository.stop(id: StopID("3493")))
        let fallback = Coordinate(stop)
        let place = try repository.createSavedPlace(name: "Casa", symbolName: "house.fill", anchor: .stop(stop))

        let withoutStop = Self.fixtureWithoutStop3493()
        _ = try GTFSImporter(database: database).import(feed: try GTFSParser().parse(from: withoutStop).feed)

        let reloaded = try #require(try repository.savedPlace(id: place.id))
        #expect(reloaded.anchor.isOrphaned)
        #expect(reloaded.anchor.resolvedStop == nil)
        #expect(reloaded.coordinate == fallback)
        #expect(reloaded.place == .coordinate(fallback, label: "Casa"), "sigue siendo planificable")
        #expect(reloaded.name == "Casa")
    }

    // MARK: - Journeys

    @Test("Creates and reads a journey between two saved places")
    func createJourneyFromSavedPlaces() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let home = try repository.createSavedPlace(
            name: "Casa", symbolName: "house.fill", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        let work = try repository.createSavedPlace(
            name: "Trabajo", symbolName: "briefcase.fill", anchor: .coordinate(.init(latitude: 2, longitude: 2)))

        let journey = try repository.createSavedJourney(
            customLabel: nil, origin: .savedPlace(home), destination: .savedPlace(work))

        #expect(journey.displayLabel == "Casa → Trabajo")
        #expect(journey.origin.placeID == home.id)
        #expect(journey.destination.placeID == work.id)
        #expect(!journey.origin.isDetached)

        // Not a full-struct `==`: `createdAt` round-trips through SQLite's datetime
        // storage, which is not guaranteed to preserve sub-millisecond precision.
        let fetched = try #require(try repository.savedJourney(id: journey.id))
        #expect(fetched.id == journey.id)
        #expect(fetched.customLabel == journey.customLabel)
        #expect(fetched.origin == journey.origin)
        #expect(fetched.destination == journey.destination)
        #expect(fetched.sortIndex == journey.sortIndex)
        #expect(try repository.savedJourneys().map(\.id) == [journey.id])
    }

    @Test("Renaming a saved place propagates to the journey's derived label")
    func renamingPlacePropagatesToJourney() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let home = try repository.createSavedPlace(
            name: "Casa", symbolName: "house.fill", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        let work = try repository.createSavedPlace(
            name: "Trabajo", symbolName: "briefcase.fill", anchor: .coordinate(.init(latitude: 2, longitude: 2)))
        let journey = try repository.createSavedJourney(
            customLabel: nil, origin: .savedPlace(home), destination: .savedPlace(work))

        try repository.updateSavedPlace(id: home.id, SavedPlaceEdit(name: "Piso nuevo"))

        let reloaded = try #require(try repository.savedJourney(id: journey.id))
        #expect(reloaded.origin.name == "Piso nuevo")
        #expect(reloaded.displayLabel == "Piso nuevo → Trabajo")
    }

    @Test("Deleting a saved place detaches the journey's endpoint instead of breaking it")
    func deletingPlaceDetachesEndpoint() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let home = try repository.createSavedPlace(
            name: "Casa", symbolName: "house.fill", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        let work = try repository.createSavedPlace(
            name: "Trabajo", symbolName: "briefcase.fill", anchor: .coordinate(.init(latitude: 2, longitude: 2)))
        let journey = try repository.createSavedJourney(
            customLabel: nil, origin: .savedPlace(home), destination: .savedPlace(work))

        try repository.deleteSavedPlace(id: home.id)

        let reloaded = try #require(try repository.savedJourney(id: journey.id))
        #expect(reloaded.origin.isDetached)
        #expect(reloaded.origin.placeID == nil)
        #expect(reloaded.origin.name == "Casa", "el nombre queda de la instantánea")
        #expect(reloaded.origin.coordinate == Coordinate(latitude: 1, longitude: 1))
        #expect(!reloaded.destination.isDetached, "el otro extremo no se ve afectado")
        #expect(reloaded.destination.placeID == work.id)
        // The journey as a whole must survive and still be usable.
        #expect(try repository.savedJourneys().map(\.id).contains(journey.id))
    }

    @Test("A custom label overrides the derived one, and clearing it restores propagation")
    func customLabelOverridesAndCanBeCleared() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let home = try repository.createSavedPlace(
            name: "Casa", symbolName: "house.fill", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        let work = try repository.createSavedPlace(
            name: "Trabajo", symbolName: "briefcase.fill", anchor: .coordinate(.init(latitude: 2, longitude: 2)))
        let journey = try repository.createSavedJourney(
            customLabel: nil, origin: .savedPlace(home), destination: .savedPlace(work))

        try repository.updateSavedJourney(id: journey.id, SavedJourneyEdit(label: .custom("Mi viaje diario")))
        var reloaded = try #require(try repository.savedJourney(id: journey.id))
        #expect(reloaded.displayLabel == "Mi viaje diario")

        // A rename must not leak through a custom label.
        try repository.updateSavedPlace(id: home.id, SavedPlaceEdit(name: "Piso nuevo"))
        reloaded = try #require(try repository.savedJourney(id: journey.id))
        #expect(reloaded.displayLabel == "Mi viaje diario")

        try repository.updateSavedJourney(id: journey.id, SavedJourneyEdit(label: .derived))
        reloaded = try #require(try repository.savedJourney(id: journey.id))
        #expect(reloaded.displayLabel == "Piso nuevo → Trabajo", "vuelve a propagar")
    }

    @Test("An ad-hoc endpoint round-trips detached, never linked to a saved place")
    func adHocEndpointRoundTrips() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let home = try repository.createSavedPlace(
            name: "Casa", symbolName: "house.fill", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        let adHocCoordinate = Coordinate(latitude: 5, longitude: 5)
        let journey = try repository.createSavedJourney(
            customLabel: nil, origin: .savedPlace(home),
            destination: .adHoc(name: "Aeropuerto de Peinador", anchor: .coordinate(adHocCoordinate)))

        #expect(journey.destination.isDetached)
        #expect(journey.destination.placeID == nil)
        #expect(journey.destination.coordinate == adHocCoordinate)

        let reloaded = try #require(try repository.savedJourney(id: journey.id))
        #expect(reloaded.destination.isDetached)
        #expect(reloaded.destination.name == "Aeropuerto de Peinador")
    }

    @Test("Deleting a journey removes only that row")
    func deleteJourneyRemovesOneRow() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let home = try repository.createSavedPlace(name: "Casa", symbolName: "house.fill", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        let work = try repository.createSavedPlace(name: "Trabajo", symbolName: "briefcase.fill", anchor: .coordinate(.init(latitude: 2, longitude: 2)))
        let gym = try repository.createSavedPlace(name: "Gimnasio", symbolName: "figure.run", anchor: .coordinate(.init(latitude: 3, longitude: 3)))
        let j1 = try repository.createSavedJourney(customLabel: nil, origin: .savedPlace(home), destination: .savedPlace(work))
        let j2 = try repository.createSavedJourney(customLabel: nil, origin: .savedPlace(home), destination: .savedPlace(gym))

        try repository.deleteSavedJourney(id: j1.id)
        #expect(try repository.savedJourneys().map(\.id) == [j2.id])
    }

    @Test("Reordering journeys persists")
    func reorderJourneysPersists() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let home = try repository.createSavedPlace(name: "Casa", symbolName: "house.fill", anchor: .coordinate(.init(latitude: 1, longitude: 1)))
        let work = try repository.createSavedPlace(name: "Trabajo", symbolName: "briefcase.fill", anchor: .coordinate(.init(latitude: 2, longitude: 2)))
        let gym = try repository.createSavedPlace(name: "Gimnasio", symbolName: "figure.run", anchor: .coordinate(.init(latitude: 3, longitude: 3)))
        let j1 = try repository.createSavedJourney(customLabel: nil, origin: .savedPlace(home), destination: .savedPlace(work))
        let j2 = try repository.createSavedJourney(customLabel: nil, origin: .savedPlace(home), destination: .savedPlace(gym))

        try repository.reorderSavedJourneys([j2.id, j1.id])
        #expect(try repository.savedJourneys().map(\.id) == [j2.id, j1.id])
    }

    // MARK: - Fixture variants

    /// `Fixture.stops` with stop 3493's `stop_name` changed, everything else identical.
    /// Used to prove a saved place resolves the live `Stop` on every read rather than a
    /// persisted blob.
    private static func fixtureRenamingStop3493(to newName: String) -> GTFSInMemory {
        let renamedStops = Fixture.stops.replacingOccurrences(
            of: "Praza de América  1", with: newName)
        return GTFSInMemory(texts: [
            "agency.txt": Fixture.agency,
            "stops.txt": renamedStops,
            "routes.txt": Fixture.routes,
            "trips.txt": Fixture.trips,
            "stop_times.txt": Fixture.stopTimes,
            "calendar.txt": Fixture.calendar,
            "calendar_dates.txt": Fixture.calendarDates,
            "shapes.txt": Fixture.shapes,
        ])
    }

    /// A structurally valid variant of the fixture with stop 3493 (and the two stop_time
    /// rows that reference it) removed entirely, simulating what a weekly GTFS refresh can
    /// legitimately do: a stop dropped from the published feed.
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
