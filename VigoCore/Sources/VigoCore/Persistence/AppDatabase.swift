import Foundation
import GRDB

/// Owns the SQLite connection and the schema.
///
/// Static GTFS data is bulk-imported, read-only afterwards, and cheap to throw away and
/// rebuild — which is what makes SQLite the right fit and what makes the importer able to
/// be idempotent by simply clearing the tables first.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// On-disk database in Application Support.
    public static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        // The GTFS import writes ~280k rows in one transaction; a generous busy timeout
        // keeps a concurrent reader from failing while that lands.
        config.busyMode = .timeout(10)
        config.maximumReaderCount = 4
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(pool)
    }

    /// In-memory database, for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "stop") { t in
                t.primaryKey("id", .text)
                t.column("gtfsStopCode", .text).notNull()
                t.column("vitrasaCode", .integer)          // null: no live arrivals possible
                t.column("name", .text).notNull()
                t.column("searchName", .text).notNull()
                t.column("latitude", .double).notNull()
                t.column("longitude", .double).notNull()
                t.column("wheelchairBoarding", .integer)
            }
            try db.create(index: "stop_searchName", on: "stop", columns: ["searchName"])
            try db.create(index: "stop_vitrasaCode", on: "stop", columns: ["vitrasaCode"])
            // Bounding-box prefilter for the nearby screen.
            try db.create(index: "stop_lat_lon", on: "stop", columns: ["latitude", "longitude"])

            try db.create(table: "route") { t in
                t.primaryKey("id", .text)
                t.column("shortName", .text).notNull()
                t.column("longName", .text).notNull()
                t.column("routeType", .integer).notNull()
                t.column("colorHex", .text)
                t.column("textColorHex", .text)
            }

            try db.create(table: "trip") { t in
                t.primaryKey("id", .text)
                t.column("routeID", .text).notNull().indexed()
                t.column("serviceID", .text).notNull().indexed()
                t.column("headsign", .text)
                t.column("directionID", .integer)
                t.column("shapeID", .text).indexed()
            }

            try db.create(table: "stopTime") { t in
                t.column("tripID", .text).notNull()
                t.column("stopID", .text).notNull()
                t.column("stopSequence", .integer).notNull()
                t.column("arrival", .integer).notNull()     // seconds since service day start
                t.column("departure", .integer).notNull()
                t.primaryKey(["tripID", "stopSequence"])
            }
            // The departures-at-a-stop query is the app's hot path.
            try db.create(index: "stopTime_stop_departure", on: "stopTime",
                          columns: ["stopID", "departure"])

            try db.create(table: "calendarEntry") { t in
                t.primaryKey("serviceID", .text)
                for day in ["monday", "tuesday", "wednesday", "thursday",
                            "friday", "saturday", "sunday"] {
                    t.column(day, .boolean).notNull().defaults(to: false)
                }
                t.column("startDate", .integer).notNull()
                t.column("endDate", .integer).notNull()
            }

            try db.create(table: "calendarDate") { t in
                t.column("serviceID", .text).notNull()
                t.column("date", .integer).notNull()
                t.column("exception", .integer).notNull()
                t.primaryKey(["serviceID", "date"])
            }
            try db.create(index: "calendarDate_date", on: "calendarDate", columns: ["date"])

            try db.create(table: "shapePoint") { t in
                t.column("shapeID", .text).notNull()
                t.column("sequence", .integer).notNull()
                t.column("latitude", .double).notNull()
                t.column("longitude", .double).notNull()
                t.primaryKey(["shapeID", "sequence"])
            }

            try db.create(table: "stopRoute") { t in
                t.column("stopID", .text).notNull()
                t.column("routeID", .text).notNull()
                t.primaryKey(["stopID", "routeID"])
            }
            try db.create(index: "stopRoute_routeID", on: "stopRoute", columns: ["routeID"])

            try db.create(table: "feedMetadata") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }

            // User data. Deliberately in the same file but never cleared by the importer.
            try db.create(table: "favouriteStop") { t in
                t.primaryKey("stopID", .text)
                t.column("addedAt", .datetime).notNull()
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "cachedArrivals") { t in
                t.primaryKey("vitrasaCode", .integer)
                t.column("fetchedAt", .datetime).notNull()
                t.column("payload", .blob).notNull()
            }
        }

        return migrator
    }
}

/// Keys used in `feedMetadata`.
public enum FeedMetadataKey {
    public static let etag = "gtfs.etag"
    public static let lastModified = "gtfs.lastModified"
    public static let importedAt = "gtfs.importedAt"
    public static let windowStart = "gtfs.windowStart"
    public static let windowEnd = "gtfs.windowEnd"
    public static let sourceURL = "gtfs.sourceURL"
    public static let advisories = "gtfs.advisories"
}
