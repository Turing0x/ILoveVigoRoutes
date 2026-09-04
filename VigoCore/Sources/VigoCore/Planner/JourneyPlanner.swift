import Foundation

public struct PlanQuery: Sendable, Hashable {
    public let origin: Place
    public let destination: Place
    /// Earliest the journey may leave. "Salir ahora" is just `Date()` passed here.
    public let departure: Date

    public init(origin: Place, destination: Place, departure: Date) {
        self.origin = origin; self.destination = destination; self.departure = departure
    }
}

/// Every way `JourneyPlanner.plan` can honestly answer, success included.
///
/// The distinction between `outsideFeedWindow` and `noServiceOnDay` is load-bearing, not
/// pedantry: the feed only covers seven days, and "I have no data for that day" is a
/// different fact from "there is no service that day" — confusing the two is exactly the
/// kind of silent wrong answer this project's design explicitly rules out (`README.md`).
public enum PlanOutcome: Sendable {
    case journeys([Journey])
    /// Walking beats every bus alternative found (or none was found at all).
    case walkOnly(Journey)
    case noStopsNearOrigin(radiusMetres: Double)
    case noStopsNearDestination(radiusMetres: Double)
    case outsideFeedWindow(ClosedRange<ServiceDate>)
    case noServiceOnDay(ServiceDate)
    case noJourneyFound(horizon: TimeInterval)
    case noData
}

public struct PlanResult: Sendable {
    public let outcome: PlanOutcome
    public let feedStatus: FeedStatus
    public let computeDuration: TimeInterval
}

/// The public facade: resolves places to stops, checks the feed can answer the question at
/// all, runs RAPTOR against a cached `Timetable`, reconstructs and fits the alternatives,
/// and never lets a "no journey" answer look like a crash.
public struct JourneyPlanner: Sendable {
    let repository: TransitRepository
    let store: TimetableStore
    let options: PlannerOptions

    public init(repository: TransitRepository, store: TimetableStore,
                options: PlannerOptions = PlannerOptions()) {
        self.repository = repository
        self.store = store
        self.options = options
    }

    public func plan(_ query: PlanQuery) async throws -> PlanResult {
        let started = Date()
        let walk = WalkModel(options: options)

        func finish(_ outcome: PlanOutcome, feedStatus: FeedStatus) -> PlanResult {
            PlanResult(outcome: outcome, feedStatus: feedStatus,
                      computeDuration: Date().timeIntervalSince(started))
        }

        let feedStatus = try repository.feedStatus()
        guard feedStatus.hasData else { return finish(.noData, feedStatus: feedStatus) }

        let originCoordinate = query.origin.coordinate
        let destinationCoordinate = query.destination.coordinate
        let access = try repository.nearbyStops(
            latitude: originCoordinate.latitude, longitude: originCoordinate.longitude,
            radiusMetres: options.accessRadiusMetres)
        guard !access.isEmpty else {
            return finish(.noStopsNearOrigin(radiusMetres: options.accessRadiusMetres), feedStatus: feedStatus)
        }
        let egress = try repository.nearbyStops(
            latitude: destinationCoordinate.latitude, longitude: destinationCoordinate.longitude,
            radiusMetres: options.accessRadiusMetres)
        guard !egress.isEmpty else {
            return finish(.noStopsNearDestination(radiusMetres: options.accessRadiusMetres), feedStatus: feedStatus)
        }

        let day = ServiceDate(query.departure, calendar: repository.calendar)
        guard let window = feedStatus.window, window.contains(day) else {
            let reported = feedStatus.window ?? (day...day)
            return finish(.outsideFeedWindow(reported), feedStatus: feedStatus)
        }
        guard try !repository.activeServiceIDs(on: day).isEmpty else {
            return finish(.noServiceOnDay(day), feedStatus: feedStatus)
        }

        let timetable = try await store.timetable(anchor: day)
        let accessWalks = access.compactMap { nearby -> StopWalk? in
            guard let index = timetable.index(of: nearby.stop.id) else { return nil }
            return StopWalk(stop: index, seconds: Int32(walk.seconds(metres: nearby.distanceMetres)))
        }
        let egressWalks = egress.compactMap { nearby -> StopWalk? in
            guard let index = timetable.index(of: nearby.stop.id) else { return nil }
            return StopWalk(stop: index, seconds: Int32(walk.seconds(metres: nearby.distanceMetres)))
        }
        let raptorQuery = RaptorQuery(
            access: accessWalks, egress: egressWalks,
            departure: Int32(timetable.axisSeconds(for: query.departure)),
            horizon: Int32(options.searchHorizon))
        let result = RaptorEngine(options: options).run(timetable, raptorQuery)
        let alternatives = JourneyReconstruction.alternatives(
            timetable: timetable, result: result, query: raptorQuery,
            origin: query.origin, destination: query.destination, options: options)

        // A direct walk has no radius limit of its own, but one that would take longer than
        // the bus search is willing to look is not a "faster than the bus" fallback — it is
        // the same "nothing reasonable found" as an empty bus search.
        let directWalkSeconds = walk.seconds(from: originCoordinate, to: destinationCoordinate)
        let walkIsViable = TimeInterval(directWalkSeconds) <= options.searchHorizon
        func walkOnlyJourney() -> Journey {
            Journey(legs: [.walk(from: query.origin, to: query.destination,
                                 seconds: directWalkSeconds,
                                 metres: walk.metres(from: originCoordinate, to: destinationCoordinate))],
                    departure: query.departure,
                    arrival: query.departure.addingTimeInterval(TimeInterval(directWalkSeconds)),
                    transfers: 0)
        }

        guard let bestBus = alternatives.first else {
            guard walkIsViable else {
                return finish(.noJourneyFound(horizon: options.searchHorizon), feedStatus: feedStatus)
            }
            return finish(.walkOnly(walkOnlyJourney()), feedStatus: feedStatus)
        }
        if walkIsViable,
           query.departure.addingTimeInterval(TimeInterval(directWalkSeconds)) < bestBus.arrival {
            return finish(.walkOnly(walkOnlyJourney()), feedStatus: feedStatus)
        }
        return finish(.journeys(alternatives), feedStatus: feedStatus)
    }
}
