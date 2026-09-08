import Testing
import Foundation
import GRDB
@testable import VigoCore

/// `v2` adds `savedPlace` and `savedJourney` without touching `v1`. These tests exercise
/// the migration path itself — a database that already has user data on `v1` must come out
/// the other side with that data intact and the new tables present but empty.
@Suite("Migrations")
struct MigrationTests {

    @Test("v1 user data survives migrating to v2, and the new tables start empty")
    func v1DataSurvivesToV2() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")

        try queue.write { db in
            try FavouriteStop(stopID: StopID("3493"), addedAt: Date(), sortIndex: 0).insert(db)
            try CachedArrivalsRow(vitrasaCode: 6930, fetchedAt: Date(), payload: Data("x".utf8)).insert(db)
        }

        try AppDatabase.migrator.migrate(queue)

        let favouriteCount = try queue.read { try FavouriteStop.fetchCount($0) }
        let favouriteStopID = try queue.read { try FavouriteStop.fetchOne($0, key: "3493")?.stopID }
        let cachedCount = try queue.read { try CachedArrivalsRow.fetchCount($0) }
        let savedPlaceCount = try queue.read { try SavedPlaceRow.fetchCount($0) }
        let savedJourneyCount = try queue.read { try SavedJourneyRow.fetchCount($0) }

        #expect(favouriteCount == 1)
        #expect(favouriteStopID == StopID("3493"))
        #expect(cachedCount == 1)
        #expect(savedPlaceCount == 0)
        #expect(savedJourneyCount == 0)
    }

    /// The exact predicate a read-only caller would use to decide whether it is safe to
    /// read from a database without running the migrator itself.
    @Test("hasCompletedMigrations is false on a v1-only database, true once v2 has run")
    func hasCompletedMigrationsReflectsSchemaVersion() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        let beforeV2 = try queue.read { try AppDatabase.migrator.hasCompletedMigrations($0) }
        #expect(!beforeV2)

        try AppDatabase.migrator.migrate(queue)
        let afterV2 = try queue.read { try AppDatabase.migrator.hasCompletedMigrations($0) }
        #expect(afterV2)
    }

    @Test("A fresh database migrates straight to v2 with both new tables present")
    func freshDatabaseHasV2Tables() throws {
        let db = try AppDatabase.inMemory()
        let hasSavedPlace = try db.writer.read { try $0.tableExists("savedPlace") }
        let hasSavedJourney = try db.writer.read { try $0.tableExists("savedJourney") }
        #expect(hasSavedPlace)
        #expect(hasSavedJourney)
    }

    /// `v3` adds `activeJourney` and `recentSearch` together, on the owner's explicit call
    /// not to chain a `v4` two weeks later — `recentSearch` stays empty until Fase 12.
    @Test("v2 user data survives migrating to v3, and both new tables start empty")
    func v2DataSurvivesToV3() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2")

        try queue.write { db in
            try SavedPlaceRow(id: "p1", name: "Casa", symbolName: "house.fill", kind: "coordinate",
                              stopID: nil, latitude: 42.2, longitude: -8.7,
                              createdAt: Date(), sortIndex: 0).insert(db)
        }

        try AppDatabase.migrator.migrate(queue)

        let savedPlaceCount = try queue.read { try SavedPlaceRow.fetchCount($0) }
        let activeJourneyCount = try queue.read { try ActiveJourneyRow.fetchCount($0) }
        #expect(savedPlaceCount == 1)
        #expect(activeJourneyCount == 0)

        let hasActiveJourney = try queue.read { try $0.tableExists("activeJourney") }
        let hasRecentSearch = try queue.read { try $0.tableExists("recentSearch") }
        #expect(hasActiveJourney)
        #expect(hasRecentSearch)
    }

    @Test("A fresh database migrates straight to v3 with all tables present")
    func freshDatabaseHasV3Tables() throws {
        let db = try AppDatabase.inMemory()
        let hasActiveJourney = try db.writer.read { try $0.tableExists("activeJourney") }
        let hasRecentSearch = try db.writer.read { try $0.tableExists("recentSearch") }
        #expect(hasActiveJourney)
        #expect(hasRecentSearch)
    }

    /// `v4` adds `onboardRide`, the bus the traveller says they are on right now.
    @Test("v3 user data survives migrating to v4, and onboardRide starts empty")
    func v3DataSurvivesToV4() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3")

        try queue.write { db in
            try ActiveJourneyRow(
                id: ActiveJourneyRow.currentID, startedAt: Date(), state: "active",
                destinationName: "Biblioteca", destinationStopID: nil,
                destinationLatitude: 42.2, destinationLongitude: -8.7,
                scheduledArrival: Date(), payload: Data("{}".utf8)).insert(db)
        }

        try AppDatabase.migrator.migrate(queue)

        #expect(try queue.read { try ActiveJourneyRow.fetchCount($0) } == 1)
        #expect(try queue.read { try OnboardRideRow.fetchCount($0) } == 0)
        #expect(try queue.read { try $0.tableExists("onboardRide") })
    }

    @Test("A fresh database migrates straight to v4 with onboardRide present")
    func freshDatabaseHasV4Tables() throws {
        let db = try AppDatabase.inMemory()
        #expect(try db.writer.read { try $0.tableExists("onboardRide") })
    }
}
