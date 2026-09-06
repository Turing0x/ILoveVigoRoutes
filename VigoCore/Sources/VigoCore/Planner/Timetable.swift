import Foundation

/// One trip of a pattern, kept alongside the times so a journey can be traced back to the
/// GTFS row it came from.
public struct TripRef: Sendable, Hashable {
    public let tripID: TripID
    /// The service day this trip belongs to, which is not always the calendar day it runs
    /// on: a trip at `25:10:00` on Friday's service day runs at 01:10 on Saturday.
    public let serviceDate: ServiceDate
    /// Seconds added to the feed's service-day times to place them on the timetable's axis.
    public let dayOffsetSeconds: Int32
    public let headsign: String?

    public init(tripID: TripID, serviceDate: ServiceDate,
                dayOffsetSeconds: Int32, headsign: String?) {
        self.tripID = tripID; self.serviceDate = serviceDate
        self.dayOffsetSeconds = dayOffsetSeconds; self.headsign = headsign
    }
}

/// An immutable snapshot of everything RAPTOR needs, laid out for the search rather than
/// for storage.
///
/// **Why this is not a set of SQLite tables.** RAPTOR's "routes" are not the feed's
/// `route_id`s: they are *patterns*, maximal sets of trips that visit exactly the same
/// stops in the same order without overtaking one another. Materialising those would mean
/// touching the importer and adding a migration, to save a read that has to happen anyway.
/// Built in memory the whole thing costs about a megabyte.
///
/// **Why flat `Int32` arrays and not arrays of structs.** The inner loop of the algorithm
/// walks the times of one pattern in order, thousands of times per query. Contiguous
/// integers are the only thing that makes that loop cheap; a `[[StopTime]]` would spend
/// its life chasing pointers. The layout is CSR — an offsets array saying where each
/// pattern's data begins, and one flat data array behind it.
///
/// **Why `Int32` is safe here (H-16).** Every time on this axis is seconds relative to
/// `anchorMidnight`, folded from at most three service days (`TimetableBuilder`'s
/// yesterday/today/tomorrow) plus a GTFS time that may run past `30:00:00`. That bounds the
/// whole axis to roughly `[-1 day, +2 days]` in seconds — nowhere near `Int32`'s range —
/// which is what makes every `&+`/`&-` on these values in `RaptorEngine` and
/// `JourneyReconstruction` an optimisation rather than a risk: the wraparound they exist to
/// avoid the cost of checking for is not reachable from real data. Nothing enforces this
/// bound in code; `JourneyPlanner.scan` asserts it at the one place an external time (the
/// caller's requested departure) enters the axis.
public struct Timetable: Sendable {

    // MARK: - Stops

    /// The compact index space. Every `Int32` stop index elsewhere is a position here.
    ///
    /// The whole `Stop` is kept, not just its coordinates: journey reconstruction needs
    /// the name and the public code, and 1149 structs are not worth a second lookup path.
    public let stops: [Stop]
    public let stopIndexByID: [StopID: Int32]

    // MARK: - Patterns

    /// `patternStops[patternStopsOffset[p] ..< patternStopsOffset[p + 1]]` are the stop
    /// indices pattern `p` visits, in order. Length is `patternCount + 1`.
    public let patternStopsOffset: [Int32]
    public let patternStops: [Int32]

    /// `tripRefs[patternTripsOffset[p] ..< patternTripsOffset[p + 1]]` are the trips of
    /// pattern `p`, **sorted by departure time and guaranteed not to overtake**. That
    /// guarantee is what lets the engine binary-search for the first catchable trip.
    public let patternTripsOffset: [Int32]
    public let tripRefs: [TripRef]

    /// Times are pattern-major, then trip, then position:
    /// `patternTimesOffset[p] + localTrip * stopCount(p) + position`.
    /// Seconds on the anchor axis, so they may be negative or well past 86400.
    public let patternTimesOffset: [Int32]
    public let tripArrival: [Int32]
    public let tripDeparture: [Int32]

    public let patternRouteID: [RouteID]
    public let patternRouteShortName: [String]

    // MARK: - Inverse incidence

    /// Which patterns serve a stop, and at which position along them. This is the index
    /// RAPTOR scans at the start of every round.
    public let stopPatternsOffset: [Int32]
    public let stopPatternPattern: [Int32]
    public let stopPatternPosition: [Int32]

    // MARK: - Footpaths

    /// Transfer walks, CSR by origin stop index.
    public let footpathOffset: [Int32]
    public let footpathTarget: [Int32]
    public let footpathSeconds: [Int32]

    // MARK: - Provenance

