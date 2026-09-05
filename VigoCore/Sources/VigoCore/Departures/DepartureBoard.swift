import Foundation

/// A day of one line's departures from one stop, arranged the way a timetable is read.
///
/// Pure, and in `VigoCore` rather than in the view, so the two decisions that are easy to get
/// wrong — which direction a departure belongs to, and which one is the next — are covered by
/// `swift test` on the Mac instead of by squinting at a device.
public struct DepartureBoard: Sendable, Equatable {

    /// One direction of the line, as it is signed on the front of the bus.
    public struct Direction: Sendable, Equatable, Identifiable {
        /// What the bus says it is going to. `ScheduledDeparture.destination` already falls
        /// back to the route's long name when a trip carries no headsign.
        public let destination: String
        public let departures: [ScheduledDeparture]
        /// Index of the first departure still to come, or `nil` when they have all gone.
        public let nextIndex: Int?

        public var id: String { destination }

        /// The next departure of this direction, if there is one left today.
        public var next: ScheduledDeparture? {
            guard let nextIndex, departures.indices.contains(nextIndex) else { return nil }
            return departures[nextIndex]
        }
    }

    public let directions: [Direction]

    public var isEmpty: Bool { directions.isEmpty }

    /// Groups a day of departures by direction and marks where "now" falls in each.
    ///
    /// **Split by direction and not merged into one column.** A stop is often served by both
    /// directions of the same line — usually as two posts across the road, but not always — and
    /// a single column of times mixing "towards Alcampo" with "towards the centre" is a table
    /// that means nothing. Splitting is the difference between a timetable and a list of
    /// numbers.
    ///
    /// Directions come out in the order their first departure happens, which is stable and
    /// needs no rule of its own; departures inside each keep the chronological order they
    /// arrive in.
    ///
    /// - Parameter now: passed in rather than read, for the reason the whole planner already
    ///   does it: a test that depends on the hour it runs at passes or fails by the clock.
    public static func build(_ departures: [ScheduledDeparture], now: Date) -> DepartureBoard {
        var order: [String] = []
        var grouped: [String: [ScheduledDeparture]] = [:]

        for departure in departures.sorted(by: { $0.absoluteDate < $1.absoluteDate }) {
            let key = departure.destination
            if grouped[key] == nil {
                grouped[key] = []
                order.append(key)
            }
            grouped[key]?.append(departure)
        }

        let directions = order.map { key -> Direction in
            let rows = grouped[key] ?? []
            // The first one still to come, not the first one there is. At 20:00 the head of
            // the list is the 06:00 bus, and pointing at it would be pointing at yesterday.
            let next = rows.firstIndex { $0.absoluteDate >= now }
            return Direction(destination: key, departures: rows, nextIndex: next)
        }
        return DepartureBoard(directions: directions)
    }
}
