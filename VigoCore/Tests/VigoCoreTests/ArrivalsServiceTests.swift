import Testing
import Foundation
@testable import VigoCore

@Suite("Arrivals service provenance")
struct ArrivalsServiceTests {

    private func makeStop(_ repository: TransitRepository) throws -> Stop {
        try #require(try repository.stop(id: StopID("3493")))
    }

    @Test("A successful fetch is labelled as realtime")
    func realtime() async throws {
        let db = try Fixture.importedDatabase()
        let repository = TransitRepository(database: db)
        let stub = StubRealtimeProvider { code in
            ArrivalsSnapshot(stopCode: code, stopName: "X", latitude: nil, longitude: nil,
                             arrivals: [Arrival(rawLine: "C1", destination: "A*", minutes: 4, metres: 300)],
                             fetchedAt: Date())
        }
        let service = ArrivalsService(realtime: stub, repository: repository,
                                      cache: ArrivalsCache(database: db))
        let result = await service.arrivals(for: try makeStop(repository))
        #expect(result.source.isRealtime)
        #expect(result.arrivals.count == 1)
    }

    /// When realtime dies the app must say so and fall back to the last good answer,
    /// clearly marked. Silently showing stale minutes as live is the failure mode this
    /// whole design exists to prevent.
    @Test("A failure falls back to cache and says so")
    func cacheFallback() async throws {
        let db = try Fixture.importedDatabase()
        let repository = TransitRepository(database: db)
        let cache = ArrivalsCache(database: db)
        try cache.store(ArrivalsSnapshot(
            stopCode: VitrasaStopCode(6930), stopName: "Praza de América  1",
            latitude: nil, longitude: nil,
            arrivals: [Arrival(rawLine: "C1", destination: "A*", minutes: 7, metres: -1)],
            fetchedAt: Date().addingTimeInterval(-120)))

        let failing = StubRealtimeProvider { _ in throw RealtimeError.transport("offline") }
        let service = ArrivalsService(realtime: failing, repository: repository, cache: cache)
        let result = await service.arrivals(for: try makeStop(repository))

        guard case .cache(_, let failure) = result.source else {
            Issue.record("expected a cache fallback, got \(result.source)"); return
        }
        #expect(failure.contains("offline"))
        #expect(result.arrivals.first?.minutes == 7)
        #expect(!result.source.isRealtime, "cached data must never be presented as live")
    }

    @Test("A stale cache is not used")
    func staleCacheIgnored() async throws {
        let db = try Fixture.importedDatabase()
        let repository = TransitRepository(database: db)
        let cache = ArrivalsCache(database: db)
        try cache.store(ArrivalsSnapshot(
            stopCode: VitrasaStopCode(6930), stopName: "X", latitude: nil, longitude: nil,
            arrivals: [Arrival(rawLine: "C1", destination: "A*", minutes: 7, metres: -1)],
            fetchedAt: Date().addingTimeInterval(-3600)))
        let failing = StubRealtimeProvider { _ in throw RealtimeError.transport("offline") }
        let service = ArrivalsService(realtime: failing, repository: repository,
                                      cache: cache, maximumCacheAge: 300)
        let result = await service.arrivals(for: try makeStop(repository))
        guard case .unavailable = result.source else {
            Issue.record("expected unavailable, got \(result.source)"); return
        }
        #expect(result.arrivals.isEmpty)
    }

    /// Even with no realtime at all, the timetable must still be there — labelled.
    @Test("The timetable is always computed as a fallback")
    func timetableAlwaysPresent() async throws {
        let db = try Fixture.importedDatabase()
        let repository = TransitRepository(database: db)
        let failing = StubRealtimeProvider { _ in throw RealtimeError.transport("offline") }
        let service = ArrivalsService(realtime: failing, repository: repository,
                                      cache: ArrivalsCache(database: db))
        let result = await service.arrivals(for: try makeStop(repository),
                                            now: Fixture.date(2026, 9, 4, 7, 0))
        #expect(!result.scheduled.isEmpty)
        #expect(result.scheduled.contains { $0.routeShortName == "C1" })
    }

    /// "No departures" and "I have no data for today" are different answers and the UI
    /// has to be able to tell them apart.
    @Test("Reports when the requested day falls outside the feed window")
    func outsideWindow() async throws {
        let db = try Fixture.importedDatabase()
        let repository = TransitRepository(database: db)
        let failing = StubRealtimeProvider { _ in throw RealtimeError.transport("offline") }
        let service = ArrivalsService(realtime: failing, repository: repository,
                                      cache: ArrivalsCache(database: db))
        let inside = await service.arrivals(for: try makeStop(repository),
                                            now: Fixture.date(2026, 9, 4, 7, 0))
        #expect(!inside.outsideFeedWindow)
        let outside = await service.arrivals(for: try makeStop(repository),
                                             now: Fixture.date(2026, 10, 1, 7, 0))
        #expect(outside.outsideFeedWindow)
    }

    @Test("A stop with no realtime code reports that, without pretending to be offline")
    func noRealtimeCode() async throws {
        let db = try Fixture.importedDatabase()
        let repository = TransitRepository(database: db)
        let stop = try #require(try repository.stop(id: StopID("9999")))
        let stub = StubRealtimeProvider { _ in Issue.record("must not reach the network"); throw RealtimeError.transport("x") }
        let service = ArrivalsService(realtime: stub, repository: repository,
                                      cache: ArrivalsCache(database: db))
        let result = await service.arrivals(for: stop)
        guard case .unavailable(let failure) = result.source else {
            Issue.record("expected unavailable, got \(result.source)"); return
        }
        #expect(failure.contains("no realtime code"))
    }

    @Test("Cached snapshots survive a round trip")
    func cacheRoundTrip() throws {
        let db = try Fixture.importedDatabase()
        let cache = ArrivalsCache(database: db)
        let original = ArrivalsSnapshot(
            stopCode: VitrasaStopCode(6930), stopName: "Praza de América  1",
            latitude: 42.22, longitude: -8.73,
            arrivals: [Arrival(rawLine: "N4", destination: "G.ESPINO*", minutes: 29, metres: -1),
                       Arrival(rawLine: "C1", destination: "PRAZA AMÉRICA*", minutes: 3, metres: 420)],
            fetchedAt: Date())
        try cache.store(original)
        let loaded = try #require(try cache.load(VitrasaStopCode(6930)))
        #expect(loaded.arrivals.count == 2)
        #expect(loaded.stopName == "Praza de América  1")
        #expect(loaded.arrivals.first { $0.rawLine == "C1" }?.confidence == .vehicleTracked(metres: 420))
        #expect(loaded.arrivals.first { $0.rawLine == "N4" }?.confidence == .operatorEstimate)
    }
}
