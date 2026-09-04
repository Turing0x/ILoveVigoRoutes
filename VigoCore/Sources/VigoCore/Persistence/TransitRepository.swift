import Foundation
import GRDB

/// A timetabled departure resolved to an absolute instant.
public struct ScheduledDeparture: Sendable, Hashable, Identifiable {
    public let tripID: TripID
    public let routeID: RouteID
    public let routeShortName: String
    public let routeLongName: String
    public let headsign: String?
    public let departure: ServiceTime
    public let serviceDate: ServiceDate
    /// Absolute instant, already accounting for service days that run past midnight.
    public let absoluteDate: Date

    public var id: String { "\(tripID.rawValue)#\(serviceDate.yyyymmdd)" }

    public var destination: String {
        if let h = headsign, !h.isEmpty { return h }
        return routeLongName
    }
}

public struct NearbyStop: Sendable, Hashable, Identifiable {
    public let stop: Stop
    /// Straight-line metres. The app never claims this is walking distance.
    public let distanceMetres: Double
    public let routeShortNames: [String]
    public var id: StopID { stop.id }
}

/// Everything the app knows about where its static data came from and how long it is
/// good for. Surfaced in the UI rather than kept in logs.
public struct FeedStatus: Sendable, Hashable {
    /// When the data currently in the database was imported.
    public let importedAt: Date?
    /// When the server was last asked for a newer feed, which may be more recent than
    /// `importedAt` if the answer was "nothing changed".
    public let lastCheckedAt: Date?
    public let etag: String?
    public let lastModified: String?
    public let sourceURL: URL?
    public let window: ClosedRange<ServiceDate>?
    public let advisories: [String]

    public init(importedAt: Date?, lastCheckedAt: Date?, etag: String?, lastModified: String?,
                sourceURL: URL?, window: ClosedRange<ServiceDate>?, advisories: [String]) {
        self.importedAt = importedAt; self.lastCheckedAt = lastCheckedAt
        self.etag = etag; self.lastModified = lastModified
        self.sourceURL = sourceURL; self.window = window; self.advisories = advisories
    }

    /// Nothing imported yet.
    public static let empty = FeedStatus(
        importedAt: nil, lastCheckedAt: nil, etag: nil, lastModified: nil,
        sourceURL: nil, window: nil, advisories: [])

    public var hasData: Bool { importedAt != nil }

    /// Whether the feed can answer questions about a given day at all.
    public func covers(_ date: ServiceDate) -> Bool {
        guard let window else { return false }
        return window.contains(date)
    }

    public func isExpired(on date: ServiceDate) -> Bool {
        guard let window else { return true }
        return date > window.upperBound
    }

    public func daysRemaining(from date: ServiceDate, calendar: Calendar) -> Int? {
        guard let window,
              let from = date.startOfDay(in: calendar),
              let to = window.upperBound.startOfDay(in: calendar) else { return nil }
        return calendar.dateComponents([.day], from: from, to: to).day
    }
}

/// Read access to the imported GTFS.
public struct TransitRepository: Sendable {
    let database: AppDatabase
    /// Europe/Madrid. Service days are defined in the agency's local time, and getting
    /// this wrong shifts every departure by an hour twice a year.
    public let calendar: Calendar

    public init(database: AppDatabase, timeZone: TimeZone = TimeZone(identifier: "Europe/Madrid") ?? .current) {
        self.database = database
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        self.calendar = cal
    }

    // MARK: - Feed status

    public func feedStatus() throws -> FeedStatus {
        try database.writer.read { db in
            let rows = try MetadataRow.fetchAll(db)
            var map: [String: String] = [:]
            for r in rows { map[r.key] = r.value }
            let start = map[FeedMetadataKey.windowStart].flatMap(Int.init).map(ServiceDate.init(yyyymmdd:))
            let end = map[FeedMetadataKey.windowEnd].flatMap(Int.init).map(ServiceDate.init(yyyymmdd:))
            var window: ClosedRange<ServiceDate>?
            if let start, let end, start <= end { window = start...end }
            return FeedStatus(
                importedAt: map[FeedMetadataKey.importedAt].flatMap { ISO8601DateFormatter().date(from: $0) },
                lastCheckedAt: map[FeedMetadataKey.lastCheckedAt].flatMap { ISO8601DateFormatter().date(from: $0) },
                etag: map[FeedMetadataKey.etag],
                lastModified: map[FeedMetadataKey.lastModified],
                sourceURL: map[FeedMetadataKey.sourceURL].flatMap(URL.init(string:)),
                window: window,
                advisories: map[FeedMetadataKey.advisories]?
                    .split(separator: "\n").map(String.init) ?? [])
        }
    }

