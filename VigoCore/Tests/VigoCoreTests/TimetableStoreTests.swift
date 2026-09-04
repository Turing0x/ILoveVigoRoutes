import Testing
import Foundation
@testable import VigoCore

@Suite("TimetableStore")
struct TimetableStoreTests {

    /// Direct SQL, bypassing `GTFSImporter` entirely, so `feedMetadata.importedAt` — the
    /// cache fingerprint — is untouched. Any behaviour difference this produces can only
    /// come from the cache, never from a genuine re-import.
    private static func retimeFirstStop(_ database: AppDatabase, tripID: String, addSeconds: Int) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE stopTime SET departure = departure + ?, arrival = arrival + ?
                WHERE tripID = ? AND stopSequence = 1
                """, arguments: [addSeconds, addSeconds, tripID])
        }
    }

    @Test("A second request for the same day and feed is served from the cache")
    func cacheHit() async throws {
        let database = try PlannerFixture.networkDatabase()
        let repository = TransitRepository(database: database)
        let store = TimetableStore(repository: repository)

        let first = try await store.timetable(anchor: PlannerFixture.anchor)
        try Self.retimeFirstStop(database, tripID: "T1_0800", addSeconds: 999)
        let second = try await store.timetable(anchor: PlannerFixture.anchor)

        #expect(first.tripDeparture == second.tripDeparture,
                "the DB changed but the fingerprint (importedAt) did not, so the cached snapshot must be reused")
    }

    @Test("A new import changes the fingerprint and forces a rebuild")
    func fingerprintChangeRebuilds() async throws {
        let database = try PlannerFixture.networkDatabase()
        let repository = TransitRepository(database: database)
        let store = TimetableStore(repository: repository)

        let first = try await store.timetable(anchor: PlannerFixture.anchor)
        try Self.retimeFirstStop(database, tripID: "T1_0800", addSeconds: 999)
        // A real re-import, unlike the raw SQL above, is what actually changes
        // `feedMetadata.importedAt` and should invalidate the snapshot built before it.
        let parsed = try GTFSParser().parse(from: PlannerFixture.networkProvider)
        _ = try GTFSImporter(database: database).import(
            feed: parsed.feed, parseWarnings: parsed.warnings,
            importedAt: Fixture.importedAt.addingTimeInterval(3_600))
        try Self.retimeFirstStop(database, tripID: "T1_0800", addSeconds: 999)
        let second = try await store.timetable(anchor: PlannerFixture.anchor)

        #expect(first.feedFingerprint != second.feedFingerprint)
        #expect(first.tripDeparture != second.tripDeparture,
                "the re-import's own effects, plus the SQL edit after it, must both be visible")
    }

    @Test("Requests beyond capacity evict the least recently used snapshot")
    func capacityEviction() async throws {
        let database = try PlannerFixture.networkDatabase()
        let repository = TransitRepository(database: database)
        let store = TimetableStore(repository: repository, capacity: 3)
        let calendar = repository.calendar

        let anchor0 = PlannerFixture.anchor
        let anchors = (1...3).map { anchor0.adding(days: $0, calendar: calendar)! }

        let firstBuild = try await store.timetable(anchor: anchor0)
        for anchor in anchors {
            _ = try await store.timetable(anchor: anchor) // fills the cache past anchor0
        }
        try Self.retimeFirstStop(database, tripID: "T1_0800", addSeconds: 999)
        let afterEviction = try await store.timetable(anchor: anchor0)

        #expect(firstBuild.tripDeparture != afterEviction.tripDeparture,
                "anchor0 was pushed out once three newer anchors filled the cache, so this rebuilds")
    }
}
