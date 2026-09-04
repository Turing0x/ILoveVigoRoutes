import Foundation
import GRDB

public struct ImportProgress: Sendable, Hashable {
    public enum Stage: String, Sendable {
        case downloading, unpacking, parsing, validating, writing, done
    }
    public let stage: Stage
    /// 0…1 within the whole import, or `nil` when the stage cannot report a fraction.
    public let fraction: Double?
    public init(stage: Stage, fraction: Double?) { self.stage = stage; self.fraction = fraction }
}

public struct ImportSummary: Sendable {
    public let stops: Int
    public let routes: Int
    public let routesWithTrips: Int
    public let trips: Int
    public let stopTimes: Int
    public let shapePoints: Int
    public let serviceWindow: ClosedRange<ServiceDate>?
    public let advisories: [String]
    public let warnings: [String]
    public let duration: TimeInterval
}

public enum ImportError: Error, CustomStringConvertible, Sendable {
    case validationFailed([String])
    case parse(String)

    public var description: String {
        switch self {
        case .validationFailed(let f): "feed rejected: " + f.joined(separator: "; ")
        case .parse(let m): "could not parse feed: \(m)"
        }
    }
}

/// Loads a parsed GTFS feed into SQLite.
///
/// Idempotent by construction: the whole swap happens in one transaction that first
/// clears the static tables, so importing the same feed twice leaves the database
/// identical and a failure part-way through leaves the previous feed intact. User data
/// (favourites, cached arrivals) lives in tables the importer never touches.
public struct GTFSImporter: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    /// - Parameter provenance: HTTP validators for the ZIP this feed came from, stored so
    ///   the next refresh can ask the server "has this changed?" instead of re-downloading.
    public func `import`(
        feed: GTFSFeed,
        parseWarnings: [GTFSParseWarning] = [],
        provenance: FeedProvenance? = nil,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) throws -> ImportSummary {
        let started = Date()
        progress?(ImportProgress(stage: .validating, fraction: 0.05))

        let report = GTFSValidator().validate(feed)
        guard report.isImportable else {
            throw ImportError.validationFailed(report.blocking.map(\.description))
        }

        progress?(ImportProgress(stage: .writing, fraction: 0.10))

        // Derived once, outside the transaction, to keep the write lock short.
        let tripsByID = Dictionary(feed.trips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var stopRoutePairs = Set<StopRouteRow>()
        for st in feed.stopTimes {
            if let trip = tripsByID[st.tripID] {
                stopRoutePairs.insert(StopRouteRow(stopID: st.stopID, routeID: trip.routeID))
            }
        }

        try database.writer.write { db in
            // Static tables only. favouriteStop and cachedArrivals are untouched.
            for table in ["stopRoute", "stopTime", "shapePoint", "trip",
                          "calendarDate", "calendarEntry", "route", "stop"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }

            for stop in feed.stops { try stop.insert(db) }
            for route in feed.routes { try route.insert(db) }
            for entry in feed.calendar { try CalendarRow(entry).insert(db) }
            for date in feed.calendarDates { try date.insert(db) }
            for trip in feed.trips { try trip.insert(db) }

            var written = 0
            for st in feed.stopTimes {
                try st.insert(db)
                written += 1
                if written % 20_000 == 0 {
                    let f = 0.10 + 0.55 * Double(written) / Double(max(1, feed.stopTimes.count))
                    progress?(ImportProgress(stage: .writing, fraction: f))
                }
            }

            written = 0
            for point in feed.shapePoints {
                try point.insert(db)
                written += 1
                if written % 20_000 == 0 {
                    let f = 0.65 + 0.25 * Double(written) / Double(max(1, feed.shapePoints.count))
                    progress?(ImportProgress(stage: .writing, fraction: f))
                }
            }

            for pair in stopRoutePairs { try pair.insert(db) }

            // Provenance and window, written last so a torn import cannot claim success.
            func put(_ key: String, _ value: String?) throws {
                guard let value else {
                    try db.execute(sql: "DELETE FROM feedMetadata WHERE key = ?", arguments: [key])
                    return
                }
                try MetadataRow(key: key, value: value).upsert(db)
            }
            try put(FeedMetadataKey.importedAt, ISO8601DateFormatter().string(from: Date()))
            try put(FeedMetadataKey.etag, provenance?.etag)
            try put(FeedMetadataKey.lastModified, provenance?.lastModified)
            try put(FeedMetadataKey.sourceURL, provenance?.sourceURL?.absoluteString)
            try put(FeedMetadataKey.windowStart, report.serviceWindow.map { String($0.lowerBound.yyyymmdd) })
            try put(FeedMetadataKey.windowEnd, report.serviceWindow.map { String($0.upperBound.yyyymmdd) })
            try put(FeedMetadataKey.advisories,
                    report.advisories.isEmpty ? nil : report.advisories.map(\.description).joined(separator: "\n"))
        }

        progress?(ImportProgress(stage: .done, fraction: 1.0))

        return ImportSummary(
            stops: report.stopCount,
            routes: report.routeCount,
            routesWithTrips: report.routesWithTrips,
            trips: report.tripCount,
            stopTimes: report.stopTimeCount,
            shapePoints: report.shapePointCount,
            serviceWindow: report.serviceWindow,
            advisories: report.advisories.map(\.description),
            warnings: parseWarnings.map(\.description),
            duration: Date().timeIntervalSince(started))
    }
}

/// HTTP validators for a downloaded feed, used to avoid re-downloading unchanged data.
public struct FeedProvenance: Sendable, Hashable {
    public let etag: String?
    public let lastModified: String?
    public let sourceURL: URL?
    public init(etag: String?, lastModified: String?, sourceURL: URL?) {
        self.etag = etag; self.lastModified = lastModified; self.sourceURL = sourceURL
    }
}
