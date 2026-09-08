import Foundation

/// "I am on this bus. Does it get me to X, and if not, where do I get off?"
///
/// A sibling of `PlanQuery`, not a variant of it: the origin is not a place the traveller can
/// walk from, it is a vehicle in motion. There is no departure time to choose either — the bus
/// leaves when it leaves, and the only clock that matters is now.
public struct OnboardQuery: Sendable, Hashable {
    public let ride: OnboardRide
    public let destination: Place
    public let now: Date
    public let accessibility: AccessibilityProfile

    public init(ride: OnboardRide, destination: Place, now: Date,
                accessibility: AccessibilityProfile = .standard) {
        self.ride = ride; self.destination = destination
        self.now = now; self.accessibility = accessibility
    }
}

extension JourneyPlanner {

    /// Plans from a bus already boarded.
    ///
    /// **What it shares with `plan`**: the feed checks, the service-day resolution and its
    /// projected/observed labelling, the timetable snapshot, the egress side of the walking
    /// layer, and the shortlist. **What it deliberately does not share**:
    ///
    /// - *The access walk.* There is none. `RaptorQuery.onboard` replaces it, which is what
    ///   keeps the answer honest: from inside a moving bus the only way into the rest of the
    ///   network is a stop this bus has not reached yet, and a plain search from the
    ///   traveller's coordinates would happily propose boarding another line at a stop this
    ///   one drives straight past.
    /// - *The departure scan.* `plan` runs RAPTOR several times, each pass forced onto a later
    ///   first vehicle, because "this bus or the next one" is the real choice at a stop. On
    ///   board there is no next one: the first vehicle is given. One pass.
    ///
    /// The direct answer — this bus reaches the destination, no changes — is pinned at the head
    /// of the list rather than left to the shortlist. It is the question that was asked, and a
    /// one-transfer alternative arriving a few minutes earlier must not be allowed to push it
    /// out of the pool.
    public func planOnboard(_ query: OnboardQuery) async throws -> PlanResult {
        let started = Date()
        var options = self.options
        options.accessibility = query.accessibility
        let walk = WalkModel(options: options)

        func finish(_ outcome: PlanOutcome, feedStatus: FeedStatus,
                    schedule: ServiceDaySource = .observed) -> PlanResult {
            PlanResult(outcome: outcome, feedStatus: feedStatus,
                       computeDuration: Date().timeIntervalSince(started), schedule: schedule)
        }

        let feedStatus = try repository.feedStatus()
        guard feedStatus.hasData else { return finish(.noData, feedStatus: feedStatus) }

        let destinationCoordinate = query.destination.coordinate
        // Not refused here the way `plan` refuses it. "No stop near the destination" is not an
        // answer to somebody already on a bus heading that way: the fallback below can still
        // tell them where to get off and how far they would have to walk. It only becomes the
        // answer when even that comes to nothing.
        let egress = try repository.nearbyStops(
            latitude: destinationCoordinate.latitude, longitude: destinationCoordinate.longitude,
            radiusMetres: options.accessRadiusMetres, limit: options.maxNearbyStops)

        let day = ServiceDate(query.now, calendar: repository.calendar)
        let resolver = try repository.serviceDayResolver(
            holidays: holidays, maxProjectionDays: options.maxProjectionDays)
        guard let resolved = resolver.resolve(day) else {
            if let window = feedStatus.window, window.contains(day) {
                return finish(.noServiceOnDay(day), feedStatus: feedStatus)
            }
            return finish(.outsideFeedWindow(feedStatus.window ?? (day...day)), feedStatus: feedStatus)
        }
        guard try !repository.activeServiceIDs(on: resolved.template).isEmpty else {
            return finish(.noServiceOnDay(day), feedStatus: feedStatus)
        }
        let schedule = resolved.source

        let timetable = try await store.timetable(anchor: day, profile: query.accessibility)
        let ride: ResolvedOnboardRide
        switch OnboardRideResolution.resolve(query.ride, in: timetable, now: query.now) {
        case .success(let resolvedRide): ride = resolvedRide
        case .failure(let failure):
            return finish(.onboardRideUnresolvable(failure), feedStatus: feedStatus,
                          schedule: schedule)
        }

        let egressWalks = egress.compactMap { nearby -> StopWalk? in
            guard let index = timetable.index(of: nearby.stop.id) else { return nil }
            return StopWalk(stop: index,
                            seconds: Int32(walk.seconds(metres: nearby.distanceMetres,
                                                        as: .accessEgress)))
        }

        let seed = OnboardSeed(pattern: Int32(ride.pattern), trip: Int32(ride.trip),
                               boardPosition: Int32(ride.currentPosition),
                               delaySeconds: ride.delaySeconds)
        let departure = Int32(timetable.axisSeconds(for: query.now))
        let raptorQuery = RaptorQuery(access: [], egress: egressWalks, departure: departure,
                                      horizon: Int32(options.searchHorizon), onboard: seed)

        // Same reason `plan` detaches: RAPTOR is pure CPU with no suspension point inside it,
        // and this is called from the main actor.
        let origin = Place.stop(timetable.stops[Int(timetable.stopIndex(
            pattern: ride.pattern, position: ride.currentPosition))])
        var alternatives: [Journey] = []
        // Skipped outright with no egress stop: RAPTOR would have nothing to prune against and
        // nothing to reconstruct, and the fallback below is the whole answer.
        if !egressWalks.isEmpty {
            alternatives = try await Task.detached(priority: .userInitiated) {
                let result = RaptorEngine(options: options).run(timetable, raptorQuery)
                return JourneyReconstruction.alternatives(
                    timetable: timetable, result: result, query: raptorQuery,
                    origin: origin, destination: query.destination, options: options)
            }.value
        }

        guard !alternatives.isEmpty else {
            // Nothing the network can do from here. Getting off at whichever stop of this bus
            // puts the traveller at the door soonest is still an answer, and it is one only
            // this ride can give — unlike `plan`'s walk-only fallback, it never proposes
            // abandoning the bus where it stands.
            if let fallback = OnboardWalkFallback.candidate(
                seed: seed, ride: ride, destination: query.destination,
                timetable: timetable, options: options, walk: walk) {
                return finish(.journeys([fallback]), feedStatus: feedStatus, schedule: schedule)
            }
            guard !egressWalks.isEmpty else {
                return finish(.noStopsNearDestination(radiusMetres: options.accessRadiusMetres),
                              feedStatus: feedStatus, schedule: schedule)
            }
            return finish(.noJourneyFound(horizon: options.searchHorizon), feedStatus: feedStatus,
                          schedule: schedule)
        }

        // No walk-only candidate is folded in here, unlike `plan`. Every onboard alternative
        // begins with the bus the traveller is on, so they all compete on the same axes; a
        // "forget the bus and walk" journey departing now would tie or win on
        // `JourneyShortlist.undominated`'s departure and boarding axes against every one of
        // them and sit on the list permanently.
        let direct = alternatives.first { $0.transfers == 0 }
        let rest = JourneyShortlist.cut(
            JourneyShortlist.plausible(
                JourneyShortlist.undominated(alternatives.filter { $0 != direct }),
                slack: options.alternativeSlackSeconds),
            to: options.maxCandidates)
        return finish(.journeys([direct].compactMap { $0 } + rest),
                      feedStatus: feedStatus, schedule: schedule)
    }
}

