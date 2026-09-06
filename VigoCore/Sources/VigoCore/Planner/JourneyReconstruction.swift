import Foundation

/// Turns a `RaptorResult` into `Journey` values.
///
/// Two passes. First, the parent pointers are walked backwards from a chosen egress stop
/// into a forward chain of legs — RAPTOR's own earliest-arrival search, which boards the
/// first catchable trip at every stage. Second, a backward-fit pass swaps each ride for the
/// **latest** trip of the same pattern that still keeps every downstream connection: without
/// it the first leg boards needlessly early, because "earliest arrival overall" says nothing
/// about when the *first* vehicle has to leave.
public enum JourneyReconstruction {

    /// One alternative per round that actually improved the arrival at the destination —
    /// already a Pareto front, since a later round is only kept here when it bought an
    /// earlier arrival for one more transfer. Filtered so an extra transfer must save at
    /// least `options.extraTransferWorthSeconds` over the last alternative kept, sorted
    /// soonest-arrival first, capped at `options.maxAlternatives`.
    ///
    /// Every journey returned here leaves at the same time: rounds vary the vehicles taken,
    /// not the departure. Offering "the next bus" as well is `JourneyPlanner`'s job, which
    /// calls this once per departure it scans.
    public static func alternatives(
        timetable: Timetable, result: RaptorResult, query: RaptorQuery,
        origin: Place, destination: Place, options: PlannerOptions
    ) -> [Journey] {
        guard result.roundsRun >= 1 else { return [] }
        let walk = WalkModel(options: options)

        func build(_ candidate: EgressCandidate) -> Journey? {
            reconstruct(
                timetable: timetable, result: result, round: candidate.round,
                egressStop: candidate.stop, egressSeconds: candidate.seconds,
                origin: origin, destination: destination, options: options, walk: walk)
        }

        // The chain that already existed: one journey per round that improved the arrival,
        // fastest way out each time, filtered so an extra transfer has to be worth it.
        var byTransfersAscending: [Journey] = []
        // Everything else on the egress front: the stops that trade arrival for a shorter walk.
        var closerOnFoot: [Journey] = []
        var seenExits = Set<EgressCandidate>()
        var lastRound = -1

        for round in 1...result.roundsRun {
            let candidates = egressCandidates(upTo: round, result: result, query: query,
                                              limit: options.maxEgressCandidates)
            guard let fastest = candidates.first else { continue }

            if fastest.round != lastRound, let journey = build(fastest) {
                lastRound = fastest.round
                byTransfersAscending.append(journey)
                seenExits.insert(fastest)
            }

            // The rest bypass the transfer filter below on purpose. That filter answers "is
            // one more change of bus worth it", which is not the question these candidates
            // pose; whether they earn a place is decided by `JourneyPlanner.ranked`, whose
            // dominance test knows about the final walk.
            for candidate in candidates.dropFirst() {
                guard seenExits.insert(candidate).inserted,
                      let journey = build(candidate) else { continue }
                closerOnFoot.append(journey)
            }
        }

        var kept: [Journey] = []
        for journey in byTransfersAscending {
            if let last = kept.last {
                let gained = last.arrival.timeIntervalSince(journey.arrival)
                guard gained >= TimeInterval(options.extraTransferWorthSeconds) else { continue }
            }
            kept.append(journey)
        }

        // Cut by `maxCandidates` and not by `maxAlternatives`: this is the pool the user's
        // ordering preference chooses from, not the list they see. `JourneyShortlist.cut`,
        // not a plain sort-by-arrival-then-prefix (H-04): the latter is the same bias by
        // arrival Fase 10 exists to remove, just moved one call earlier — `closerOnFoot`
        // candidates are by construction never the earliest to arrive, so a prefix-by-arrival
        // drops exactly the ones this whole mechanism exists to produce.
        return JourneyShortlist.cut(kept + closerOnFoot, to: options.maxCandidates)
    }

    /// One way out of the network: which stop to get off at, after how many vehicles, and
    /// what it costs on foot afterwards.
    ///
    /// `Hashable` on `(round, stop)` alone — that pair is the identity for deduplication
    /// across rounds (the same stop reached with the same number of vehicles reconstructs to
    /// the same journey), and `seconds`/`arrival` are derived from it, never independent of
    /// it. H-17: this replaces a hand-rolled `round &* 1_000_003 &+ stop` integer key, which
    /// collided above roughly 1.15 million patterns worth of round·stop space — nowhere near
    /// reachable at this feed's size, but a real `Hashable` costs nothing extra to get right.
    struct EgressCandidate: Hashable {
        let round: Int
        let stop: Int
        /// Seconds on foot from that stop to the real destination.
        let seconds: Int32
        /// Door-to-door arrival, this walk included.
        let arrival: Int32

