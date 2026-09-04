import Foundation

public struct Stop: Hashable, Sendable, Codable, Identifiable {
    public let id: StopID
    /// Raw GTFS `stop_code`, e.g. `P006930`. Kept for display and debugging.
    public let gtfsStopCode: String
    /// The identifier the realtime API accepts. `nil` only if `stop_code` had no digits.
    public let vitrasaCode: VitrasaStopCode?
    public let name: String
    /// Accent- and case-folded name, precomputed at import time so search stays cheap.
    public let searchName: String
    public let latitude: Double
    public let longitude: Double
    public let wheelchairBoarding: Int?

    public init(
        id: StopID, gtfsStopCode: String, vitrasaCode: VitrasaStopCode?,
        name: String, searchName: String,
        latitude: Double, longitude: Double, wheelchairBoarding: Int?
    ) {
        self.id = id; self.gtfsStopCode = gtfsStopCode; self.vitrasaCode = vitrasaCode
        self.name = name; self.searchName = searchName
        self.latitude = latitude; self.longitude = longitude
        self.wheelchairBoarding = wheelchairBoarding
    }
}

public struct Route: Hashable, Sendable, Codable, Identifiable {
    public let id: RouteID
    public let shortName: String
    public let longName: String
    public let routeType: Int
    public let colorHex: String?
    public let textColorHex: String?

    public init(id: RouteID, shortName: String, longName: String, routeType: Int,
                colorHex: String?, textColorHex: String?) {
        self.id = id; self.shortName = shortName; self.longName = longName
        self.routeType = routeType; self.colorHex = colorHex; self.textColorHex = textColorHex
    }
}

public struct Trip: Hashable, Sendable, Codable, Identifiable {
    public let id: TripID
    public let routeID: RouteID
    public let serviceID: ServiceID
    public let headsign: String?
    public let directionID: Int?
    public let shapeID: ShapeID?

    public init(id: TripID, routeID: RouteID, serviceID: ServiceID,
                headsign: String?, directionID: Int?, shapeID: ShapeID?) {
        self.id = id; self.routeID = routeID; self.serviceID = serviceID
        self.headsign = headsign; self.directionID = directionID; self.shapeID = shapeID
    }
}

public struct StopTime: Hashable, Sendable, Codable {
    public let tripID: TripID
    public let stopID: StopID
    public let stopSequence: Int
    public let arrival: ServiceTime
    public let departure: ServiceTime

    public init(tripID: TripID, stopID: StopID, stopSequence: Int,
                arrival: ServiceTime, departure: ServiceTime) {
        self.tripID = tripID; self.stopID = stopID; self.stopSequence = stopSequence
        self.arrival = arrival; self.departure = departure
    }
}

public struct CalendarEntry: Hashable, Sendable, Codable {
    public let serviceID: ServiceID
    /// Monday-first, seven entries.
    public let daysOfWeek: [Bool]
    public let startDate: ServiceDate
    public let endDate: ServiceDate

    public init(serviceID: ServiceID, daysOfWeek: [Bool],
                startDate: ServiceDate, endDate: ServiceDate) {
        self.serviceID = serviceID; self.daysOfWeek = daysOfWeek
        self.startDate = startDate; self.endDate = endDate
    }
}

public struct CalendarDate: Hashable, Sendable, Codable {
    public enum Exception: Int, Sendable, Codable { case added = 1, removed = 2 }
    public let serviceID: ServiceID
    public let date: ServiceDate
    public let exception: Exception

    public init(serviceID: ServiceID, date: ServiceDate, exception: Exception) {
        self.serviceID = serviceID; self.date = date; self.exception = exception
    }
}

public struct ShapePoint: Hashable, Sendable, Codable {
    public let shapeID: ShapeID
    public let sequence: Int
    public let latitude: Double
    public let longitude: Double

    public init(shapeID: ShapeID, sequence: Int, latitude: Double, longitude: Double) {
        self.shapeID = shapeID; self.sequence = sequence
        self.latitude = latitude; self.longitude = longitude
    }
}

public struct Agency: Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let url: String
    public let timeZone: String

    public init(id: String, name: String, url: String, timeZone: String) {
        self.id = id; self.name = name; self.url = url; self.timeZone = timeZone
    }
}

/// The parsed contents of a GTFS feed, before it reaches the database.
public struct GTFSFeed: Sendable {
    public var agencies: [Agency] = []
    public var stops: [Stop] = []
    public var routes: [Route] = []
    public var trips: [Trip] = []
    public var stopTimes: [StopTime] = []
    public var calendar: [CalendarEntry] = []
    public var calendarDates: [CalendarDate] = []
    public var shapePoints: [ShapePoint] = []

    public init() {}

    /// The span of dates this feed can actually answer questions about.
    ///
    /// The Vitrasa feed carries an empty `calendar.txt` and a seven-day
    /// `calendar_dates.txt`, so this window is narrow and expires quickly.
    /// The UI has to be able to say "I have no data for that day" rather than
    /// "there is no service that day".
    public var serviceWindow: ClosedRange<ServiceDate>? {
        var dates: [ServiceDate] = calendarDates.map(\.date)
        for entry in calendar {
            dates.append(entry.startDate)
            dates.append(entry.endDate)
        }
        guard let lo = dates.min(), let hi = dates.max() else { return nil }
        return lo...hi
    }
}
