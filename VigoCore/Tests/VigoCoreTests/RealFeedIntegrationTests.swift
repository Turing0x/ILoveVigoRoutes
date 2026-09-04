import Testing
import Foundation
@testable import VigoCore

/// End-to-end checks against the actual published Vitrasa archive.
///
/// Skipped unless `VIGO_GTFS_ZIP` points at a downloaded `gtfs_vigo.zip`, so the suite
/// stays runnable offline and the 16 MB archive never enters the repository:
///
///     VIGO_GTFS_ZIP=/path/to/gtfs_vigo.zip swift test
///
/// The expectations here are deliberately shape-based rather than exact counts, because
/// the feed is regenerated weekly and exact numbers would rot within days.
@Suite("Real feed integration", .enabled(if: ProcessInfo.processInfo.environment["VIGO_GTFS_ZIP"] != nil))
struct RealFeedIntegrationTests {

    private func archiveData() throws -> Data {
        let path = try #require(ProcessInfo.processInfo.environment["VIGO_GTFS_ZIP"])
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func parsed() throws -> GTFSParseResult {
        try GTFSParser().parse(from: try GTFSZipProvider(data: try archiveData()))
    }

    @Test("Reads every expected file straight out of the published archive")
    func readsArchive() throws {
        let archive = try ZipArchive(data: try archiveData())
        for name in ["agency.txt", "stops.txt", "routes.txt", "trips.txt",
                     "stop_times.txt", "calendar.txt", "calendar_dates.txt", "shapes.txt"] {
            #expect(archive.contains(name), "\(name) missing from the archive")
            let data = try #require(try archive.extract(name), "\(name) failed to extract")
            #expect(!data.isEmpty)
        }
    }

    @Test("Parses the real feed at a plausible scale")
    func parsesRealFeed() throws {
        let result = try parsed()
        let feed = result.feed
        // Vigo runs roughly 45 lines over ~1100 stops. Wide bounds catch a feed that has
        // collapsed without failing every time the network is retimetabled.
        #expect(feed.stops.count > 900 && feed.stops.count < 2000, "got \(feed.stops.count) stops")
        #expect(feed.routes.count > 30 && feed.routes.count < 200, "got \(feed.routes.count) routes")
        #expect(feed.trips.count > 1000, "got \(feed.trips.count) trips")
        #expect(feed.stopTimes.count > 50_000, "got \(feed.stopTimes.count) stop times")
        #expect(!feed.shapePoints.isEmpty, "shapes.txt should carry the line geometry")
        #expect(feed.agencies.first?.timeZone == "Europe/Madrid")
    }

    @Test("The published feed passes referential integrity")
    func realFeedIsValid() throws {
        let report = GTFSValidator().validate(try parsed().feed)
        #expect(report.isImportable, "blocking findings: \(report.blocking.map(\.description))")
    }

    /// The single mapping the whole realtime path depends on. If the publisher ever
    /// changes the stop_code scheme, this is where it should be caught.
    @Test("Every stop yields a realtime code derived from stop_code")
    func stopCodeMapping() throws {
        let feed = try parsed().feed
        let withoutCode = feed.stops.filter { $0.vitrasaCode == nil }
        #expect(withoutCode.isEmpty, "stops with no derivable realtime code: \(withoutCode.prefix(5).map(\.id))")
        // The two identifier spaces must stay disjoint in practice, or a mix-up would
        // go unnoticed.
        let collisions = feed.stops.filter { $0.vitrasaCode?.value == Int($0.id.rawValue) }
        #expect(collisions.isEmpty, "stop_id and stop_code collided for \(collisions.prefix(5).map(\.id))")
    }

    @Test("Late-night trips survive parsing")
    func pastMidnightTimes() throws {
        let feed = try parsed().feed
        let late = feed.stopTimes.filter(\.departure.rollsPastMidnight)
        #expect(!late.isEmpty, "the feed is known to contain times past 24:00:00")
        let latest = try #require(feed.stopTimes.map(\.departure).max())
        #expect(latest.secondsSinceServiceDayStart > 86_400)
    }

    @Test("Imports and queries the real feed")
    func importsRealFeed() throws {
        let result = try parsed()
        let db = try AppDatabase.inMemory()
        let summary = try GTFSImporter(database: db).import(feed: result.feed,
                                                           parseWarnings: result.warnings)
        #expect(summary.stops == result.feed.stops.count)
        #expect(summary.routesWithTrips < summary.routes, "the feed carries routes with no trips")

        let repository = TransitRepository(database: db)

        // Praza de América 1 — stop_id 3493, stop_code P006930, realtime id 6930.
        if let stop = try repository.stop(id: StopID("3493")) {
            #expect(stop.vitrasaCode == VitrasaStopCode(6930))
            #expect(stop.name.contains("América"), "accents must survive the round trip: got \(stop.name)")
        }

        #expect(!(try repository.searchStops("america").isEmpty))
        #expect(!(try repository.searchStops("6930").isEmpty))

        // Praza de América, in the middle of the city: there must be stops around it.
        let nearby = try repository.nearbyStops(latitude: 42.2209, longitude: -8.7328, radiusMetres: 500)
        #expect(!nearby.isEmpty)
        #expect(nearby.allSatisfy { $0.distanceMetres <= 500 })
    }

    /// Search has to stay under 100 ms. Measured over the real 1149-stop table.
    @Test("Name search stays well under the 100 ms budget")
    func searchPerformance() throws {
        let result = try parsed()
        let db = try AppDatabase.inMemory()
        _ = try GTFSImporter(database: db).import(feed: result.feed)
        let repository = TransitRepository(database: db)

        _ = try repository.searchStops("warmup")
        let queries = ["america", "urzaiz", "gran via", "coru", "praza", "6930", "hospital"]
        let started = Date()
        for q in queries { _ = try repository.searchStops(q) }
        let perQuery = Date().timeIntervalSince(started) / Double(queries.count)
        #expect(perQuery < 0.100, "average search took \(Int(perQuery * 1000)) ms")
    }

    @Test("Reports the feed's service window")
    func serviceWindow() throws {
        let feed = try parsed().feed
        let window = try #require(feed.serviceWindow)
        #expect(window.lowerBound <= window.upperBound)
        let distinctDates = Set(feed.calendarDates.map(\.date)).count
        // Documented as a seven-day rolling window. If this ever widens, the refresh
        // strategy can be relaxed — and that is worth noticing.
        #expect(distinctDates >= 1)
        print("""
              real feed: window \(window.lowerBound)–\(window.upperBound), \
              \(distinctDates) distinct dates
              """)
    }
}

/// Timing measurements over the real archive, printed rather than asserted except where
/// the brief sets an explicit budget. Run with `-c release`; a debug build is several
/// times slower and would give a misleading picture.
@Suite("Real feed timings", .enabled(if: ProcessInfo.processInfo.environment["VIGO_GTFS_ZIP"] != nil),
       .serialized)
struct RealFeedTimingTests {

