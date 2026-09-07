import Foundation
import GRDB

public enum TimetableError: Error, Sendable, Equatable {
    /// The anchor day could not be turned into a calendar date, which means the calendar
    /// or the date itself is malformed rather than that there is no service.
    case undatableAnchor(ServiceDate)
}

/// Builds a `Timetable` from the imported GTFS.
///
/// Reads the three service days around the anchor in one query each, folds them onto a
/// single time axis, and groups the trips into non-overtaking patterns. On the real feed
/// this touches roughly 190 000 rows and produces about a megabyte, which is why the
/// result is cached rather than rebuilt per query — see `TimetableStore`.
public struct TimetableBuilder: Sendable {
    public let repository: TransitRepository
    public let options: PlannerOptions
    /// Measured stop-to-stop walks. Defaults to the resource shipped with the package;
    /// injectable so a test can build a timetable over hand-made geometry without the real
    /// table's three thousand pairs quietly deciding the answer.
    public let footpaths: FootpathTable

    public init(repository: TransitRepository, options: PlannerOptions = PlannerOptions(),
                footpaths: FootpathTable = .bundled) {
        self.repository = repository
        self.options = options
        self.footpaths = footpaths
    }

    /// A trip as read from the database, before it is grouped into a pattern.
    ///
    /// Not `private`: `nonOvertakingGroups`/`overtakes` are pure functions of this type and
    /// nothing else, so `TimetableBuilderTests` can hand them hand-built values directly —
    /// the same reason `JourneyReconstruction.egressCandidates` is `internal` rather than
    /// `private`.
    struct RawTrip {
        let ref: TripRef
        let routeID: RouteID
        let stops: [Int32]
        /// Already shifted onto the anchor axis.
        let arrivals: [Int32]
        let departures: [Int32]
    }

    /// Route plus stop sequence. The route belongs in the key: two lines can happen to
    /// serve the same stops in the same order, and merging them would put a journey on
    /// the wrong bus.
    private struct PatternKey: Hashable {
        let routeID: RouteID
        let stops: [Int32]
    }

