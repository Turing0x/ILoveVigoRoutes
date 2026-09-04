import Foundation

/// Referential-integrity and sanity checks over a parsed feed.
///
/// This is the Swift counterpart of the Fase 0 validation, kept in the app so a bad
/// refresh is caught at import time rather than surfacing as wrong departure times.
/// Findings are graded: `blocking` means do not swap this feed in, `advisory` means
/// import it but tell the user.
public struct GTFSValidator: Sendable {

    public enum Severity: Sendable, Comparable { case advisory, blocking }

    public struct Finding: Sendable, Hashable, CustomStringConvertible {
        public let severity: Severity
        public let check: String
        public let count: Int
        public let detail: String
        public var description: String { "[\(severity == .blocking ? "BLOCK" : "warn")] \(check): \(detail)" }

        // Hashable conformance keeps Severity out of the synthesized requirement.
        public static func == (a: Finding, b: Finding) -> Bool {
            a.check == b.check && a.count == b.count && a.detail == b.detail
        }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(check); hasher.combine(count); hasher.combine(detail)
        }
    }

    public struct Report: Sendable {
        public let findings: [Finding]
        public let stopCount: Int
        public let routeCount: Int
        public let routesWithTrips: Int
        public let tripCount: Int
        public let stopTimeCount: Int
        public let shapePointCount: Int
        public let serviceWindow: ClosedRange<ServiceDate>?
        public let timesPastMidnight: Int
        public let latestTime: ServiceTime?

        public var isImportable: Bool { !findings.contains { $0.severity == .blocking } }
        public var blocking: [Finding] { findings.filter { $0.severity == .blocking } }
        public var advisories: [Finding] { findings.filter { $0.severity == .advisory } }
    }

    public init() {}

    public func validate(_ feed: GTFSFeed) -> Report {
        var findings: [Finding] = []

        let routeIDs = Set(feed.routes.map(\.id))
        let tripIDs = Set(feed.trips.map(\.id))
        let stopIDs = Set(feed.stops.map(\.id))
        let shapeIDs = Set(feed.shapePoints.map(\.shapeID))
        var serviceIDs = Set(feed.calendar.map(\.serviceID))
        serviceIDs.formUnion(feed.calendarDates.map(\.serviceID))

        func add(_ severity: Severity, _ check: String, _ count: Int, _ detail: String) {
            guard count > 0 else { return }
            findings.append(Finding(severity: severity, check: check, count: count, detail: detail))
        }

        // --- Structural emptiness: these make the feed useless, not merely degraded.
        if feed.stops.isEmpty { add(.blocking, "stops.empty", 1, "feed has no stops") }
        if feed.routes.isEmpty { add(.blocking, "routes.empty", 1, "feed has no routes") }
        if feed.trips.isEmpty { add(.blocking, "trips.empty", 1, "feed has no trips") }
        if feed.stopTimes.isEmpty { add(.blocking, "stopTimes.empty", 1, "feed has no stop times") }
        if serviceIDs.isEmpty {
            add(.blocking, "service.empty", 1,
                "no calendar.txt rows and no calendar_dates.txt rows: nothing would ever run")
        }

        // --- Referential integrity.
        let orphanTripRoutes = feed.trips.filter { !routeIDs.contains($0.routeID) }.count
        add(.blocking, "trips.route_id", orphanTripRoutes,
            "\(orphanTripRoutes) trips reference a route that does not exist")

        let orphanTripServices = feed.trips.filter { !serviceIDs.contains($0.serviceID) }.count
        add(.blocking, "trips.service_id", orphanTripServices,
            "\(orphanTripServices) trips reference a service that does not exist")

        let orphanTripShapes = feed.trips.filter {
            if let s = $0.shapeID { return !shapeIDs.contains(s) } else { return false }
        }.count
        // Advisory: a missing shape costs a drawn line on the map, not a departure time.
        add(.advisory, "trips.shape_id", orphanTripShapes,
            "\(orphanTripShapes) trips reference a shape that has no points")

        var orphanStopTimeTrips = 0
        var orphanStopTimeStops = 0
        var tripsSeen = Set<TripID>()
        var stopsSeen = Set<StopID>()
        var pastMidnight = 0
        var latest: ServiceTime?
        for st in feed.stopTimes {
            if !tripIDs.contains(st.tripID) { orphanStopTimeTrips += 1 } else { tripsSeen.insert(st.tripID) }
            if !stopIDs.contains(st.stopID) { orphanStopTimeStops += 1 } else { stopsSeen.insert(st.stopID) }
            if st.departure.rollsPastMidnight { pastMidnight += 1 }
            if latest == nil || st.departure > latest! { latest = st.departure }
        }
        add(.blocking, "stopTimes.trip_id", orphanStopTimeTrips,
            "\(orphanStopTimeTrips) stop times reference a trip that does not exist")
        add(.blocking, "stopTimes.stop_id", orphanStopTimeStops,
            "\(orphanStopTimeStops) stop times reference a stop that does not exist")

        let tripsWithoutTimes = tripIDs.subtracting(tripsSeen).count
        add(.advisory, "trips.withoutStopTimes", tripsWithoutTimes,
            "\(tripsWithoutTimes) trips have no stop times and can never be shown")

        let stopsNeverServed = stopIDs.subtracting(stopsSeen).count
        add(.advisory, "stops.neverServed", stopsNeverServed,
            "\(stopsNeverServed) stops are never served by any trip")

        // --- Monotonic times within a trip.
        var nonMonotonic = 0
        var previousTrip: TripID?
        var previousDeparture = Int.min
        for st in feed.stopTimes {
            if st.tripID == previousTrip, st.arrival.secondsSinceServiceDayStart < previousDeparture {
                nonMonotonic += 1
            }
            previousTrip = st.tripID
            previousDeparture = st.departure.secondsSinceServiceDayStart
        }
        add(.advisory, "stopTimes.nonMonotonic", nonMonotonic,
            "\(nonMonotonic) stop times go backwards within their trip")

        // --- Ghost routes. The feed carries 16 of these; showing them would reproduce
        //     exactly the "lineas fantasma" complaint about the official app.
        let routesWithTrips = Set(feed.trips.map(\.routeID))
        let ghostRoutes = routeIDs.subtracting(routesWithTrips).count
        add(.advisory, "routes.withoutTrips", ghostRoutes,
            "\(ghostRoutes) routes have no trips in this feed and must be hidden from the UI")

        // --- Stops with no realtime identifier.
        let noCode = feed.stops.filter { $0.vitrasaCode == nil }.count
        add(.advisory, "stops.withoutVitrasaCode", noCode,
            "\(noCode) stops have no usable stop_code and cannot show live arrivals")

        // --- Coordinate sanity, loosely bounded on the Vigo area.
        let outOfBox = feed.stops.filter {
            !((41.5...42.7).contains($0.latitude) && (-9.5...(-8.0)).contains($0.longitude))
        }.count
        add(.advisory, "stops.coordinatesOutsideVigo", outOfBox,
            "\(outOfBox) stops fall outside the Vigo bounding box")

        // --- Service window. A feed that has already expired is worse than useless:
        //     it would silently answer "no service" for every query.
        let window = feed.serviceWindow
        if let window {
            let days = feed.calendarDates.isEmpty ? 0 : Set(feed.calendarDates.map(\.date)).count
            if days > 0 && days <= 8 {
                add(.advisory, "calendar.shortWindow", days,
                    "feed only covers \(days) day(s), \(window.lowerBound)–\(window.upperBound); it will expire quickly")
            }
        } else {
            add(.blocking, "calendar.noWindow", 1, "feed defines no dates at all")
        }

        if feed.calendar.isEmpty && !feed.calendarDates.isEmpty {
            add(.advisory, "calendar.datesOnly", 1,
                "calendar.txt is empty; all service comes from calendar_dates.txt")
        }

        return Report(
            findings: findings,
            stopCount: feed.stops.count,
            routeCount: feed.routes.count,
            routesWithTrips: routesWithTrips.count,
            tripCount: feed.trips.count,
            stopTimeCount: feed.stopTimes.count,
            shapePointCount: feed.shapePoints.count,
            serviceWindow: window,
            timesPastMidnight: pastMidnight,
            latestTime: latest)
    }
}