    /// The day the time axis is measured from. Zero is midnight at the start of this day,
    /// in the agency's timezone.
    public let anchorDay: ServiceDate
    public let anchorMidnight: Date
    /// The service days actually folded into this snapshot, in order.
    public let coveredDays: [ServiceDate]
    /// The `importedAt` of the feed this was built from. A snapshot built before a refresh
    /// describes a timetable that no longer exists, and the cache key has to notice.
    public let feedFingerprint: Date?

    public init(
        stops: [Stop], stopIndexByID: [StopID: Int32],
        patternStopsOffset: [Int32], patternStops: [Int32],
        patternTripsOffset: [Int32], tripRefs: [TripRef],
        patternTimesOffset: [Int32], tripArrival: [Int32], tripDeparture: [Int32],
        patternRouteID: [RouteID], patternRouteShortName: [String],
        stopPatternsOffset: [Int32], stopPatternPattern: [Int32], stopPatternPosition: [Int32],
        footpathOffset: [Int32], footpathTarget: [Int32], footpathSeconds: [Int32],
        anchorDay: ServiceDate, anchorMidnight: Date,
        coveredDays: [ServiceDate], feedFingerprint: Date?
    ) {
        self.stops = stops; self.stopIndexByID = stopIndexByID
        self.patternStopsOffset = patternStopsOffset; self.patternStops = patternStops
        self.patternTripsOffset = patternTripsOffset; self.tripRefs = tripRefs
        self.patternTimesOffset = patternTimesOffset
        self.tripArrival = tripArrival; self.tripDeparture = tripDeparture
        self.patternRouteID = patternRouteID; self.patternRouteShortName = patternRouteShortName
        self.stopPatternsOffset = stopPatternsOffset
        self.stopPatternPattern = stopPatternPattern
        self.stopPatternPosition = stopPatternPosition
        self.footpathOffset = footpathOffset
        self.footpathTarget = footpathTarget
        self.footpathSeconds = footpathSeconds
        self.anchorDay = anchorDay; self.anchorMidnight = anchorMidnight
        self.coveredDays = coveredDays; self.feedFingerprint = feedFingerprint
    }

    // MARK: - Access

    public var stopCount: Int { stops.count }
    public var patternCount: Int { patternStopsOffset.count - 1 }
    public var tripCount: Int { tripRefs.count }

    @inlinable public func stopCount(ofPattern pattern: Int) -> Int {
        Int(patternStopsOffset[pattern + 1] - patternStopsOffset[pattern])
    }

    @inlinable public func stopIndex(pattern: Int, position: Int) -> Int32 {
        patternStops[Int(patternStopsOffset[pattern]) + position]
    }

    @inlinable public func tripCount(ofPattern pattern: Int) -> Int {
        Int(patternTripsOffset[pattern + 1] - patternTripsOffset[pattern])
    }

    /// `trip` is the trip's index **within the pattern**, not within `tripRefs`.
    @inlinable public func tripRef(pattern: Int, trip: Int) -> TripRef {
        tripRefs[Int(patternTripsOffset[pattern]) + trip]
    }

    @inlinable public func timeIndex(pattern: Int, trip: Int, position: Int) -> Int {
        Int(patternTimesOffset[pattern]) + trip * stopCount(ofPattern: pattern) + position
    }

    @inlinable public func arrival(pattern: Int, trip: Int, position: Int) -> Int32 {
        tripArrival[timeIndex(pattern: pattern, trip: trip, position: position)]
    }

    @inlinable public func departure(pattern: Int, trip: Int, position: Int) -> Int32 {
        tripDeparture[timeIndex(pattern: pattern, trip: trip, position: position)]
    }

    /// The `(pattern, position)` pairs serving a stop, as a range into
    /// `stopPatternPattern` and `stopPatternPosition`.
    @inlinable public func patternSlots(ofStop stop: Int) -> Range<Int> {
        Int(stopPatternsOffset[stop]) ..< Int(stopPatternsOffset[stop + 1])
    }

    @inlinable public func footpaths(fromStop stop: Int) -> Range<Int> {
        Int(footpathOffset[stop]) ..< Int(footpathOffset[stop + 1])
    }

    // MARK: - Time axis

    /// Seconds on the anchor axis for an absolute instant.
    public func axisSeconds(for date: Date) -> Int {
        Int(date.timeIntervalSince(anchorMidnight).rounded())
    }

    public func date(forAxisSeconds seconds: Int) -> Date {
        anchorMidnight.addingTimeInterval(TimeInterval(seconds))
    }

    /// The feed's own `HH:MM:SS` value behind an axis time, i.e. undoing the day shift.
    public func serviceTime(axisSeconds: Int, trip: TripRef) -> ServiceTime {
        ServiceTime(seconds: axisSeconds - Int(trip.dayOffsetSeconds))
    }

    public func index(of stop: StopID) -> Int32? { stopIndexByID[stop] }
}
