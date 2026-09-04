import Foundation

/// Supplies the raw bytes of a GTFS file by name, so the parser can run against an
/// unzipped directory on device or against fixtures in tests.
public protocol GTFSFileProviding: Sendable {
    /// Returns `nil` when the file is absent — several GTFS files are optional.
    func data(forFile name: String) throws -> Data?
}

public struct GTFSDirectory: GTFSFileProviding {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func data(forFile name: String) throws -> Data? {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}

public struct GTFSInMemory: GTFSFileProviding {
    private let files: [String: Data]
    public init(files: [String: Data]) { self.files = files }
    public init(texts: [String: String]) {
        self.files = texts.mapValues { Data($0.utf8) }
    }
    public func data(forFile name: String) throws -> Data? { files[name] }
}

public enum GTFSParseError: Error, CustomStringConvertible, Sendable {
    case missingRequiredFile(String)
    case csv(CSVError)
    case badRow(file: String, line: Int, reason: String)

    public var description: String {
        switch self {
        case .missingRequiredFile(let f): "missing required file \(f)"
        case .csv(let e): e.description
        case .badRow(let f, let l, let r): "\(f) row \(l): \(r)"
        }
    }
}

/// Non-fatal observations made while parsing. Surfaced rather than logged so the app can
/// show the user that the feed is degrading before it breaks outright.
public struct GTFSParseWarning: Sendable, Hashable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let message: String
    public var description: String { "\(file):\(line): \(message)" }
}

public struct GTFSParseResult: Sendable {
    public let feed: GTFSFeed
    public let warnings: [GTFSParseWarning]
}

public struct GTFSParser: Sendable {
    /// Cap on warnings retained, so a catastrophically broken feed cannot exhaust memory.
    public let maxWarnings: Int

    public init(maxWarnings: Int = 500) { self.maxWarnings = maxWarnings }