    public func build(anchor: ServiceDate) throws -> Timetable {
        let calendar = repository.calendar
        guard let anchorMidnight = anchor.startOfDay(in: calendar) else {
            throw TimetableError.undatableAnchor(anchor)
        }

        // Compact stop space, ordered by id so that two builds of the same feed produce
        // byte-identical arrays and a test can compare them.
        let stops = try repository.allStops().sorted { $0.id.rawValue < $1.id.rawValue }
        var stopIndexByID = [StopID: Int32](minimumCapacity: stops.count)
        for (index, stop) in stops.enumerated() { stopIndexByID[stop.id] = Int32(index) }

        var routeShortNames = [RouteID: String]()
        for route in try repository.routesWithService() { routeShortNames[route.id] = route.shortName }

        // MARK: Three service days on one axis
        //
        // Yesterday is needed for the trips that run past midnight, and tomorrow for a
        // query made late in the evening whose journey finishes after it. Both are folded
        // onto the anchor's axis rather than kept as separate days, because RAPTOR
        // compares times and cannot be asked to compare "25:10 on Friday" with
        // "01:15 on Saturday".
        var raws: [RawTrip] = []
        var covered: [ServiceDate] = []
        for dayShift in -1...1 {
            guard let day = anchor.adding(days: dayShift, calendar: calendar),
                  let midnight = day.startOfDay(in: calendar) else { continue }
            // The real distance between the two midnights, not a hardcoded 86400. Twice a
            // year consecutive midnights in Madrid are 23 or 25 hours apart, and an hour
            // of error would land squarely on the night lines.
            let offset = Int32(midnight.timeIntervalSince(anchorMidnight).rounded())

            let services = try repository.activeServiceIDs(on: day)
                .sorted { $0.rawValue < $1.rawValue }
            guard !services.isEmpty else { continue }

            covered.append(day)
            raws.append(contentsOf: try trips(
                on: day, services: services, offset: offset,
                onlyPastMidnight: dayShift < 0, stopIndexByID: stopIndexByID))
        }

        // MARK: Patterns

        var tripsByPattern = [PatternKey: [Int]]()
        for (index, raw) in raws.enumerated() {
            tripsByPattern[PatternKey(routeID: raw.routeID, stops: raw.stops), default: []]
                .append(index)
        }
        let orderedKeys = tripsByPattern.keys.sorted { a, b in
            if a.routeID.rawValue != b.routeID.rawValue {
                return a.routeID.rawValue < b.routeID.rawValue
            }
            return a.stops.lexicographicallyPrecedes(b.stops)
        }

        var patternStopsOffset: [Int32] = [0]
        var patternStops: [Int32] = []
        var patternTripsOffset: [Int32] = [0]
        var tripRefs: [TripRef] = []
        var patternTimesOffset: [Int32] = []
        var tripArrival: [Int32] = []
        var tripDeparture: [Int32] = []
        var patternRouteID: [RouteID] = []
        var patternRouteShortName: [String] = []

        for key in orderedKeys {
            let members = tripsByPattern[key]!.sorted { a, b in
                if raws[a].departures[0] != raws[b].departures[0] {
                    return raws[a].departures[0] < raws[b].departures[0]
                }
                return raws[a].ref.tripID.rawValue < raws[b].ref.tripID.rawValue
            }

            for group in Self.nonOvertakingGroups(members, in: raws) {
                patternStops.append(contentsOf: key.stops)
                patternStopsOffset.append(Int32(patternStops.count))
                patternTimesOffset.append(Int32(tripArrival.count))
                for member in group {
                    tripRefs.append(raws[member].ref)
                    tripArrival.append(contentsOf: raws[member].arrivals)
                    tripDeparture.append(contentsOf: raws[member].departures)
                }
                patternTripsOffset.append(Int32(tripRefs.count))
                patternRouteID.append(key.routeID)
                patternRouteShortName.append(routeShortNames[key.routeID] ?? key.routeID.rawValue)
            }
        }

        // MARK: Inverse incidence

        var slotsByStop = [[(pattern: Int32, position: Int32)]](
            repeating: [], count: stops.count)
        for pattern in 0..<(patternStopsOffset.count - 1) {
            let range = Int(patternStopsOffset[pattern]) ..< Int(patternStopsOffset[pattern + 1])
            for (position, stopIndex) in patternStops[range].enumerated() {
                slotsByStop[Int(stopIndex)].append((Int32(pattern), Int32(position)))
            }
        }
        var stopPatternsOffset: [Int32] = [0]
        var stopPatternPattern: [Int32] = []
        var stopPatternPosition: [Int32] = []
        for slots in slotsByStop {
            for slot in slots {
                stopPatternPattern.append(slot.pattern)
                stopPatternPosition.append(slot.position)
            }
            stopPatternsOffset.append(Int32(stopPatternPattern.count))
        }

        // MARK: Footpaths

        var pathsByOrigin = [[(target: Int32, seconds: Int32)]](repeating: [], count: stops.count)
        for path in WalkModel(options: options).footpaths(stops: stops, table: footpaths) {
            pathsByOrigin[Int(path.from)].append((path.to, path.seconds))
        }
        var footpathOffset: [Int32] = [0]
        var footpathTarget: [Int32] = []
        var footpathSeconds: [Int32] = []
        for paths in pathsByOrigin {
            for path in paths.sorted(by: { $0.target < $1.target }) {
                footpathTarget.append(path.target)
                footpathSeconds.append(path.seconds)
            }
            footpathOffset.append(Int32(footpathTarget.count))
        }

        return Timetable(
            stops: stops, stopIndexByID: stopIndexByID,
            patternStopsOffset: patternStopsOffset, patternStops: patternStops,
            patternTripsOffset: patternTripsOffset, tripRefs: tripRefs,
            patternTimesOffset: patternTimesOffset,
            tripArrival: tripArrival, tripDeparture: tripDeparture,
            patternRouteID: patternRouteID, patternRouteShortName: patternRouteShortName,
            stopPatternsOffset: stopPatternsOffset,
            stopPatternPattern: stopPatternPattern,
            stopPatternPosition: stopPatternPosition,
            footpathOffset: footpathOffset,
            footpathTarget: footpathTarget,
            footpathSeconds: footpathSeconds,
            anchorDay: anchor, anchorMidnight: anchorMidnight,
            coveredDays: covered,
            feedFingerprint: try repository.feedStatus().importedAt)
    }

    // MARK: - Reading