        static func == (a: Self, b: Self) -> Bool { a.round == b.round && a.stop == b.stop }
        func hash(into hasher: inout Hasher) { hasher.combine(round); hasher.combine(stop) }
    }

    /// The ways out of the network worth reconstructing, using at most `round` vehicles.
    ///
    /// For each egress stop, the highest round `<= round` that improved it — arrivals only ever
    /// get better as rounds go on (`RaptorEngineTests.monotone`), so that is that round
    /// budget's best even if `round` itself did not touch the stop.
    ///
    /// **The Pareto front over (arrival, walk at the end), not the single fastest.** This is
    /// the change Fase 10 turns on. Picking only the stop with the earliest door-to-door
    /// arrival — which is what this did before — means a stop that drops you 100 m from the
    /// door but is reached three minutes later is never reconstructed at all. It is not
    /// filtered out downstream: it does not exist, and an ordering by "least walking" would
    /// have nothing of the sort to offer. A stop earns its place only by being unbeaten on one
    /// of the two axes.
    static func egressCandidates(
        upTo round: Int, result: RaptorResult, query: RaptorQuery, limit: Int
    ) -> [EgressCandidate] {
        var reachable: [EgressCandidate] = []
        for exit in query.egress {
            var r = round
            // Down to 1, not to 0: round 0 is "reachable from the origin without boarding
            // anything", which is the walk-only answer and `JourneyPlanner`'s business. Letting
            // it onto this front would put a candidate that cannot be reconstructed at its head
            // and, before Fase 10 filtered it out one level up, take the whole round with it.
            while r >= 1 {
                if let value = result.arrival(round: r, stop: Int(exit.stop)) {
                    reachable.append(EgressCandidate(round: r, stop: Int(exit.stop),
                                                     seconds: exit.seconds,
                                                     arrival: value &+ exit.seconds))
                    break
                }
                r -= 1
            }
        }

        let front = reachable.filter { candidate in
            !reachable.contains { other in
                other.arrival <= candidate.arrival && other.seconds <= candidate.seconds
                    && (other.arrival < candidate.arrival || other.seconds < candidate.seconds)
            }
        }
        // Ties on arrival are real — two egress stops equidistant from the door reached at
        // the same instant — and `Array.sorted` is not stable, so without a tiebreak two
        // builds of the same front could hand `trim` its ends in a different order (H-18).
        // The stop index is arbitrary but fixed, which is all a tiebreak needs to be.
        return trim(front.sorted { $0.arrival != $1.arrival ? $0.arrival < $1.arrival : $0.stop < $1.stop },
                   to: limit)
    }

    /// Cuts the front to `limit` **from both ends**, not from the front.
    ///
    /// The front comes sorted by arrival, so its head is the fastest way out and its tail is
    /// the shortest walk. Taking the first `limit` would drop the tail — which is precisely
    /// the candidate this whole mechanism exists to produce. Taking from alternating ends
    /// keeps both extremes whatever the limit is.
    private static func trim(_ front: [EgressCandidate], to limit: Int) -> [EgressCandidate] {
        guard front.count > limit else { return front }
        guard limit > 0 else { return [] }

        var picked: [EgressCandidate] = []
        var low = 0
        var high = front.count - 1
        var fromLow = true
        while picked.count < limit, low <= high {
            picked.append(front[fromLow ? low : high])
            if fromLow { low += 1 } else { high -= 1 }
            fromLow.toggle()
        }
        return picked.sorted { $0.arrival != $1.arrival ? $0.arrival < $1.arrival : $0.stop < $1.stop }
    }

    // MARK: - Forward reconstruction

    private struct Step {
        let stop: Int
        let parent: RaptorParent
    }

    private struct RideDraft {
        let pattern: Int
        var trip: Int
        let boardPosition: Int
        let alightPosition: Int
    }

    private enum Gap {
        case access(seconds: Int32)
        case sameStop
        case walk(seconds: Int32)
    }

