import Foundation

/// One leg of a `Journey`: either on foot, or riding a single vehicle from one stop to
/// another of the same pattern.
public enum JourneyLeg: Sendable, Hashable {
    case walk(from: Place, to: Place, seconds: Int, metres: Double)
    case ride(routeID: RouteID, routeShortName: String, headsign: String?,
              tripID: TripID, board: Stop, alight: Stop,
              departure: Date, arrival: Date, intermediateStops: [Stop])
}

/// A complete door-to-door plan: the walk that gets the passenger into the network, zero or
/// more vehicles, the walk out at the end.
public struct Journey: Sendable, Hashable, Identifiable {
    public let legs: [JourneyLeg]
    public let departure: Date
    public let arrival: Date
    public let duration: TimeInterval
    /// Vehicles ridden, minus one. Zero for a direct ride.
    public let transfers: Int
    public let walkingSeconds: Int

    public init(legs: [JourneyLeg], departure: Date, arrival: Date, transfers: Int) {
        self.legs = legs; self.departure = departure; self.arrival = arrival
        self.duration = arrival.timeIntervalSince(departure)
        self.transfers = transfers
        self.walkingSeconds = legs.reduce(into: 0) { total, leg in
            if case .walk(_, _, let seconds, _) = leg { total += seconds }
        }
    }

    /// `Journey` is a value type built once per alternative, never mutated: identity by
    /// content is exactly what a test — or a `List` diffing alternatives after a re-plan —
    /// needs, and it costs nothing to add on top of `Hashable`.
    public var id: Self { self }
}