    @Test("Measures the whole import pipeline")
    func importTimings() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VIGO_GTFS_ZIP"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        func measure<T>(_ label: String, _ block: () throws -> T) rethrows -> (T, TimeInterval) {
            let start = Date()
            let value = try block()
            let elapsed = Date().timeIntervalSince(start)
            print(String(format: "  %-24@ %7.2f s", label as NSString, elapsed))
            return (value, elapsed)
        }

        print("archive \(data.count) bytes")
        let (provider, unzipTime) = try measure("unzip + CRC") { try GTFSZipProvider(data: data) }
        let (parsed, parseTime) = try measure("parse") { try GTFSParser().parse(from: provider) }
        let (_, validateTime) = measure("validate") { GTFSValidator().validate(parsed.feed) }

        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vigo-timing-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try AppDatabase.onDisk(at: dbURL)
        let (summary, importTime) = try measure("import to sqlite") {
            try GTFSImporter(database: db).import(feed: parsed.feed, parseWarnings: parsed.warnings)
        }

        let total = unzipTime + parseTime + validateTime + importTime
        let size = (try FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int) ?? 0
        print("""
          total \(String(format: "%.2f", total)) s, sqlite \(size / 1_000_000) MB
          stops \(summary.stops), routes \(summary.routes) (\(summary.routesWithTrips) with trips), \
        trips \(summary.trips), stopTimes \(summary.stopTimes), shapes \(summary.shapePoints)
          window \(summary.serviceWindow.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "none")
          parse warnings: \(summary.warnings.count)
        """)
        for advisory in summary.advisories { print("  advisory: \(advisory)") }

        let repository = TransitRepository(database: db)

        _ = try repository.searchStops("warm")
        let searchStart = Date()
        let queries = ["america", "urzaiz", "gran via", "coru", "praza", "6930", "hospital", "samil"]
        for q in queries { _ = try repository.searchStops(q) }
        let perSearch = Date().timeIntervalSince(searchStart) / Double(queries.count)
        print(String(format: "  search        %6.1f ms", perSearch * 1000))

        let nearbyStart = Date()
        let nearby = try repository.nearbyStops(latitude: 42.2209, longitude: -8.7328, radiusMetres: 800)
        print(String(format: "  nearby(800 m) %6.1f ms -> %d stops",
                     Date().timeIntervalSince(nearbyStart) * 1000, nearby.count))

        let departuresStart = Date()
        let departures = try repository.scheduledDepartures(stopID: StopID("3493"), from: Date())
        print(String(format: "  departures    %6.1f ms -> %d rows",
                     Date().timeIntervalSince(departuresStart) * 1000, departures.count))

        // The brief's only hard timing budget for Fase 1.
        #expect(perSearch < 0.100, "search must stay under 100 ms")
    }
}