    private static func reconstruct(
        timetable: Timetable, result: RaptorResult, round: Int,
        egressStop: Int, egressSeconds: Int32,
        origin: Place, destination: Place, options: PlannerOptions, walk: WalkModel
    ) -> Journey? {
        // MARK: walk the parents back to the access leg
        //
        // A `.walk(from: S)` step was computed from S's *ride* in this round (the snapshot
        // `RaptorEngine.run` takes before its footpath loop can overwrite anything), so it
        // is `result.rideParent`, not `result.parent`, that has to be read for S — its
        // current `parent` may since have been rewritten by an incoming walk of its own.
        // Reading the wrong one chains footpaths that the engine never actually chained.
        var chain: [Step] = []
        var currentRound = round
        var stop = egressStop
        var stepFollowedAWalk = false
        // No legitimate chain revisits a (round, stop) pair, so this bounds the walk even
        // if two parents ever pointed at each other — a cycle the loop below has no other
        // way to notice, since a `.walk` step does not advance `currentRound`.
        var stepsRemaining = (result.roundsRun + 2) * result.stopCount
        while let parent = stepFollowedAWalk
                ? result.rideParent(round: currentRound, stop: stop)
                : result.parent(round: currentRound, stop: stop) {
            guard stepsRemaining > 0 else { return nil }
            stepsRemaining -= 1
            chain.append(Step(stop: stop, parent: parent))
            stepFollowedAWalk = false
            switch parent {
            case .access:
                currentRound = -1
            case .ride(let pattern, _, let board, _):
                stop = Int(timetable.stopIndex(pattern: Int(pattern), position: Int(board)))
                currentRound -= 1
            case .walk(let from, _):
                stop = Int(from)
                stepFollowedAWalk = true
            }
            if currentRound < 0 { break }
        }
        chain.reverse()

        // MARK: pull out the rides and what precedes each of them
        var rides: [RideDraft] = []
        var gapsBeforeRide: [Gap] = []
        var pendingGap: Gap?
        for step in chain {
            switch step.parent {
            case .access(let seconds):
                pendingGap = .access(seconds: seconds)
            case .walk(_, let seconds):
                pendingGap = .walk(seconds: seconds)
            case .ride(let pattern, let trip, let board, let alight):
                rides.append(RideDraft(pattern: Int(pattern), trip: Int(trip),
                                       boardPosition: Int(board), alightPosition: Int(alight)))
                gapsBeforeRide.append(pendingGap ?? .sameStop)
                pendingGap = nil
            }
        }

        // A chain with no vehicle in it is not a journey this function can describe: it is
        // somewhere you can reach on foot, which is `JourneyPlanner`'s walk-only answer. It can
        // genuinely happen — a stop near the origin is also near the destination when the two
        // are close, and RAPTOR still records it as reached — and every line below assumes at
        // least one ride, starting with `rides[rides.count - 1]`.
        guard !rides.isEmpty else { return nil }

        // MARK: backward fit — from the fixed final arrival, the latest trip per ride that
        // still meets the connection already chosen for the leg after it.
        var limit = timetable.arrival(pattern: rides[rides.count - 1].pattern,
                                      trip: rides[rides.count - 1].trip,
                                      position: rides[rides.count - 1].alightPosition)
        for index in stride(from: rides.count - 1, through: 0, by: -1) {
            let ride = rides[index]
            // `latestTrip` cannot actually return `nil` here (H-14): `ride.trip` itself
            // already satisfies `arrival(..., ride.trip, ...) <= limit` — it is either the
            // last ride, whose own arrival *is* `limit`, or an earlier one whose connection
            // to the ride after it was already fixed to respect this same bound — so the
            // search always has at least `ride.trip` to find. `?? ride.trip` would make that
            // reasoning silent and untestable; this keeps the same fallback but says so.
            let latest: Int
            if let found = latestTrip(timetable, pattern: ride.pattern,
                                      position: ride.alightPosition, atMost: limit) {
                latest = found
            } else {
                assertionFailure("ride.trip already meets `limit`, so latestTrip must find at least it")
                latest = ride.trip
            }
            rides[index].trip = latest
            let boardTime = timetable.departure(pattern: ride.pattern, trip: latest,
                                                position: ride.boardPosition)
            switch gapsBeforeRide[index] {
            case .access:
                limit = boardTime
            case .sameStop:
                limit = boardTime &- Int32(options.minTransferSeconds)
            case .walk(let seconds):
                limit = boardTime &- Int32(options.footpathBufferSeconds) &- seconds
            }
        }

        // MARK: assemble legs, forward, using the fitted trips
        var legs: [JourneyLeg] = []
        var rideIndex = 0
        var accessDeparture: Int32 = 0
        for (index, step) in chain.enumerated() {
            switch step.parent {
            case .access(let seconds):
                let firstBoard = rides[0]
                let firstBoardTime = timetable.departure(
                    pattern: firstBoard.pattern, trip: firstBoard.trip, position: firstBoard.boardPosition)
                accessDeparture = firstBoardTime &- seconds
                legs.append(.walk(from: origin, to: .stop(timetable.stops[step.stop]),
                                  seconds: Int(seconds), metres: walk.metres(forSeconds: Int(seconds))))
            case .walk(_, let seconds):
                let source = chain[index - 1].stop
                legs.append(.walk(from: .stop(timetable.stops[source]),
                                  to: .stop(timetable.stops[step.stop]),
                                  seconds: Int(seconds), metres: walk.metres(forSeconds: Int(seconds))))
            case .ride:
                let ride = rides[rideIndex]
                rideIndex += 1
                let boardStop = chain[index - 1].stop
                let tripRef = timetable.tripRef(pattern: ride.pattern, trip: ride.trip)
                let departSeconds = timetable.departure(pattern: ride.pattern, trip: ride.trip,
                                                        position: ride.boardPosition)
                let arriveSeconds = timetable.arrival(pattern: ride.pattern, trip: ride.trip,
                                                      position: ride.alightPosition)
                let intermediate = ((ride.boardPosition + 1)..<ride.alightPosition).map {
                    timetable.stops[Int(timetable.stopIndex(pattern: ride.pattern, position: $0))]
                }
                legs.append(.ride(
                    routeID: timetable.patternRouteID[ride.pattern],
                    routeShortName: timetable.patternRouteShortName[ride.pattern],
                    headsign: tripRef.headsign, tripID: tripRef.tripID,
                    board: timetable.stops[boardStop], alight: timetable.stops[step.stop],
                    departure: timetable.date(forAxisSeconds: Int(departSeconds)),
                    arrival: timetable.date(forAxisSeconds: Int(arriveSeconds)),
                    intermediateStops: intermediate))
            }
        }
        legs.append(.walk(from: .stop(timetable.stops[egressStop]), to: destination,
                          seconds: Int(egressSeconds), metres: walk.metres(forSeconds: Int(egressSeconds))))

        let lastRide = rides[rides.count - 1]
        var networkArrival = timetable.arrival(pattern: lastRide.pattern, trip: lastRide.trip,
                                               position: lastRide.alightPosition)
        // The chain can end with a transfer walk when the chosen egress stop is one hop
        // from where the last vehicle actually lets the passenger off — `egressStop` and
        // the last ride's own alighting stop are not always the same stop. Every walking
        // step after the last ride is on the way to the door, and has to be counted:
        // leaving it out understates the arrival by exactly that walk, which is otherwise
        // invisible because the leg list drawn from `legs` already includes it.
        if let lastRideIndex = chain.lastIndex(where: {
            if case .ride = $0.parent { return true }; return false }) {
            for step in chain[(lastRideIndex + 1)...] {
                if case .walk(_, let seconds) = step.parent { networkArrival &+= seconds }
            }
        }
        return Journey(
            legs: legs,
            departure: timetable.date(forAxisSeconds: Int(accessDeparture)),
            arrival: timetable.date(forAxisSeconds: Int(networkArrival &+ egressSeconds)),
            transfers: rides.count - 1)
    }

    /// The trip of `pattern` with the **latest** arrival at `position` that is still
    /// `<= atMost`. Sound for the same reason `RaptorEngine`'s own binary search is: trips
    /// of a pattern never overtake one another, so arrival at a fixed position is monotone
    /// in trip index.
    private static func latestTrip(_ timetable: Timetable, pattern: Int, position: Int,
                                   atMost: Int32) -> Int? {
        let trips = timetable.tripCount(ofPattern: pattern)
        var low = 0, high = trips
        while low < high {
            let mid = (low + high) / 2
            if timetable.arrival(pattern: pattern, trip: mid, position: position) <= atMost {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? low - 1 : nil
    }
}