    public func isEmpty() throws -> Bool {
        try database.writer.read { db in
            try Stop.fetchCount(db) == 0
        }
    }

    // MARK: - Stops

    public func stop(id: StopID) throws -> Stop? {
        try database.writer.read { db in try Stop.fetchOne(db, key: id.rawValue) }
    }

    public func stop(vitrasaCode: VitrasaStopCode) throws -> Stop? {
        try database.writer.read { db in
            try Stop.filter(sql: "vitrasaCode = ?", arguments: [vitrasaCode.value]).fetchOne(db)
        }
    }

    public func allStops() throws -> [Stop] {
        try database.writer.read { db in try Stop.fetchAll(db) }
    }

    /// Stops within `radiusMetres`, nearest first.
    ///
    /// A latitude/longitude bounding box narrows the candidates using the index, then the
    /// exact distance is computed in Swift. At 1149 stops this is comfortably instant; the
    /// box exists so it stays that way if the feed ever grows.
    public func nearbyStops(
        latitude: Double, longitude: Double,
        radiusMetres: Double = 800, limit: Int = 40
    ) throws -> [NearbyStop] {
        let latDelta = radiusMetres / 111_320.0
        let lonDelta = radiusMetres / (111_320.0 * max(0.1, cos(latitude * .pi / 180)))
        return try database.writer.read { db in
            let candidates = try Stop.filter(
                sql: "latitude BETWEEN ? AND ? AND longitude BETWEEN ? AND ?",
                arguments: [latitude - latDelta, latitude + latDelta,
                            longitude - lonDelta, longitude + lonDelta]
            ).fetchAll(db)

            let scored = candidates.compactMap { stop -> (Stop, Double)? in
                let d = Self.haversineMetres(latitude, longitude, stop.latitude, stop.longitude)
                return d <= radiusMetres ? (stop, d) : nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)

            return try scored.map { stop, distance in
                NearbyStop(stop: stop, distanceMetres: distance,
                           routeShortNames: try Self.routeShortNames(db, stopID: stop.id))
            }
        }
    }

    /// Name or stop-number search.
    ///
    /// Matching is done on the accent-folded name computed at import time, so the user can
    /// type "america" and find "Praza de América". A purely numeric query is also matched
    /// against the public stop code, which is how the numbers printed at the stop read.
    public func searchStops(_ query: String, limit: Int = 50) throws -> [Stop] {
        let folded = TextNormalization.searchFolded(query)
        guard !folded.isEmpty else { return [] }
        let digits = folded.filter(\.isNumber)
        let isNumeric = !digits.isEmpty && folded.allSatisfy { $0.isNumber || $0.isWhitespace }

        return try database.writer.read { db in
            if isNumeric, let code = Int(digits) {
                let exact = try Stop.filter(sql: "vitrasaCode = ?", arguments: [code]).fetchAll(db)
                let prefix = try Stop.filter(
                    sql: "CAST(vitrasaCode AS TEXT) LIKE ? AND vitrasaCode <> ?",
                    arguments: ["\(digits)%", code]
                ).limit(limit).fetchAll(db)
                if !exact.isEmpty || !prefix.isEmpty { return exact + prefix }
            }
            // Prefix matches first, then matches anywhere, so "coru" puts
            // "Rúa da Coruña" above a stop that merely mentions it.
            let prefixed = try Stop
                .filter(sql: "searchName LIKE ?", arguments: ["\(folded)%"])
                .order(sql: "searchName").limit(limit).fetchAll(db)
            let contained = try Stop
                .filter(sql: "searchName LIKE ? AND searchName NOT LIKE ?",
                        arguments: ["%\(folded)%", "\(folded)%"])
                .order(sql: "searchName").limit(limit).fetchAll(db)
            return Array((prefixed + contained).prefix(limit))
        }
    }

