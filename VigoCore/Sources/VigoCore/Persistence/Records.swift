import Foundation
import GRDB

// Domain models double as database records. Their identifier types encode as bare
// scalars (see Identifiers.swift), so every column stays flat and inspectable with
// the sqlite3 CLI.

extension Stop: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "stop"
}

extension Route: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "route"
}

extension Trip: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "trip"
}

extension StopTime: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "stopTime"
}

extension CalendarDate: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "calendarDate"
}


extension ShapePoint: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "shapePoint"
}

/// `calendar.txt` flattened into columns. The domain type carries a `[Bool]`, which
/// has no sensible single-column representation.
struct CalendarRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "calendarEntry"
    var serviceID: ServiceID
    var monday: Bool, tuesday: Bool, wednesday: Bool, thursday: Bool
    var friday: Bool, saturday: Bool, sunday: Bool
    var startDate: ServiceDate
    var endDate: ServiceDate

    init(_ e: CalendarEntry) {
        serviceID = e.serviceID
        let d = e.daysOfWeek + Array(repeating: false, count: max(0, 7 - e.daysOfWeek.count))
        monday = d[0]; tuesday = d[1]; wednesday = d[2]; thursday = d[3]
        friday = d[4]; saturday = d[5]; sunday = d[6]
        startDate = e.startDate; endDate = e.endDate
    }

    var entry: CalendarEntry {
        CalendarEntry(serviceID: serviceID,
                      daysOfWeek: [monday, tuesday, wednesday, thursday, friday, saturday, sunday],
                      startDate: startDate, endDate: endDate)
    }
}

/// Precomputed stop→route pairs.
///
/// Deriving "which lines serve this stop" from `stopTime ⋈ trip` on every row of the
/// nearby-stops list would mean a join over 135k rows per screen refresh. Materialising
/// it at import keeps that screen a single indexed read.
struct StopRouteRow: Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "stopRoute"
    var stopID: StopID
    var routeID: RouteID
}

/// Single-row-per-key store for feed provenance: ETag, Last-Modified, import time and
/// the service window. The UI needs all of these to be honest about what it is showing.
struct MetadataRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "feedMetadata"
    var key: String
    var value: String
}

public struct FavouriteStop: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "favouriteStop"
    public var stopID: StopID
    public var addedAt: Date
    public var sortIndex: Int

    public init(stopID: StopID, addedAt: Date = Date(), sortIndex: Int = 0) {
        self.stopID = stopID; self.addedAt = addedAt; self.sortIndex = sortIndex
    }
}

/// Last successful realtime response for a stop, so the app can show something after a
/// cold start with no network — clearly labelled as cached, never as live.
struct CachedArrivalsRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "cachedArrivals"
    var vitrasaCode: Int
    var fetchedAt: Date
    var payload: Data
}
