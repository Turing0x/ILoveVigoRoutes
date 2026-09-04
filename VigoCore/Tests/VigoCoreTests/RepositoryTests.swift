import Testing
import Foundation
@testable import VigoCore

@Suite("Import and queries")
struct RepositoryTests {

    @Test("Imports the fixture feed")
    func imports() throws {
        let db = try AppDatabase.inMemory()
        let parsed = try GTFSParser().parse(from: Fixture.provider)
        let summary = try GTFSImporter(database: db).import(feed: parsed.feed)
        #expect(summary.stops == 4)
        #expect(summary.trips == 3)
        #expect(summary.stopTimes == 6)
        #expect(summary.routesWithTrips == 3)
        #expect(summary.serviceWindow?.lowerBound == ServiceDate(yyyymmdd: 20_260_904))
    }

    /// Re-importing must leave the database identical. A refresh happens weekly, so an
    /// importer that appended would double every departure after seven days.
    @Test("Re-importing the same feed does not duplicate anything")
    func idempotent() throws {
        let db = try AppDatabase.inMemory()
        let parsed = try GTFSParser().parse(from: Fixture.provider)
        let importer = GTFSImporter(database: db)
        _ = try importer.import(feed: parsed.feed)
        let repository = TransitRepository(database: db)
        let firstCount = try repository.allStops().count
        let firstDepartures = try repository.scheduledDepartures(
            stopID: StopID("3493"), from: Fixture.date(2026, 9, 4, 7, 0)).count

        _ = try importer.import(feed: parsed.feed)
        #expect(try repository.allStops().count == firstCount)
        #expect(try repository.scheduledDepartures(
            stopID: StopID("3493"), from: Fixture.date(2026, 9, 4, 7, 0)).count == firstDepartures)
    }

    @Test("Import preserves favourites")
    func importKeepsUserData() throws {
        let db = try Fixture.importedDatabase()
        let repository = TransitRepository(database: db)
        try repository.setFavourite(StopID("3493"), true)
        let parsed = try GTFSParser().parse(from: Fixture.provider)
        _ = try GTFSImporter(database: db).import(feed: parsed.feed)
        #expect(try repository.favouriteStopIDs() == [StopID("3493")])
    }

    @Test("A feed that fails validation is rejected and leaves the old data alone")
    func rejectsBadFeed() throws {
        let db = try Fixture.importedDatabase()
        let repository = TransitRepository(database: db)
        var broken = try Fixture.parsedFeed()
        broken.stopTimes.append(StopTime(tripID: TripID("GHOST"), stopID: StopID("3493"),
                                         stopSequence: 9, arrival: ServiceTime(seconds: 1),
                                         departure: ServiceTime(seconds: 1)))
        #expect(throws: ImportError.self) {
            _ = try GTFSImporter(database: db).import(feed: broken)
        }
        #expect(try repository.allStops().count == 4, "the previous feed must survive")
    }

    @Test("Finds ordinary departures")
    func departures() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let departures = try repository.scheduledDepartures(
            stopID: StopID("3493"), from: Fixture.date(2026, 9, 4, 7, 0))
        #expect(departures.contains { $0.routeShortName == "C1" && $0.departure.clockDescription == "08:00" })
    }

    /// The night trip departs at 25:10:00 on Friday's service day, i.e. 01:10 on Saturday.
    /// Finding it at 01:00 on Saturday requires querying Friday's calendar with an offset
    /// past 86400. An implementation that only ever looks at "today" misses it entirely.
    @Test("Finds a departure that belongs to the previous service day")
    func pastMidnightDeparture() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let departures = try repository.scheduledDepartures(
            stopID: StopID("3493"), from: Fixture.date(2026, 9, 5, 1, 0))
        let night = try #require(departures.first { $0.routeShortName == "N4" })
        #expect(night.serviceDate == ServiceDate(yyyymmdd: 20_260_904), "belongs to Friday's service day")
        #expect(night.departure.clockDescription == "01:10")
        #expect(night.absoluteDate == Fixture.date(2026, 9, 5, 1, 10))
    }

    @Test("Departures are ordered by absolute time")
    func ordering() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let departures = try repository.scheduledDepartures(
            stopID: StopID("3493"), from: Fixture.date(2026, 9, 4, 0, 0), horizon: 36 * 3600)
        #expect(departures == departures.sorted { $0.absoluteDate < $1.absoluteDate })
    }

    @Test("Resolves service by weekday", arguments: [
        (20_260_904, 2), (20_260_905, 2), (20_260_906, 1), (20_260_907, 0),
    ])
    func activeServices(date: Int, expectedTrips: Int) throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let services = try repository.activeServiceIDs(on: ServiceDate(yyyymmdd: date))
        // Two trips share the weekday service, one runs on the Sunday service.
        let expectedServices = expectedTrips == 0 ? 0 : 1
        #expect(services.count == expectedServices)
    }

    @Test("Searches by folded name")
    func searchByName() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        #expect(try repository.searchStops("america").count == 2, "accent-insensitive")
        #expect(try repository.searchStops("AMÉRICA").count == 2, "case- and accent-insensitive")
        #expect(try repository.searchStops("urzaiz").first?.id == StopID("3885"))
        #expect(try repository.searchStops("").isEmpty)
    }

    /// The number printed at the stop is the public code, so typing it must work.
    @Test("Searches by the public stop number")
    func searchByNumber() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let hits = try repository.searchStops("6930")
        #expect(hits.first?.id == StopID("3493"))
    }

    @Test("Finds nearby stops ordered by distance")
    func nearby() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let nearby = try repository.nearbyStops(
            latitude: 42.2209973130163, longitude: -8.73283517659561, radiusMetres: 500)
        #expect(nearby.first?.stop.id == StopID("3493"))
        #expect(nearby.first?.distanceMetres ?? 1 < 1)
        #expect(nearby.map(\.distanceMetres) == nearby.map(\.distanceMetres).sorted())
    }

    @Test("A tight radius excludes distant stops")
    func nearbyRadius() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let nearby = try repository.nearbyStops(
            latitude: 42.2209973130163, longitude: -8.73283517659561, radiusMetres: 50)
        #expect(!nearby.contains { $0.stop.id == StopID("3885") }, "Urzáiz is ~1.4 km away")
    }

    /// Ghost routes must never reach the UI.
    @Test("Only routes with trips are listed")
    func routesWithService() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        let names = try repository.routesWithService().map(\.shortName)
        #expect(names.contains("C1"))
        #expect(!names.contains("9B."), "a route with no trips is a ghost line")
    }

    @Test("Lists the lines serving a stop")
    func linesAtStop() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        #expect(try Set(repository.routeShortNames(stopID: StopID("3493"))) == ["C1", "N4"])
    }

    @Test("Orders line labels numerically then alphabetically")
    func lineOrdering() {
        let sorted = ["A", "15B", "C1", "2", "10", "N4"].sorted(by: TransitRepository.lineNameOrdering)
        #expect(sorted == ["2", "10", "15B", "A", "C1", "N4"])
    }

    @Test("Toggles and orders favourites")
    func favourites() throws {
        let repository = TransitRepository(database: try Fixture.importedDatabase())
        try repository.setFavourite(StopID("3493"), true)
        try repository.setFavourite(StopID("3885"), true)
        #expect(try repository.favouriteStopIDs() == [StopID("3493"), StopID("3885")])
        #expect(try repository.isFavourite(StopID("3493")))
        try repository.reorderFavourites([StopID("3885"), StopID("3493")])
        #expect(try repository.favouriteStopIDs() == [StopID("3885"), StopID("3493")])
        try repository.setFavourite(StopID("3493"), false)
        #expect(try repository.favouriteStopIDs() == [StopID("3885")])
    }

    @Test("Records the feed window and reports expiry")
    func feedStatus() throws {
        let db = try AppDatabase.inMemory()
        let parsed = try GTFSParser().parse(from: Fixture.provider)
        _ = try GTFSImporter(database: db).import(
            feed: parsed.feed,
            provenance: FeedProvenance(etag: "\"abc\"", lastModified: "Mon, 31 Aug 2026 04:31:47 GMT",
                                       sourceURL: URL(string: "https://datos.vigo.org/data/transporte/gtfs_vigo.zip")))
        let status = try TransitRepository(database: db).feedStatus()
        #expect(status.hasData)
        #expect(status.etag == "\"abc\"")
        #expect(status.covers(ServiceDate(yyyymmdd: 20_260_904)))
        #expect(!status.covers(ServiceDate(yyyymmdd: 20_260_910)))
        #expect(status.isExpired(on: ServiceDate(yyyymmdd: 20_260_910)))
        #expect(status.daysRemaining(from: ServiceDate(yyyymmdd: 20_260_904), calendar: Fixture.madrid) == 2)
    }
}
