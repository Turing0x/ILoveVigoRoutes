import Foundation

/// What the map draws for a journey already under way — the one the traveller said they
/// boarded (`ActiveJourneySnapshot`) or the bus they declared from the map (`OnboardRide`).
///
/// The planner's alternatives are drawn from live `Journey` values that only exist while the
/// route sheet is open. A journey under way outlives that sheet, and the app, so it is drawn
/// from what was persisted instead. Deciding *what* to draw is this pure value; reading the
/// shapes is the app's job, because that needs SQLite and a map.
public struct RideTracePlan: Sendable, Hashable {

    public struct Ride: Sendable, Hashable {
        /// For the shape. May no longer resolve after a reimport, which is what `stopPath` is for.
        public let tripID: TripID?
        public let board: Coordinate
        public let alight: Coordinate
        /// Boarding stop, every stop in between, alighting stop, in riding order. Drawn when
        /// there is no shape: stop to stop, which is honest about what is known, rather than a
        /// street route nobody measured.
        public let stopPath: [Coordinate]
        public let boardName: String
        public let alightName: String

        public init(tripID: TripID?, board: Coordinate, alight: Coordinate,
                    stopPath: [Coordinate], boardName: String, alightName: String) {
            self.tripID = tripID; self.board = board; self.alight = alight
            self.stopPath = stopPath; self.boardName = boardName; self.alightName = alightName
        }
    }

    public struct Walk: Sendable, Hashable {
        public let from: Coordinate
        public let to: Coordinate
    }

    public let rides: [Ride]
    /// From the last alighting stop to the destination, when there is a walk left at all.
    public let egressWalk: Walk?
    /// Where the journey ends, when it ends somewhere other than the last alighting stop.
    public let destination: Coordinate?

    public init(rides: [Ride], egressWalk: Walk?, destination: Coordinate?) {
        self.rides = rides; self.egressWalk = egressWalk; self.destination = destination
    }

    /// Everything the camera must fit.
    public var keyCoordinates: [Coordinate] {
        rides.flatMap(\.stopPath) + [egressWalk?.to, destination].compactMap { $0 }
    }
}

extension RideTracePlan {

    /// The journey the traveller boarded from a planned route. The access walk is not drawn:
    /// the snapshot does not keep where it started, and whoever pressed "He subido" is past it.
    public init(_ snapshot: ActiveJourneySnapshot) {
        let rides = snapshot.rides.map { ride in
            Ride(tripID: ride.tripID, board: ride.board.coordinate, alight: ride.alight.coordinate,
                 stopPath: [ride.board.coordinate] + ride.intermediate.map(\.coordinate)
                    + [ride.alight.coordinate],
                 boardName: ride.board.name, alightName: ride.alight.name)
        }
        let destination = snapshot.destination.coordinate
        let lastAlight = rides.last?.alight
        // A destination that *is* the alighting stop has no walk left, whatever the snapshot's
        // seconds say once they are rounded — and no separate flag to plant on the same spot.
        let endsElsewhere = lastAlight.map { $0 != destination } ?? true
        let walk: Walk? = if snapshot.egressWalkSeconds > 0, endsElsewhere, let lastAlight {
            Walk(from: lastAlight, to: destination)
        } else {
            nil
        }
        self.init(rides: rides, egressWalk: walk, destination: endsElsewhere ? destination : nil)
    }

    /// What is left of a declared bus: from the last stop the traveller is known to have
    /// reached to the end of its pattern. Shrinks as the ride advances.
    ///
    /// Stops that have vanished from the feed are skipped rather than drawn at a guessed
    /// position. `nil` when fewer than two stops remain — there is no line to draw.
    public init?(_ ride: OnboardRide, stops: (StopID) -> Stop?) {
        guard ride.patternStopIDs.indices.contains(ride.currentPosition) else { return nil }
        let remaining = ride.patternStopIDs[ride.currentPosition...].compactMap(stops)
        guard remaining.count >= 2, let first = remaining.first, let last = remaining.last else {
            return nil
        }
        self.init(rides: [Ride(tripID: ride.tripID, board: Coordinate(first),
                               alight: Coordinate(last),
                               stopPath: remaining.map { Coordinate($0) },
                               boardName: first.name, alightName: last.name)],
                  egressWalk: nil, destination: nil)
    }
}
