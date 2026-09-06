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

    /// Every day the feed can actually answer for, in order. Empty when nothing is imported.
    ///
    /// What a day picker is allowed to offer. "Seven days from today" is the wrong list and
    /// not hypothetically so: a feed downloaded on 2026-09-04 reported a window of
    /// 20260905–20260911, which *starts tomorrow* — so even "today" can sit outside it. A
    /// picker built from the clock would offer days that answer nothing, with no explanation.
    public func serviceDays(calendar: Calendar) -> [ServiceDate] {
        guard let window else { return [] }
        var days: [ServiceDate] = []
        var day = window.lowerBound
        while day <= window.upperBound {
            days.append(day)
            guard let next = day.adding(days: 1, calendar: calendar) else { break }
            day = next
        }
        return days
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
    /// Matching is done on the accent- and punctuation-folded name computed at import time
    /// (`TextNormalization.searchFolded`), so the user can type "america" and find "Praza de
    /// América", and "avda florida" and find "Avda. da Florida". The query is split into
    /// terms and every term must appear somewhere in the name — order and adjacency do not
    /// matter, so "praza america" and "america praza" both find "Praza de América" — with
    /// results ranked so a match at the very start of the name, then a match at the start of
    /// some word in it, outranks one only buried mid-word.
    ///
    /// A numeric query is also matched against the public stop code (how the number printed
    /// at the stop reads), merged with the name results rather than replacing them: a short
    /// number is as often a portal number as a stop code.
    public func searchStops(_ query: String, limit: Int = 50) throws -> [Stop] {
        let folded = TextNormalization.searchFolded(query)
        guard !folded.isEmpty else { return [] }
        let digits = folded.filter(\.isNumber)
        // Inner spaces are accepted on purpose ("69 30" reads the same as "6930") — `digits`
        // already strips them before either query below sees them.
        let isNumeric = !digits.isEmpty && folded.allSatisfy { $0.isNumber || $0.isWhitespace }
        let pattern = TextNormalization.likePattern(folded)
        let terms = folded.split(separator: " ").map(String.init)
        let termClause = terms.map { _ in "searchName LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
        let termArgs: [String] = terms.map { "%\(TextNormalization.likePattern($0))%" }

        return try database.writer.read { db in
            var numeric: [Stop] = []
            if isNumeric {
                let exactCode = Int(digits)
                if let exactCode {
                    numeric += try Stop.filter(sql: "vitrasaCode = ?", arguments: [exactCode]).fetchAll(db)
                }
                // The canonical form, not `digits`: no stored code carries a leading zero, so
                // "0693" has to find the same stop as "693". Built without `Int(digits)`, which
                // is `nil` for an implausibly long query — the prefix search below does not
                // need the integer, only the exact match above does.
                let canonical = String(digits.drop(while: { $0 == "0" }))
                if !canonical.isEmpty {
                    var sql = "CAST(vitrasaCode AS TEXT) LIKE ? ESCAPE '\\'"
                    var args: [any DatabaseValueConvertible] = ["\(TextNormalization.likePattern(canonical))%"]
                    if let exactCode {
                        sql += " AND vitrasaCode <> ?"
                        args.append(exactCode)
                    }
                    numeric += try Stop.filter(sql: sql, arguments: StatementArguments(args))
                        .order(sql: "vitrasaCode").limit(limit).fetchAll(db)
                }
            }

            // Prefix matches first, then matches anywhere, so "coru" puts
            // "Rúa da Coruña" above a stop that merely mentions it.
            let prefixed = try Stop
                .filter(sql: "searchName LIKE ? ESCAPE '\\'", arguments: ["\(pattern)%"])
                .order(sql: "searchName").limit(limit).fetchAll(db)
            // Every term has to appear somewhere, in any order — "hospital povisa" finds
            // "Rúa de Barcelona  Hospital Ribera Povisa" even though the words are neither
            // contiguous nor in that order in the name.
            let contained = try Stop
                .filter(sql: "(\(termClause)) AND searchName NOT LIKE ? ESCAPE '\\'",
                        arguments: StatementArguments(termArgs + ["\(pattern)%"]))
                .fetchAll(db)
                .map { ($0, Self.termPrefixScore(terms, in: $0.searchName)) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.searchName < $1.0.searchName }
                .map(\.0)

            var seen = Set<StopID>()
            var merged: [Stop] = []
            for stop in numeric + prefixed + contained where seen.insert(stop.id).inserted {
                merged.append(stop)
            }
            return Array(merged.prefix(limit))
        }
    }

    /// How many `terms` prefix some word of `foldedName`, for ranking the "appears
    /// somewhere" tier of `searchStops`: a term matching the start of a word ("coru" in
    /// "rua da coruna") outranks one that only appears buried inside one.
    private static func termPrefixScore(_ terms: [String], in foldedName: String) -> Int {
        let words = foldedName.split(separator: " ")
        return terms.reduce(0) { score, term in
            score + (words.contains { $0.hasPrefix(term) } ? 1 : 0)
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

    /// Every timetabled departure of one route from one stop, on one calendar day.
    ///
    /// The sibling of `scheduledDepartures(stopID:from:horizon:limit:)`, which answers "what is
    /// coming soon" — all routes, three hours, thirty rows. This one answers "when does this
    /// line pass here", which is a different question and needs the whole day: a busy Vitrasa
    /// line is 60–80 rows, so there is no cap to apply.
    ///
    /// **A calendar day, not a service day, and the two are not the same.** A trip departing at
    /// `25:10:00` belongs to the *previous* service day but happens at 01:10 on this one, and
    /// somebody reading a timetable expects to find it under the day they will be standing at
    /// the stop. So both service days are asked, and each row is placed by the instant it
    /// actually happens. Asking only the day named would silently lose every early-morning
    /// departure of the night lines.
    ///
    /// The bounds come from real midnights rather than from adding 86 400, for the reason
    /// `TimetableBuilder` already documents: twice a year the offset between two midnights is
    /// not a day.
    public func scheduledDepartures(
        stopID: StopID, routeID: RouteID, on serviceDate: ServiceDate
    ) throws -> [ScheduledDeparture] {
        guard let dayStart = serviceDate.startOfDay(in: calendar),
              let nextDay = serviceDate.adding(days: 1, calendar: calendar),
              let dayEnd = nextDay.startOfDay(in: calendar),
              let previousDay = serviceDate.adding(days: -1, calendar: calendar)
        else { return [] }

        return try database.writer.read { db in
            var results: [ScheduledDeparture] = []
            for serviceDay in [previousDay, serviceDate] {
                guard let midnight = serviceDay.startOfDay(in: calendar) else { continue }
                let lowerBound = Int(dayStart.timeIntervalSince(midnight))
                let upperBound = Int(dayEnd.timeIntervalSince(midnight))

                let services = try Self.activeServiceIDs(db, serviceDay, calendar)
                guard !services.isEmpty else { continue }
                let placeholders = databaseQuestionMarks(count: services.count)

                var arguments: [any DatabaseValueConvertible] = [
                    stopID.rawValue, routeID.rawValue, lowerBound, upperBound
                ]
                arguments.append(contentsOf: services.map(\.rawValue))

                let rows = try Row.fetchAll(db, sql: """
                    SELECT st.tripID AS tripID, st.departure AS departure,
                           t.routeID AS routeID, t.headsign AS headsign,
                           r.shortName AS shortName, r.longName AS longName
                    FROM stopTime st
                    JOIN trip t ON t.id = st.tripID
                    JOIN route r ON r.id = t.routeID
                    WHERE st.stopID = ? AND t.routeID = ?
                      AND st.departure >= ? AND st.departure < ?
                      AND t.serviceID IN (\(placeholders))
                    ORDER BY st.departure
                    """, arguments: StatementArguments(arguments))

                for row in rows {
                    let seconds: Int = row["departure"]
                    results.append(ScheduledDeparture(
                        tripID: TripID(row["tripID"] as String),
                        routeID: RouteID(row["routeID"] as String),
                        routeShortName: row["shortName"] as String,
                        routeLongName: row["longName"] as String,
                        headsign: row["headsign"] as String?,
                        departure: ServiceTime(seconds: seconds),
                        serviceDate: serviceDay,
                        absoluteDate: midnight.addingTimeInterval(TimeInterval(seconds))))
                }
            }
            return results.sorted { $0.absoluteDate < $1.absoluteDate }
        }
    }

    // MARK: - Favourites

    public func favouriteStopIDs() throws -> [StopID] {
        try database.writer.read { db in
            try FavouriteStop.order(sql: "sortIndex, addedAt").fetchAll(db).map(\.stopID)
        }
    }

    /// Every favourite row, including ones whose stop_id the current feed no longer
    /// contains. `favouriteStops()` compact-maps those away; this is how the UI can say so
    /// out loud instead of silently shortening the list after a weekly refresh.
    public func favouriteStopRows() throws -> [FavouriteStop] {
        try database.writer.read { db in
            try FavouriteStop.order(sql: "sortIndex, addedAt").fetchAll(db)
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

    // MARK: - Saved places

    public func savedPlaces() throws -> [SavedPlace] {
        try database.writer.read { db in
            let rows = try SavedPlaceRow.order(sql: "sortIndex, createdAt").fetchAll(db)
            let stops = try Self.resolveStops(for: rows.compactMap(\.stopID), db: db)
            return rows.map { Self.savedPlace(from: $0, stops: stops) }
        }
    }

    public func savedPlace(id: SavedPlaceID) throws -> SavedPlace? {
        try database.writer.read { db in
            guard let row = try SavedPlaceRow.fetchOne(db, key: id.rawValue) else { return nil }
            let stops = try Self.resolveStops(for: [row.stopID].compactMap { $0 }, db: db)
            return Self.savedPlace(from: row, stops: stops)
        }
    }

    @discardableResult
    public func createSavedPlace(
        name: String, symbolName: String, anchor: SavedPlaceAnchorInput, now: Date = Date()
    ) throws -> SavedPlace {
        try database.writer.write { db in
            let next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM savedPlace") ?? 0
            let row = SavedPlaceRow(
                id: SavedPlaceID.generate().rawValue, name: name, symbolName: symbolName,
                kind: anchor.kindString, stopID: anchor.stopIDString,
                latitude: anchor.coordinate.latitude, longitude: anchor.coordinate.longitude,
                createdAt: now, sortIndex: next)
            try row.insert(db)
            let stops = try Self.resolveStops(for: [row.stopID].compactMap { $0 }, db: db)
            return Self.savedPlace(from: row, stops: stops)
        }
    }

    public func updateSavedPlace(id: SavedPlaceID, _ edit: SavedPlaceEdit) throws {
        try database.writer.write { db in
            guard var row = try SavedPlaceRow.fetchOne(db, key: id.rawValue) else { return }
            if let name = edit.name { row.name = name }
            if let symbolName = edit.symbolName { row.symbolName = symbolName }
            if let anchor = edit.anchor {
                row.kind = anchor.kindString
                row.stopID = anchor.stopIDString
                row.latitude = anchor.coordinate.latitude
                row.longitude = anchor.coordinate.longitude
            }
            try row.update(db)
        }
    }

    /// Deleting a place must not leave a dangling reference in `savedJourney`: the
    /// `ON DELETE SET NULL` on the schema says the intent, and these two explicit UPDATEs
    /// in the same transaction mean correctness does not depend on that pragma alone.
    public func deleteSavedPlace(id: SavedPlaceID) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE savedJourney SET originPlaceID = NULL WHERE originPlaceID = ?",
                           arguments: [id.rawValue])
            try db.execute(sql: "UPDATE savedJourney SET destinationPlaceID = NULL WHERE destinationPlaceID = ?",
                           arguments: [id.rawValue])
            _ = try SavedPlaceRow.deleteOne(db, key: id.rawValue)
        }
    }

    public func reorderSavedPlaces(_ ordered: [SavedPlaceID]) throws {
        try database.writer.write { db in
            for (index, id) in ordered.enumerated() {
                try db.execute(sql: "UPDATE savedPlace SET sortIndex = ? WHERE id = ?",
                               arguments: [index, id.rawValue])
            }
        }
    }

    // MARK: - Saved journeys

    public func savedJourneys() throws -> [SavedJourney] {
        try database.writer.read { db in
            let rows = try SavedJourneyRow.order(sql: "sortIndex, createdAt").fetchAll(db)
            let placeIDs = Set(rows.flatMap { [$0.originPlaceID, $0.destinationPlaceID] }.compactMap { $0 })
            let placeRows = placeIDs.isEmpty ? [] : try SavedPlaceRow.filter(keys: Array(placeIDs)).fetchAll(db)

            var stopIDs = Set(placeRows.compactMap(\.stopID))
            stopIDs.formUnion(rows.compactMap(\.originStopID))
            stopIDs.formUnion(rows.compactMap(\.destinationStopID))
            let stops = try Self.resolveStops(for: Array(stopIDs), db: db)

            var places: [String: SavedPlace] = [:]
            for row in placeRows { places[row.id] = Self.savedPlace(from: row, stops: stops) }
            return rows.map { Self.savedJourney(from: $0, places: places, stops: stops) }
        }
    }

    public func savedJourney(id: SavedJourneyID) throws -> SavedJourney? {
        try database.writer.read { db in
            guard let row = try SavedJourneyRow.fetchOne(db, key: id.rawValue) else { return nil }
            return try Self.resolvedJourney(row, db: db)
        }
    }

    @discardableResult
    public func createSavedJourney(
        customLabel: String?, origin: SavedEndpointInput, destination: SavedEndpointInput,
        now: Date = Date()
    ) throws -> SavedJourney {
        try database.writer.write { db in
            let next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM savedJourney") ?? 0
            let row = SavedJourneyRow(
                id: SavedJourneyID.generate().rawValue, customLabel: customLabel,
                createdAt: now, sortIndex: next,
                originPlaceID: origin.placeID?.rawValue, originName: origin.name,
                originSymbolName: origin.symbolName, originKind: origin.anchor.kindString,
                originStopID: origin.anchor.stopIDString,
                originLatitude: origin.anchor.coordinate.latitude,
                originLongitude: origin.anchor.coordinate.longitude,
                destinationPlaceID: destination.placeID?.rawValue, destinationName: destination.name,
                destinationSymbolName: destination.symbolName, destinationKind: destination.anchor.kindString,
                destinationStopID: destination.anchor.stopIDString,
                destinationLatitude: destination.anchor.coordinate.latitude,
                destinationLongitude: destination.anchor.coordinate.longitude)
            try row.insert(db)
            return try Self.resolvedJourney(row, db: db)
        }
    }

    public func updateSavedJourney(id: SavedJourneyID, _ edit: SavedJourneyEdit) throws {
        try database.writer.write { db in
            guard var row = try SavedJourneyRow.fetchOne(db, key: id.rawValue) else { return }
            switch edit.label {
            case .unchanged: break
            case .custom(let text): row.customLabel = text
            case .derived: row.customLabel = nil
            }
            if let origin = edit.origin {
                row.originPlaceID = origin.placeID?.rawValue
                row.originName = origin.name
                row.originSymbolName = origin.symbolName
                row.originKind = origin.anchor.kindString
                row.originStopID = origin.anchor.stopIDString
                row.originLatitude = origin.anchor.coordinate.latitude
                row.originLongitude = origin.anchor.coordinate.longitude
            }
            if let destination = edit.destination {
                row.destinationPlaceID = destination.placeID?.rawValue
                row.destinationName = destination.name
                row.destinationSymbolName = destination.symbolName
                row.destinationKind = destination.anchor.kindString
                row.destinationStopID = destination.anchor.stopIDString
                row.destinationLatitude = destination.anchor.coordinate.latitude
                row.destinationLongitude = destination.anchor.coordinate.longitude
            }
            try row.update(db)
        }
    }

    public func deleteSavedJourney(id: SavedJourneyID) throws {
        try database.writer.write { db in
            _ = try SavedJourneyRow.deleteOne(db, key: id.rawValue)
        }
    }

    public func reorderSavedJourneys(_ ordered: [SavedJourneyID]) throws {
        try database.writer.write { db in
            for (index, id) in ordered.enumerated() {
                try db.execute(sql: "UPDATE savedJourney SET sortIndex = ? WHERE id = ?",
                               arguments: [index, id.rawValue])
            }
        }
    }

    // MARK: - Trayecto activo

    public func activeJourney() throws -> ActiveJourneySnapshot? {
        try database.writer.read { db in
            guard let row = try ActiveJourneyRow.fetchOne(db, key: ActiveJourneyRow.currentID) else {
                return nil
            }
            return try JSONDecoder().decode(ActiveJourneySnapshot.self, from: row.payload)
        }
    }

    /// `upsert`, not `insert`: the primary key is the constant `"current"`, so starting a
    /// second journey without ending the first replaces it in place — there is never a way
    /// to end up with two rows.
    public func startActiveJourney(_ snapshot: ActiveJourneySnapshot, startedAt: Date = Date()) throws {
        let payload = try JSONEncoder().encode(snapshot)
        try database.writer.write { db in
            let row = ActiveJourneyRow(
                id: ActiveJourneyRow.currentID, startedAt: startedAt, state: "active",
                destinationName: snapshot.destination.name,
                destinationStopID: snapshot.destination.stopID?.rawValue,
                destinationLatitude: snapshot.destination.latitude,
                destinationLongitude: snapshot.destination.longitude,
                scheduledArrival: snapshot.scheduledArrival,
                payload: payload)
            try row.upsert(db)
        }
    }

    /// Covers both "Terminar" and "Cancelar": the two are distinguished in the UI, never in
    /// the data, since there is no history to keep either way (a confirmed product decision —
    /// no record of finished journeys).
    public func endActiveJourney() throws {
        try database.writer.write { db in
            _ = try ActiveJourneyRow.deleteOne(db, key: ActiveJourneyRow.currentID)
        }
    }

    public func markActiveJourneyStale() throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE activeJourney SET state = 'stale' WHERE id = ?",
                           arguments: [ActiveJourneyRow.currentID])
        }
    }

    /// "Sigo en él": pushes the deadline forward. The caller (`ActiveJourneyStore`) computes
    /// the new `scheduledArrival` — normally the current one plus another grace window — so
    /// this stays a plain write with no policy of its own.
    ///
    /// Updates the flat `scheduledArrival` column **and** re-encodes the payload with it, so
    /// a later `activeJourney()` and `staleness(now:)` agree with what this just wrote —
    /// otherwise the row would go stale again one grace period sooner than the column says.
    public func extendActiveJourney(to scheduledArrival: Date) throws {
        try database.writer.write { db in
            guard var row = try ActiveJourneyRow.fetchOne(db, key: ActiveJourneyRow.currentID) else { return }
            let snapshot = try JSONDecoder().decode(ActiveJourneySnapshot.self, from: row.payload)
            let extended = ActiveJourneySnapshot(
                originName: snapshot.originName, destination: snapshot.destination,
                rides: snapshot.rides, egressWalkSeconds: snapshot.egressWalkSeconds,
                scheduledDeparture: snapshot.scheduledDeparture,
                scheduledArrival: scheduledArrival, transfers: snapshot.transfers)
            row.scheduledArrival = scheduledArrival
            row.state = "active"
            row.payload = try JSONEncoder().encode(extended)
            try row.update(db)
        }
    }

    // MARK: - Saved place / journey row mapping

    private static func resolveStops(for stopIDs: [String], db: Database) throws -> [String: Stop] {
        guard !stopIDs.isEmpty else { return [:] }
        let stops = try Stop.filter(keys: Set(stopIDs)).fetchAll(db)
        return Dictionary(uniqueKeysWithValues: stops.map { ($0.id.rawValue, $0) })
    }

    private static func anchor(
        kind: String, stopID: String?, latitude: Double, longitude: Double, stops: [String: Stop]
    ) -> SavedPlaceAnchor {
        guard kind == "stop", let stopID else {
            return .coordinate(Coordinate(latitude: latitude, longitude: longitude))
        }
        if let stop = stops[stopID] { return .stop(stop) }
        return .orphanedStop(StopID(stopID), fallback: Coordinate(latitude: latitude, longitude: longitude))
    }

    private static func savedPlace(from row: SavedPlaceRow, stops: [String: Stop]) -> SavedPlace {
        SavedPlace(
            id: SavedPlaceID(row.id), name: row.name, symbolName: row.symbolName,
            anchor: anchor(kind: row.kind, stopID: row.stopID,
                          latitude: row.latitude, longitude: row.longitude, stops: stops),
            createdAt: row.createdAt, sortIndex: row.sortIndex)
    }

    private static func endpoint(
        placeID: String?, name: String, symbolName: String, kind: String, stopID: String?,
        latitude: Double, longitude: Double, places: [String: SavedPlace], stops: [String: Stop]
    ) -> SavedEndpoint {
        if let placeID, let place = places[placeID] {
            return SavedEndpoint(placeID: place.id, name: place.name, symbolName: place.symbolName,
                                 anchor: place.anchor)
        }
        let resolved = anchor(kind: kind, stopID: stopID, latitude: latitude, longitude: longitude, stops: stops)
        return SavedEndpoint(placeID: nil, name: name, symbolName: symbolName, anchor: resolved)
    }

    private static func savedJourney(
        from row: SavedJourneyRow, places: [String: SavedPlace], stops: [String: Stop]
    ) -> SavedJourney {
        SavedJourney(
            id: SavedJourneyID(row.id), customLabel: row.customLabel,
            origin: endpoint(placeID: row.originPlaceID, name: row.originName,
                            symbolName: row.originSymbolName, kind: row.originKind,
                            stopID: row.originStopID, latitude: row.originLatitude,
                            longitude: row.originLongitude, places: places, stops: stops),
            destination: endpoint(placeID: row.destinationPlaceID, name: row.destinationName,
                                 symbolName: row.destinationSymbolName, kind: row.destinationKind,
                                 stopID: row.destinationStopID, latitude: row.destinationLatitude,
                                 longitude: row.destinationLongitude, places: places, stops: stops),
            createdAt: row.createdAt, sortIndex: row.sortIndex)
    }

    /// Resolves a single saved journey row: its endpoints' live-linked places (if any) and
    /// every stop_id involved, in one extra read each — used by `createSavedJourney` and
    /// `savedJourney(id:)`, where `savedJourneys()` instead resolves all rows in one batch.
    private static func resolvedJourney(_ row: SavedJourneyRow, db: Database) throws -> SavedJourney {
        let placeIDs = [row.originPlaceID, row.destinationPlaceID].compactMap { $0 }
        let placeRows = placeIDs.isEmpty ? [] : try SavedPlaceRow.filter(keys: placeIDs).fetchAll(db)

        var stopIDs = Set(placeRows.compactMap(\.stopID))
        if let s = row.originStopID { stopIDs.insert(s) }
        if let s = row.destinationStopID { stopIDs.insert(s) }
        let stops = try resolveStops(for: Array(stopIDs), db: db)

        var places: [String: SavedPlace] = [:]
        for placeRow in placeRows { places[placeRow.id] = savedPlace(from: placeRow, stops: stops) }
        return savedJourney(from: row, places: places, stops: stops)
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