    public func routeShortNames(stopID: StopID) throws -> [String] {
        try database.writer.read { db in try Self.routeShortNames(db, stopID: stopID) }
    }

    /// Only routes that actually have trips: the feed carries 16 route rows with no
    /// service, and showing them would reproduce the "ghost lines" problem this app exists
    /// to avoid.
    private static func routeShortNames(_ db: Database, stopID: StopID) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT r.shortName
            FROM stopRoute sr
            JOIN route r ON r.id = sr.routeID
            WHERE sr.stopID = ?
              AND EXISTS (SELECT 1 FROM trip t WHERE t.routeID = r.id)
            """, arguments: [stopID.rawValue])
            .sorted(by: Self.lineNameOrdering)
    }

    /// Human ordering for line labels: numbers ascending, then lettered lines.
    public static func lineNameOrdering(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> (Int, Int, String) {
            let digits = s.prefix { $0.isNumber }
            if let n = Int(digits) { return (0, n, s) }
            return (1, 0, s)
        }
        let (ka, kb) = (key(a), key(b))
        if ka.0 != kb.0 { return ka.0 < kb.0 }
        if ka.1 != kb.1 { return ka.1 < kb.1 }
        return ka.2 < kb.2
    }

    // MARK: - Routes

    public func routesWithService() throws -> [Route] {
        try database.writer.read { db in
            try Route.filter(sql: "EXISTS (SELECT 1 FROM trip t WHERE t.routeID = route.id)")
                .fetchAll(db)
                .sorted { Self.lineNameOrdering($0.shortName, $1.shortName) }
        }
    }

    /// The trip's own row — in practice, so `JourneyDetailView` can follow `tripID` to a
    /// `shapeID` and then to the line's actual geometry, which nothing before it needed.
    public func trip(id: TripID) throws -> Trip? {
        try database.writer.read { db in try Trip.fetchOne(db, key: id.rawValue) }
    }

    public func shape(id: ShapeID) throws -> [ShapePoint] {
        try database.writer.read { db in
            try ShapePoint.filter(sql: "shapeID = ?", arguments: [id.rawValue])
                .order(sql: "sequence").fetchAll(db)
        }
    }

    // MARK: - Service calendar

    /// Service IDs running on a given day, combining `calendar.txt` weekday patterns with
    /// `calendar_dates.txt` exceptions. In this feed only the latter is populated.
    public func activeServiceIDs(on date: ServiceDate) throws -> Set<ServiceID> {
        try database.writer.read { db in try Self.activeServiceIDs(db, date, calendar) }
    }

    private static func activeServiceIDs(
        _ db: Database, _ date: ServiceDate, _ calendar: Calendar
    ) throws -> Set<ServiceID> {
        var active = Set<ServiceID>()

        if let weekday = date.gtfsWeekdayIndex(calendar: calendar) {
            let column = ["monday", "tuesday", "wednesday", "thursday",
                          "friday", "saturday", "sunday"][weekday]
            let ids = try String.fetchAll(db, sql: """
                SELECT serviceID FROM calendarEntry
                WHERE startDate <= ? AND endDate >= ? AND \(column) = 1
                """, arguments: [date.yyyymmdd, date.yyyymmdd])
            active.formUnion(ids.map { ServiceID($0) })
        }

        let added = try String.fetchAll(db, sql:
            "SELECT serviceID FROM calendarDate WHERE date = ? AND exception = 1",
            arguments: [date.yyyymmdd])
        active.formUnion(added.map { ServiceID($0) })

        let removed = try String.fetchAll(db, sql:
            "SELECT serviceID FROM calendarDate WHERE date = ? AND exception = 2",
            arguments: [date.yyyymmdd])
        active.subtract(removed.map { ServiceID($0) })

        return active
    }

    // MARK: - Departures

    /// Timetabled departures from a stop, starting at `date`.
    ///
    /// Looks at both today's and yesterday's service days. A trip departing at `30:31:00`
    /// belongs to the previous service day, so at 06:00 the relevant rows can only be found
    /// by asking yesterday's calendar with an offset past 86400. Skipping that silently
    /// loses every early-morning departure of the night lines.
    public func scheduledDepartures(
        stopID: StopID,
        from date: Date,
        horizon: TimeInterval = 3 * 3600,
        limit: Int = 30
    ) throws -> [ScheduledDeparture] {
        let today = ServiceDate(date, calendar: calendar)
        guard let yesterday = today.adding(days: -1, calendar: calendar) else { return [] }

        return try database.writer.read { db in
            var results: [ScheduledDeparture] = []
            for serviceDay in [yesterday, today] {
                guard let midnight = serviceDay.startOfDay(in: calendar) else { continue }
                let offset = Int(date.timeIntervalSince(midnight))
                // Yesterday only matters for trips that ran past midnight.
                let lowerBound = max(offset, serviceDay == yesterday ? 86_400 : 0)
                let upperBound = offset + Int(horizon)
                guard lowerBound <= upperBound else { continue }

                let services = try Self.activeServiceIDs(db, serviceDay, calendar)
                guard !services.isEmpty else { continue }
                let placeholders = databaseQuestionMarks(count: services.count)

                var arguments: [any DatabaseValueConvertible] = [stopID.rawValue, lowerBound, upperBound]
                arguments.append(contentsOf: services.map(\.rawValue))

                let rows = try Row.fetchAll(db, sql: """
                    SELECT st.tripID AS tripID, st.departure AS departure,
                           t.routeID AS routeID, t.headsign AS headsign,
                           r.shortName AS shortName, r.longName AS longName
                    FROM stopTime st
                    JOIN trip t ON t.id = st.tripID
                    JOIN route r ON r.id = t.routeID
                    WHERE st.stopID = ? AND st.departure >= ? AND st.departure <= ?
                      AND t.serviceID IN (\(placeholders))
                    ORDER BY st.departure
                    LIMIT \(limit)
                    """, arguments: StatementArguments(arguments))

                for row in rows {
                    let seconds: Int = row["departure"]
                    let time = ServiceTime(seconds: seconds)
                    results.append(ScheduledDeparture(
                        tripID: TripID(row["tripID"] as String),
                        routeID: RouteID(row["routeID"] as String),
                        routeShortName: row["shortName"] as String,
                        routeLongName: row["longName"] as String,
                        headsign: row["headsign"] as String?,
                        departure: time,
                        serviceDate: serviceDay,
                        absoluteDate: midnight.addingTimeInterval(TimeInterval(seconds))))
                }
            }
            return results.sorted { $0.absoluteDate < $1.absoluteDate }.prefix(limit).map { $0 }
        }
    }

    // MARK: - Favourites

    public func favouriteStopIDs() throws -> [StopID] {
        try database.writer.read { db in
            try FavouriteStop.order(sql: "sortIndex, addedAt").fetchAll(db).map(\.stopID)
        }
    }

    public func favouriteStops() throws -> [Stop] {
        try database.writer.read { db in
            let favourites = try FavouriteStop.order(sql: "sortIndex, addedAt").fetchAll(db)
            return try favourites.compactMap { try Stop.fetchOne(db, key: $0.stopID.rawValue) }
        }
    }

    public func isFavourite(_ stopID: StopID) throws -> Bool {
        try database.writer.read { db in
            try FavouriteStop.filter(sql: "stopID = ?", arguments: [stopID.rawValue]).fetchCount(db) > 0
        }
    }

    public func setFavourite(_ stopID: StopID, _ favourite: Bool) throws {
        try database.writer.write { db in
            if favourite {
                let next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM favouriteStop") ?? 0
                try FavouriteStop(stopID: stopID, addedAt: Date(), sortIndex: next).upsert(db)
            } else {
                try db.execute(sql: "DELETE FROM favouriteStop WHERE stopID = ?",
                               arguments: [stopID.rawValue])
            }
        }
    }

    public func reorderFavourites(_ ordered: [StopID]) throws {
        try database.writer.write { db in
            for (index, id) in ordered.enumerated() {
                try db.execute(sql: "UPDATE favouriteStop SET sortIndex = ? WHERE stopID = ?",
                               arguments: [index, id.rawValue])
            }
        }
    }

    // MARK: - Geometry

    public static func haversineMetres(_ lat1: Double, _ lon1: Double,
                                       _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
