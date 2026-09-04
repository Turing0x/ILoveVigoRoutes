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
}
