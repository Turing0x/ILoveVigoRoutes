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
            // BINARY collation, not NOCASE: SQLite can only turn `LIKE 'x%'` into an index
            // *search* over a NOCASE-collated column, so every `searchStops` query still
            // *scans* this index rather than seeking into it (checked with
            // `EXPLAIN QUERY PLAN` against the real feed — H-07). Left this way on purpose:
            // measured against that same feed, every query costs comfortably under a
            // millisecond regardless (worst case ~2 ms, a single common letter's `LIKE
            // '%a%'` tier, which no index — NOCASE or not — could speed up, since a leading
            // wildcard can never use one). A collation migration would only help the
            // already-cheap prefix tier, so it stays a documentation note rather than a `v4`.
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

        migrator.registerMigration("v2") { db in
            // More user data, in the same file and equally untouched by the importer.
            try db.create(table: "savedPlace") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("symbolName", .text).notNull()
                t.column("kind", .text).notNull()          // "stop" | "coordinate"
                // Deliberately NOT a foreign key to `stop`: the importer deletes every row
                // of that table on each refresh, so an FK would either cascade the user's
                // places away or block the import outright. The reference is resolved at
                // read time, and the coordinate below is what keeps an orphaned place
                // usable when the feed no longer has this stop_id.
                t.column("stopID", .text)
                t.column("latitude", .double).notNull()
                t.column("longitude", .double).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "savedPlace_sortIndex", on: "savedPlace", columns: ["sortIndex"])

            try db.create(table: "savedJourney") { t in
                t.primaryKey("id", .text)
                t.column("customLabel", .text)             // null: derive from the endpoints
                t.column("createdAt", .datetime).notNull()
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                for end in ["origin", "destination"] {
                    // Live link, nulled when the place is deleted so the journey survives
                    // (see `deleteSavedPlace`, which also nulls this explicitly in the same
                    // transaction — correctness does not depend on `onDelete` alone).
                    t.column("\(end)PlaceID", .text)
                        .references("savedPlace", column: "id", onDelete: .setNull)
                    t.column("\(end)Name", .text).notNull()
                    t.column("\(end)SymbolName", .text).notNull()
                    t.column("\(end)Kind", .text).notNull()
                    t.column("\(end)StopID", .text)
                    t.column("\(end)Latitude", .double).notNull()
                    t.column("\(end)Longitude", .double).notNull()
                }
            }
            try db.create(index: "savedJourney_sortIndex", on: "savedJourney", columns: ["sortIndex"])
            try db.create(index: "savedJourney_originPlaceID", on: "savedJourney", columns: ["originPlaceID"])
            try db.create(index: "savedJourney_destinationPlaceID", on: "savedJourney",
                         columns: ["destinationPlaceID"])
        }

        migrator.registerMigration("v3") { db in
            // The active journey, and — created here in the same pass but unused until
            // Fase 12 — recent searches. Both are new user data, both untouched by the
            // importer, and both created together on the owner's explicit call not to chain
            // a `v4` two weeks later over real data.
            try db.create(table: "activeJourney") { t in
                t.primaryKey("id", .text)
                t.column("startedAt", .datetime).notNull()
                t.column("state", .text).notNull()              // "active" | "stale"
                t.column("destinationName", .text).notNull()
                // No FK to `stop`, same reasoning as `savedPlace`: the importer clears and
                // rewrites that table wholesale, and an FK would either cascade the active
                // journey away or block the import outright.
                t.column("destinationStopID", .text)
                t.column("destinationLatitude", .double).notNull()
                t.column("destinationLongitude", .double).notNull()
                t.column("scheduledArrival", .datetime).notNull()
                t.column("payload", .blob).notNull()            // JSON of ActiveJourneySnapshot
            }

            try db.create(table: "recentSearch") { t in
                t.primaryKey("dedupKey", .text)
                t.column("name", .text).notNull()
                t.column("subtitle", .text)
                t.column("symbolName", .text).notNull()
                t.column("originKind", .text).notNull()         // "stop" | "address" | "poi" | "pin"
                t.column("stopID", .text)
                t.column("latitude", .double).notNull()
                t.column("longitude", .double).notNull()
                t.column("lastUsedAt", .datetime).notNull()
            }
            try db.create(index: "recentSearch_lastUsedAt", on: "recentSearch", columns: ["lastUsedAt"])
        }

        migrator.registerMigration("v4") { db in
            // The bus the traveller says they are riding right now. A separate table from
            // `activeJourney` because it is a separate thing: that one is a plan being
            // followed and is never replanned, this one is a vehicle with no destination
            // attached yet, whose whole point is that a destination may turn up mid-ride.
            // The app keeps at most one of the two, which is a rule about behaviour, not a
            // constraint the schema can express.
            try db.create(table: "onboardRide") { t in
                t.primaryKey("id", .text)                       // constant "current"
                t.column("declaredAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("routeShortName", .text).notNull()
                t.column("normalizedLine", .text).notNull()
                t.column("headsign", .text)
                // No FK to `trip` or `stop`, same reasoning as `savedPlace` and
                // `activeJourney`: the importer clears and rewrites both wholesale.
                t.column("tripID", .text)
                t.column("currentStopID", .text)
                t.column("currentStopName", .text).notNull()
                t.column("currentLatitude", .double).notNull()
                t.column("currentLongitude", .double).notNull()
                t.column("currentPosition", .integer).notNull()
                t.column("observedDelaySeconds", .integer).notNull().defaults(to: 0)
                t.column("payload", .blob).notNull()            // JSON of OnboardRide
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
    /// Last time the server was asked, whether or not anything changed.
    public static let lastCheckedAt = "gtfs.lastCheckedAt"
    public static let windowStart = "gtfs.windowStart"
    public static let windowEnd = "gtfs.windowEnd"
    public static let sourceURL = "gtfs.sourceURL"
    public static let advisories = "gtfs.advisories"
}