    public func parse(from provider: some GTFSFileProviding) throws -> GTFSParseResult {
        var feed = GTFSFeed()
        var warnings: [GTFSParseWarning] = []

        func warn(_ file: String, _ line: Int, _ message: String) {
            guard warnings.count < maxWarnings else { return }
            warnings.append(GTFSParseWarning(file: file, line: line, message: message))
        }

        func table(_ name: String, required: Bool) throws -> CSVTable? {
            guard let data = try provider.data(forFile: name) else {
                if required { throw GTFSParseError.missingRequiredFile(name) }
                return nil
            }
            do { return try CSVTable(data: data, fileName: name) }
            catch let e as CSVError {
                if required { throw GTFSParseError.csv(e) }
                warn(name, 0, "unreadable, skipped: \(e.reason)")
                return nil
            }
        }

        // agency.txt
        if let t = try table("agency.txt", required: false) {
            let idI = t.columnIndex("agency_id")
            let nameI = try t.requiredColumnIndex("agency_name")
            let urlI = t.columnIndex("agency_url")
            let tzI = t.columnIndex("agency_timezone")
            for row in t.rows {
                guard let name = row.csvValue(nameI) else { continue }
                feed.agencies.append(Agency(
                    id: row.csvValue(idI) ?? "",
                    name: name,
                    url: row.csvValue(urlI) ?? "",
                    timeZone: row.csvValue(tzI) ?? "Europe/Madrid"))
            }
        }

        // stops.txt
        do {
            guard let t = try table("stops.txt", required: true) else {
                throw GTFSParseError.missingRequiredFile("stops.txt")
            }
            let idI = try t.requiredColumnIndex("stop_id")
            let codeI = t.columnIndex("stop_code")
            let nameI = try t.requiredColumnIndex("stop_name")
            let latI = try t.requiredColumnIndex("stop_lat")
            let lonI = try t.requiredColumnIndex("stop_lon")
            let wcI = t.columnIndex("wheelchair_boarding")
            feed.stops.reserveCapacity(t.rows.count)
            for (n, row) in t.rows.enumerated() {
                let ln = n + 2
                guard let rawID = row.csvValue(idI) else {
                    warn("stops.txt", ln, "blank stop_id, row skipped"); continue
                }
                guard let latText = row.csvValue(latI), let lat = Double(latText),
                      let lonText = row.csvValue(lonI), let lon = Double(lonText) else {
                    warn("stops.txt", ln, "unparsable coordinates for stop \(rawID), row skipped")
                    continue
                }
                let name = row.csvValue(nameI) ?? rawID
                let gtfsCode = row.csvValue(codeI) ?? ""
                let vitrasa = VitrasaStopCode(gtfsStopCode: gtfsCode)
                if vitrasa == nil {
                    // Not fatal: the stop still works for timetables, it just cannot be
                    // queried for live arrivals.
                    warn("stops.txt", ln, "stop \(rawID) has no usable stop_code '\(gtfsCode)'; no realtime for it")
                }
                feed.stops.append(Stop(
                    id: StopID(rawID),
                    gtfsStopCode: gtfsCode,
                    vitrasaCode: vitrasa,
                    name: name,
                    searchName: TextNormalization.searchFolded(name),
                    latitude: lat, longitude: lon,
                    wheelchairBoarding: row.csvValue(wcI).flatMap(Int.init)))
            }
        }

        // routes.txt
        do {
            guard let t = try table("routes.txt", required: true) else {
                throw GTFSParseError.missingRequiredFile("routes.txt")
            }
            let idI = try t.requiredColumnIndex("route_id")
            let shortI = t.columnIndex("route_short_name")
            let longI = t.columnIndex("route_long_name")
            let typeI = t.columnIndex("route_type")
            let colorI = t.columnIndex("route_color")
            let textColorI = t.columnIndex("route_text_color")
            for (n, row) in t.rows.enumerated() {
                let ln = n + 2
                guard let rawID = row.csvValue(idI) else {
                    warn("routes.txt", ln, "blank route_id, row skipped"); continue
                }
                let short = row.csvValue(shortI) ?? ""
                let long = row.csvValue(longI) ?? ""
                if short.isEmpty && long.isEmpty {
                    warn("routes.txt", ln, "route \(rawID) has neither short nor long name")
                }
                feed.routes.append(Route(
                    id: RouteID(rawID),
                    shortName: short,
                    longName: long,
                    routeType: row.csvValue(typeI).flatMap(Int.init) ?? 3,
                    colorHex: row.csvValue(colorI),
                    textColorHex: row.csvValue(textColorI)))
            }
        }

        // trips.txt
        do {
            guard let t = try table("trips.txt", required: true) else {
                throw GTFSParseError.missingRequiredFile("trips.txt")
            }
            let tripI = try t.requiredColumnIndex("trip_id")
            let routeI = try t.requiredColumnIndex("route_id")
            let svcI = try t.requiredColumnIndex("service_id")
            let headI = t.columnIndex("trip_headsign")
            let dirI = t.columnIndex("direction_id")
            let shapeI = t.columnIndex("shape_id")
            feed.trips.reserveCapacity(t.rows.count)
            for (n, row) in t.rows.enumerated() {
                let ln = n + 2
                guard let tripID = row.csvValue(tripI),
                      let routeID = row.csvValue(routeI),
                      let svcID = row.csvValue(svcI) else {
                    warn("trips.txt", ln, "missing trip_id/route_id/service_id, row skipped")
                    continue
                }
                feed.trips.append(Trip(
                    id: TripID(tripID),
                    routeID: RouteID(routeID),
                    serviceID: ServiceID(svcID),
                    headsign: row.csvValue(headI),
                    directionID: row.csvValue(dirI).flatMap(Int.init),
                    shapeID: row.csvValue(shapeI).map { ShapeID($0) }))
            }
        }

        // stop_times.txt — the big one.
        do {
            guard let t = try table("stop_times.txt", required: true) else {
                throw GTFSParseError.missingRequiredFile("stop_times.txt")
            }
            let tripI = try t.requiredColumnIndex("trip_id")
            let stopI = try t.requiredColumnIndex("stop_id")
            let seqI = try t.requiredColumnIndex("stop_sequence")
            let arrI = try t.requiredColumnIndex("arrival_time")
            let depI = try t.requiredColumnIndex("departure_time")
            feed.stopTimes.reserveCapacity(t.rows.count)
            for (n, row) in t.rows.enumerated() {
                let ln = n + 2
                guard let tripID = row.csvValue(tripI),
                      let stopID = row.csvValue(stopI),
                      let seq = row.csvValue(seqI).flatMap(Int.init) else {
                    warn("stop_times.txt", ln, "missing trip_id/stop_id/stop_sequence, row skipped")
                    continue
                }
                // Times are optional in GTFS but present throughout this feed. A row with
                // an unparsable time is dropped loudly rather than defaulted to midnight.
                let arrText = row.csvValue(arrI)
                let depText = row.csvValue(depI)
                let arrival = arrText.flatMap { ServiceTime(gtfs: $0) }
                let departure = depText.flatMap { ServiceTime(gtfs: $0) }
                guard let arrival, let departure else {
                    warn("stop_times.txt", ln,
                         "unparsable time (arrival='\(arrText ?? "")' departure='\(depText ?? "")') on trip \(tripID), row skipped")
                    continue
                }
                feed.stopTimes.append(StopTime(
                    tripID: TripID(tripID), stopID: StopID(stopID),
                    stopSequence: seq, arrival: arrival, departure: departure))
            }
        }

        // calendar.txt — optional, and empty in the Vitrasa feed.
        if let t = try table("calendar.txt", required: false) {
            let svcI = t.columnIndex("service_id")
            let dayIndices = ["monday", "tuesday", "wednesday", "thursday",
                              "friday", "saturday", "sunday"].map { t.columnIndex($0) }
            let startI = t.columnIndex("start_date")
            let endI = t.columnIndex("end_date")
            for (n, row) in t.rows.enumerated() {
                let ln = n + 2
                guard let svc = row.csvValue(svcI) else { continue }
                guard let s = row.csvValue(startI).flatMap({ ServiceDate(gtfs: $0) }),
                      let e = row.csvValue(endI).flatMap({ ServiceDate(gtfs: $0) }) else {
                    warn("calendar.txt", ln, "unparsable start/end date for service \(svc), row skipped")
                    continue
                }
                feed.calendar.append(CalendarEntry(
                    serviceID: ServiceID(svc),
                    daysOfWeek: dayIndices.map { row.csvValue($0) == "1" },
                    startDate: s, endDate: e))
            }
        }

        // calendar_dates.txt — in this feed, the only source of service.
        if let t = try table("calendar_dates.txt", required: false) {
            let svcI = try t.requiredColumnIndex("service_id")
            let dateI = try t.requiredColumnIndex("date")
            let typeI = t.columnIndex("exception_type")
            feed.calendarDates.reserveCapacity(t.rows.count)
            for (n, row) in t.rows.enumerated() {
                let ln = n + 2
                guard let svc = row.csvValue(svcI),
                      let date = row.csvValue(dateI).flatMap({ ServiceDate(gtfs: $0) }) else {
                    warn("calendar_dates.txt", ln, "missing service_id or unparsable date, row skipped")
                    continue
                }
                let raw = row.csvValue(typeI).flatMap(Int.init) ?? 1
                guard let exception = CalendarDate.Exception(rawValue: raw) else {
                    warn("calendar_dates.txt", ln, "unknown exception_type \(raw), row skipped")
                    continue
                }
                feed.calendarDates.append(CalendarDate(
                    serviceID: ServiceID(svc), date: date, exception: exception))
            }
        }

        if feed.calendar.isEmpty && feed.calendarDates.isEmpty {
            warn("calendar_dates.txt", 0, "feed defines no service at all: every trip will be inactive")
        }

        // shapes.txt — optional; present and complete in this feed.
        if let t = try table("shapes.txt", required: false) {
            let idI = try t.requiredColumnIndex("shape_id")
            let latI = try t.requiredColumnIndex("shape_pt_lat")
            let lonI = try t.requiredColumnIndex("shape_pt_lon")
            let seqI = try t.requiredColumnIndex("shape_pt_sequence")
            feed.shapePoints.reserveCapacity(t.rows.count)
            for (n, row) in t.rows.enumerated() {
                let ln = n + 2
                guard let id = row.csvValue(idI),
                      let lat = row.csvValue(latI).flatMap(Double.init),
                      let lon = row.csvValue(lonI).flatMap(Double.init),
                      let seq = row.csvValue(seqI).flatMap(Int.init) else {
                    warn("shapes.txt", ln, "unparsable shape point, row skipped")
                    continue
                }
                feed.shapePoints.append(ShapePoint(
                    shapeID: ShapeID(id), sequence: seq, latitude: lat, longitude: lon))
            }
        }

        return GTFSParseResult(feed: feed, warnings: warnings)
    }
}