    /// The trips of one service day, shifted onto the anchor axis.
    ///
    /// Streamed with `fetchCursor` rather than `fetchAll`: the real feed has around
    /// 190 000 stop times across three days, and materialising them as `Row` objects only
    /// to walk them once is the difference between a megabyte and a hundred.
    private func trips(
        on day: ServiceDate, services: [ServiceID], offset: Int32,
        onlyPastMidnight: Bool, stopIndexByID: [StopID: Int32]
    ) throws -> [RawTrip] {
        try repository.database.writer.read { db -> [RawTrip] in
            var collected: [RawTrip] = []

            var currentID: String?
            var currentRoute: RouteID?
            var currentHeadsign: String?
            var stops: [Int32] = []
            var arrivals: [Int32] = []
            var departures: [Int32] = []
            var usable = true

            // A time that moves backwards along a trip is not something the forward sweep
            // in `RaptorEngine` can make sense of: it does not fail, it silently returns a
            // journey that is merely plausible. `GTFSValidator` checks this feed-wide at
            // import time (`DATA-SOURCES.md`: 0 non-monotonic sequences in the published
            // feed today), but that is a property of *this* feed, not a guarantee the reader
            // enforces — so it is repeated here, on data already in hand, at the cost of one
            // linear pass over arrays several orders of magnitude smaller than the feed.
            func isNonDecreasing(_ values: [Int32]) -> Bool {
                zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
            }

            func flush() {
                defer {
                    stops.removeAll(keepingCapacity: true)
                    arrivals.removeAll(keepingCapacity: true)
                    departures.removeAll(keepingCapacity: true)
                    usable = true
                }
                guard usable, let id = currentID, let route = currentRoute else { return }
                // One stop time is not a trip anyone can ride.
                guard stops.count >= 2, let lastArrival = arrivals.last,
                      let lastDeparture = departures.last else { return }
                // Same reasoning as the guard just above: half a trip is worse than none,
                // and so is one that runs backwards.
                guard isNonDecreasing(arrivals), isNonDecreasing(departures) else { return }
                if onlyPastMidnight {
                    // Yesterday only reaches today through the trips that run past
                    // midnight. Everything else on that day is already over.
                    guard max(lastArrival, lastDeparture) >= 86_400 else { return }
                }
                collected.append(RawTrip(
                    ref: TripRef(tripID: TripID(id), serviceDate: day,
                                 dayOffsetSeconds: offset, headsign: currentHeadsign),
                    routeID: route,
                    stops: stops,
                    arrivals: arrivals.map { $0 + offset },
                    departures: departures.map { $0 + offset }))
            }

            let cursor = try Row.fetchCursor(db, sql: """
                SELECT st.tripID AS tripID, st.stopID AS stopID,
                       st.arrival AS arrival, st.departure AS departure,
                       t.routeID AS routeID, t.headsign AS headsign
                FROM stopTime st
                JOIN trip t ON t.id = st.tripID
                WHERE t.serviceID IN (\(databaseQuestionMarks(count: services.count)))
                ORDER BY st.tripID, st.stopSequence
                """, arguments: StatementArguments(services.map(\.rawValue)))

            while let row = try cursor.next() {
                let tripID: String = row["tripID"]
                if tripID != currentID {
                    flush()
                    currentID = tripID
                    currentRoute = RouteID(row["routeID"] as String)
                    currentHeadsign = row["headsign"] as String?
                }
                guard let stopIndex = stopIndexByID[StopID(row["stopID"] as String)] else {
                    // A stop time pointing at a stop that is not in the feed. The importer
                    // rejects such a feed, so this is belt and braces — but half a trip is
                    // worse than none, so the whole trip goes.
                    usable = false
                    continue
                }
                stops.append(stopIndex)
                arrivals.append(Int32(row["arrival"] as Int))
                departures.append(Int32(row["departure"] as Int))
            }
            flush()

            return collected
        }
    }

    // MARK: - Overtaking

    /// Splits trips that share a stop sequence into groups within which no trip overtakes
    /// another.
    ///
    /// RAPTOR finds the earliest catchable trip of a pattern by binary search, which is
    /// only valid if the trips are ordered the same way at every stop. A pattern where one
    /// trip passes another silently returns journeys that are merely plausible — the kind
    /// of failure no example-based test catches, which is why the split happens here
    /// rather than being assumed away.
    ///
    /// `members` must already be sorted by departure at the first stop. Comparing a
    /// candidate against the last trip of a group is enough: the group is built in
    /// non-decreasing order, so dominating its last member dominates all of them.
    ///
    /// `static`, not an instance method: neither this nor `overtakes` touches `self`, and
    /// `internal` (not `private`) is what lets `TimetableBuilderTests` call it directly with
    /// hand-built `RawTrip` values instead of only ever exercising it through a full GTFS
    /// import — the same reasoning as `RawTrip`'s own visibility, just above.
    static func nonOvertakingGroups(_ members: [Int], in raws: [RawTrip]) -> [[Int]] {
        var groups: [[Int]] = []
        for member in members {
            var placed = false
            for index in groups.indices where !overtakes(raws[member], raws[groups[index].last!]) {
                groups[index].append(member)
                placed = true
                break
            }
            if !placed { groups.append([member]) }
        }
        return groups
    }

    static func overtakes(_ candidate: RawTrip, _ reference: RawTrip) -> Bool {
        for position in candidate.stops.indices {
            if candidate.arrivals[position] < reference.arrivals[position] { return true }
            if candidate.departures[position] < reference.departures[position] { return true }
        }
        return false
    }
}
