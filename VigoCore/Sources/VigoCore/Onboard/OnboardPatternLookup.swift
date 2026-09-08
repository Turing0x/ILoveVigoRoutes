import Foundation

/// The lookups an onboard query needs and `Timetable` deliberately does not carry.
///
/// `Timetable` is `Sendable` and immutable by design — it holds flat arrays laid out for
/// RAPTOR's inner loop, not indexes for occasional questions. Building the one reverse index
/// this feature needs (line name → patterns) costs a pass over a few hundred patterns, once
/// per onboard query, which is nothing next to a search. Keeping it here rather than growing
/// `Timetable` also keeps every function below a pure function of its arguments.
enum OnboardPatternLookup {

    /// Patterns whose `route_short_name` folds to `line`, in index order.
    static func patterns(forLine line: String, in timetable: Timetable) -> [Int] {
        let wanted = TextNormalization.normalizedLineName(line)
        var found: [Int] = []
        for pattern in 0..<timetable.patternCount
        where TextNormalization.normalizedLineName(timetable.patternRouteShortName[pattern]) == wanted {
            found.append(pattern)
        }
        return found
    }

    /// The pattern's stops, in order, as feed identifiers — the fingerprint stored in an
    /// `OnboardRide`.
    static func stopIDs(ofPattern pattern: Int, in timetable: Timetable) -> [StopID] {
        (0..<timetable.stopCount(ofPattern: pattern)).map { position in
            timetable.stops[Int(timetable.stopIndex(pattern: pattern, position: position))].id
        }
    }

    /// Metres between a coordinate and the stop at a pattern position.
    static func metres(from coordinate: Coordinate, toPosition position: Int,
                       ofPattern pattern: Int, in timetable: Timetable) -> Double {
        let stop = timetable.stops[Int(timetable.stopIndex(pattern: pattern, position: position))]
        return TransitRepository.haversineMetres(coordinate.latitude, coordinate.longitude,
                                                 stop.latitude, stop.longitude)
    }

    /// Trips of `pattern` scheduled through `position` inside `[now - late, now + early]`.
    ///
    /// A linear scan bounded by the window rather than a binary search: trips of a pattern are
    /// ordered by time at every position (the property `TimetableBuilder` splits patterns to
    /// preserve), so the window is a contiguous run, and a pattern's trip list is small enough
    /// that finding its ends by scanning costs less than the code to not scan.
    static func trips(ofPattern pattern: Int, through position: Int, in timetable: Timetable,
                      nowAxis: Int32, late: Int32, early: Int32) -> [Int] {
        var found: [Int] = []
        for trip in 0..<timetable.tripCount(ofPattern: pattern) {
            let scheduled = timetable.departure(pattern: pattern, trip: trip, position: position)
            if scheduled < nowAxis &- late { continue }
            if scheduled > nowAxis &+ early { break }
            found.append(trip)
        }
        return found
    }
}