/// "Get off at the best stop this bus still calls at, and walk the rest."
///
/// Only reached when RAPTOR found nothing at all, which means no stop of this ride is inside
/// the destination's walking radius and no connection helps either. The answer it gives is
/// still worth having — a fifteen-minute walk beats "no journey found" when the traveller is
/// already halfway there — and it is bounded by the same search horizon, so it never proposes
/// an hour on foot.
///
/// The stop it picks is the one that puts the traveller **at the door soonest**, not the one
/// physically nearest: staying on for two more stops to save five minutes of walking is worth
/// it, and riding ten minutes past the door to shave two hundred metres is not.
enum OnboardWalkFallback {
    static func candidate(seed: OnboardSeed, ride: ResolvedOnboardRide, destination: Place,
                          timetable: Timetable, options: PlannerOptions,
                          walk: WalkModel) -> Journey? {
        let pattern = ride.pattern
        let positions = timetable.stopCount(ofPattern: pattern)
        guard ride.currentPosition + 1 < positions else { return nil }

        var best: (position: Int, arrival: Int32, walkSeconds: Int, total: Int32)?
        for position in (ride.currentPosition + 1)..<positions {
            let stop = timetable.stops[Int(timetable.stopIndex(pattern: pattern, position: position))]
            let seconds = walk.seconds(from: Coordinate(stop), to: destination.coordinate,
                                       as: .accessEgress)
            guard TimeInterval(seconds) <= options.searchHorizon else { continue }
            let arrival = timetable.arrival(pattern: pattern, trip: ride.trip, position: position)
                &+ seed.delaySeconds
            let total = arrival &+ Int32(seconds)
            if best == nil || total < best!.total {
                best = (position, arrival, seconds, total)
            }
        }
        guard let best else { return nil }

        let boardStop = timetable.stops[Int(timetable.stopIndex(pattern: pattern,
                                                                position: ride.currentPosition))]
        let alightStop = timetable.stops[Int(timetable.stopIndex(pattern: pattern,
                                                                 position: best.position))]
        let tripRef = timetable.tripRef(pattern: pattern, trip: ride.trip)
        let departure = timetable.departure(pattern: pattern, trip: ride.trip,
                                            position: ride.currentPosition) &+ seed.delaySeconds
        let intermediate = ((ride.currentPosition + 1)..<best.position).map {
            timetable.stops[Int(timetable.stopIndex(pattern: pattern, position: $0))]
        }
        return Journey(
            legs: [
                .ride(routeID: timetable.patternRouteID[pattern],
                      routeShortName: timetable.patternRouteShortName[pattern],
                      headsign: tripRef.headsign, tripID: tripRef.tripID,
                      board: boardStop, alight: alightStop,
                      departure: timetable.date(forAxisSeconds: Int(departure)),
                      arrival: timetable.date(forAxisSeconds: Int(best.arrival)),
                      intermediateStops: intermediate),
                .walk(from: .stop(alightStop), to: destination, seconds: best.walkSeconds,
                      metres: walk.metres(from: Coordinate(alightStop),
                                          to: destination.coordinate)),
            ],
            departure: timetable.date(forAxisSeconds: Int(departure)),
            arrival: timetable.date(forAxisSeconds: Int(best.total)),
            transfers: 0)
    }
}
