import Foundation

/// Matches the first bus a journey boards against what the realtime source is reporting at
/// that stop.
///
/// **Why this is a guess, and why it is bounded.** The realtime API has no notion of "this
/// specific scheduled trip": it answers with a line, a destination and a countdown from now.
/// Nothing in it can be joined to a GTFS `trip_id`. So the match is a heuristic — same line,
/// and of those the one whose implied absolute time sits closest to the departure the planner
/// already committed to — and it is accepted only inside a tolerance. Outside that window the
/// nearest arrival is almost certainly a different vehicle on the same line, and showing its
/// countdown next to this journey would be worse than showing nothing at all.
///
/// Pulled out of `JourneyDetailView`, where it was a private method, because the route list
/// now needs the same answer for up to four alternatives and two copies of a heuristic drift
/// apart exactly the way the two copies of `PlanOutcome`'s wording did.
///
/// Realtime **annotates and never decides**: no part of this feeds back into `RaptorEngine`.
/// That was settled in Fase 3 and is unchanged.
public enum FirstBoardingMatch {

    /// How far the realtime prediction may sit from the scheduled departure and still be
    /// believed to be the same bus.
    ///
    /// Fifteen minutes is wide enough to absorb ordinary lateness on a Vitrasa line and
    /// narrow enough that it cannot silently reach the *next* service on a frequent one.
    public static let defaultTolerance: TimeInterval = 15 * 60

    /// The arrival that is most likely the vehicle this leg boards, or `nil` when none is
    /// close enough to claim.
    ///
    /// - Parameters:
    ///   - now: passed in rather than read, so the caller's clock is the only clock and a
    ///     test does not depend on the hour it runs at.
    ///
    /// A query for a future date never matches, which is correct: the realtime source only
    /// knows about buses already approaching, so there is nothing for it to say about a
    /// journey tomorrow.
    public static func match(arrivals: [Arrival], routeShortName: String,
                             scheduledDeparture: Date, now: Date,
                             tolerance: TimeInterval = defaultTolerance) -> Arrival? {
        let line = TextNormalization.normalizedLineName(routeShortName)
        let candidates = arrivals.filter { $0.normalizedLine == line }
        guard let closest = candidates.min(by: {
            distance($0, from: scheduledDeparture, now: now)
                < distance($1, from: scheduledDeparture, now: now)
        }) else { return nil }
        guard distance(closest, from: scheduledDeparture, now: now) <= tolerance else { return nil }
        return closest
    }

    /// The line and boarding stop of a journey's first ride, or `nil` for a walk-only one.
    ///
    /// The *first* ride specifically: the realtime source only covers the stop the passenger
    /// is standing at, and claiming anything about a transfer two stops later would be a
    /// promise the timetable alone cannot keep.
    public static func firstRide(of journey: Journey)
        -> (routeShortName: String, board: Stop, departure: Date)? {
        for leg in journey.legs {
            if case .ride(_, let routeShortName, _, _, let board, _, let departure, _, _) = leg {
                return (routeShortName, board, departure)
            }
        }
        return nil
    }

    private static func distance(_ arrival: Arrival, from departure: Date, now: Date) -> TimeInterval {
        let implied = now.addingTimeInterval(TimeInterval(arrival.minutes * 60))
        return abs(implied.timeIntervalSince(departure))
    }
}
