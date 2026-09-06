import Foundation

/// A self-contained record of the journey the user is currently riding.
///
/// **Never replanned.** A `SavedJourney` is an origin-destination pair to plan again later;
/// this is the opposite — a specific bus already boarded. Replanning it on a cold relaunch
/// would be meaningless (you cannot switch buses mid-ride because something better turned up)
/// and would defeat the point of persisting it at all.
///
/// A `Codable` of its own, not `Journey` serialized: `Journey`/`JourneyLeg` are live
/// planner types that keep changing shape (Fase 10 just did), and a persisted blob tied to
/// their layout would turn every such refactor into a data migration.
///
/// Anchoring follows the rule Fase 4 already fixed for saved places: every stop is a
/// `stopID` **plus a fallback coordinate**, never a serialized `Stop`. `GTFSImporter` clears
/// and rewrites `stop` on each refresh, so a `Stop` frozen inside a blob could point at a
/// row that no longer exists — the fallback coordinate is what keeps the journey drawable
/// and its arrival announceable regardless.
public struct ActiveJourneySnapshot: Codable, Sendable, Hashable {
    public struct StopRef: Codable, Sendable, Hashable {
        /// `nil` when this end was never a stop in the feed — an address or a dropped pin.
        public let stopID: StopID?
        public let name: String
        public let latitude: Double
        public let longitude: Double

        public init(stopID: StopID?, name: String, latitude: Double, longitude: Double) {
            self.stopID = stopID; self.name = name
            self.latitude = latitude; self.longitude = longitude
        }

        public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

        static func from(_ stop: Stop) -> StopRef {
            StopRef(stopID: stop.id, name: stop.name, latitude: stop.latitude, longitude: stop.longitude)
        }

        static func from(_ place: Place, name: String) -> StopRef {
            let coordinate = place.coordinate
            let stopID: StopID? = if case .stop(let stop) = place { stop.id } else { nil }
            return StopRef(stopID: stopID, name: name,
                           latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    public struct Ride: Codable, Sendable, Hashable {
        public let routeShortName: String
        public let headsign: String?
        /// Informative only — a GTFS `trip_id` from the feed at boarding time, which the
        /// Fase 13 notification handler may find gone after a reimport. Nothing here depends
        /// on it resolving.
        public let tripID: TripID?
        public let board: StopRef
        public let alight: StopRef
        /// Needed by Fase 13 to answer "the stop before this one", for the pre-arrival notice.
        public let intermediate: [StopRef]
        public let scheduledDeparture: Date
        public let scheduledArrival: Date

        public init(routeShortName: String, headsign: String?, tripID: TripID?,
                    board: StopRef, alight: StopRef, intermediate: [StopRef],
                    scheduledDeparture: Date, scheduledArrival: Date) {
            self.routeShortName = routeShortName; self.headsign = headsign; self.tripID = tripID
            self.board = board; self.alight = alight; self.intermediate = intermediate
            self.scheduledDeparture = scheduledDeparture; self.scheduledArrival = scheduledArrival
        }
    }

    public let originName: String
    public let destination: StopRef
    public let rides: [Ride]
    public let egressWalkSeconds: Int
    public let scheduledDeparture: Date
    public let scheduledArrival: Date
    public let transfers: Int

    public init(originName: String, destination: StopRef, rides: [Ride], egressWalkSeconds: Int,
                scheduledDeparture: Date, scheduledArrival: Date, transfers: Int) {
        self.originName = originName; self.destination = destination; self.rides = rides
        self.egressWalkSeconds = egressWalkSeconds
        self.scheduledDeparture = scheduledDeparture; self.scheduledArrival = scheduledArrival
        self.transfers = transfers
    }

    /// - Parameters:
    ///   - originLabel: what to call the origin — the caller's own name ("Casa") rather than
    ///     whatever the first leg's `Place` happens to carry.
    ///   - destinationLabel: same, for the destination.
    public init(_ journey: Journey, originLabel: String, destinationLabel: String) {
        self.originName = originLabel
        self.egressWalkSeconds = JourneyOrdering.egressWalkSeconds(journey)
        self.scheduledDeparture = journey.departure
        self.scheduledArrival = journey.arrival
        self.transfers = journey.transfers

        var rides: [Ride] = []
        var lastPlace: Place?
        for leg in journey.legs {
            switch leg {
            case .walk(_, let to, _, _):
                lastPlace = to
            case .ride(_, let routeShortName, let headsign, let tripID, let board, let alight,
                       let departure, let arrival, let intermediateStops):
                rides.append(Ride(
                    routeShortName: routeShortName, headsign: headsign, tripID: tripID,
                    board: .from(board), alight: .from(alight),
                    intermediate: intermediateStops.map(StopRef.from),
                    scheduledDeparture: departure, scheduledArrival: arrival))
                lastPlace = .stop(alight)
            }
        }
        self.rides = rides
        // A journey always has at least one leg (`JourneyPlanner` never emits an empty one),
        // so `lastPlace` is set by the loop above.
        self.destination = .from(lastPlace ?? .coordinate(.init(latitude: 0, longitude: 0),
                                                           label: destinationLabel),
                                 name: destinationLabel)
    }
}

// MARK: - Staleness

public enum ActiveJourneyStaleness: Sendable, Hashable {
    case active
    case stale(since: Date)
}

extension ActiveJourneySnapshot {
    /// Pure: `now` comes in as a parameter, the same contract `FirstBoardingMatch.hasDeparted`
    /// already uses, so a test never depends on the hour it happens to run at.
    ///
    /// **Measured against `scheduledArrival`, not `scheduledDeparture`.** A long ride would
    /// otherwise go stale with the passenger still on board — the same distinction Fase 8's
    /// `hasDeparted` had to make between the boarding and the walk that precedes it.
    public func staleness(now: Date, grace: TimeInterval = 90 * 60) -> ActiveJourneyStaleness {
        let deadline = scheduledArrival.addingTimeInterval(grace)
        return now <= deadline ? .active : .stale(since: deadline)
    }
}
