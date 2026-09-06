import Foundation

/// A stop reachable on foot from the origin, or from which the destination is reachable
/// on foot, with the walking time it costs.
public struct StopWalk: Sendable, Hashable {
    public let stop: Int32
    public let seconds: Int32

    public init(stop: Int32, seconds: Int32) {
        self.stop = stop; self.seconds = seconds
    }
}

public struct RaptorQuery: Sendable, Hashable {
    /// Where the journey can enter the network, already resolved to stop indices.
    public let access: [StopWalk]
    /// Where it can leave it. Used only for target pruning; the engine does not decide
    /// which one wins.
    public let egress: [StopWalk]
    /// Earliest departure from the origin, in seconds on the timetable's axis.
    public let departure: Int32
    /// How far past `departure` an arrival may fall before it stops being interesting.
    public let horizon: Int32

    public init(access: [StopWalk], egress: [StopWalk], departure: Int32, horizon: Int32) {
        self.access = access; self.egress = egress
        self.departure = departure; self.horizon = horizon
    }
}

/// How a stop's label in a given round was reached. Following these backwards rebuilds
/// the journey.
public enum RaptorParent: Sendable, Hashable {
    /// Walked into the network from the origin.
    case access(seconds: Int32)
    /// Rode a trip of a pattern. `trip` is the trip's index within the pattern.
    case ride(pattern: Int32, trip: Int32, boardPosition: Int32, alightPosition: Int32)
    /// Walked from another stop, within the same round.
    case walk(from: Int32, seconds: Int32)
}

public struct RaptorResult: Sendable {
    /// Unreachable, in every array below.
    public static let unreached = Int32.max

    public let stopCount: Int
    /// The highest round that improved anything. Rounds beyond it are empty.
    public let roundsRun: Int

    /// `(round, stop)` arrival labels, flattened. `unreached` where **that round** did not
    /// improve the stop — deliberately sparse rather than carried forward, see the note in
    /// `RaptorEngine`.
    public let arrival: [Int32]
    public let parent: [RaptorParent?]
    /// The best arrival at each stop over all rounds. This is what target pruning uses.
    public let bestArrival: [Int32]
    /// The `parent` a ridden stop had at the moment its ride arrival was fixed for this
    /// round — before the same round's footpath relaxation could overwrite it.
    ///
    /// `JourneyReconstruction` needs this alongside `parent`: a `.walk(from: S)` label was
    /// computed from `S`'s ride, using the value this array (not `parent`) still remembers.
    /// See the note on the `rideArrival` snapshot in `RaptorEngine.run`.
    public let rideParent: [RaptorParent?]

    @inlinable public func arrival(round: Int, stop: Int) -> Int32? {
        let value = arrival[round * stopCount + stop]
        return value == Self.unreached ? nil : value
    }

    @inlinable public func parent(round: Int, stop: Int) -> RaptorParent? {
        parent[round * stopCount + stop]
    }

    @inlinable public func rideParent(round: Int, stop: Int) -> RaptorParent? {
        rideParent[round * stopCount + stop]
    }
}

/// RAPTOR, rounds and all.
///
/// A pure function of `(Timetable, RaptorQuery)`: no clock, no network, no database.
/// Everything that makes it deterministic is what makes it checkable against a brute-force
/// reference, which is the only way to catch the failure mode this algorithm actually has
/// — answers that are plausible but not optimal.
///
/// Round `k` holds the best journeys using at most `k` vehicles, so the rounds are the
/// Pareto front over (arrival time, number of transfers) directly. That is why RAPTOR and
/// not CSA: the second dimension comes for free.
public struct RaptorEngine: Sendable {
    public let options: PlannerOptions

    public init(options: PlannerOptions = PlannerOptions()) {
        self.options = options
    }

    public func run(_ timetable: Timetable, _ query: RaptorQuery) -> RaptorResult {
        let stopCount = timetable.stopCount
        let rounds = max(1, options.maxRounds)
        let unreached = RaptorResult.unreached
        let minTransfer = Int32(options.minTransferSeconds)
        let footpathBuffer = Int32(options.footpathBufferSeconds)

        var arrival = [Int32](repeating: unreached, count: (rounds + 1) * stopCount)
        var parent = [RaptorParent?](repeating: nil, count: (rounds + 1) * stopCount)
        var rideParent = [RaptorParent?](repeating: nil, count: (rounds + 1) * stopCount)
        var bestArrival = [Int32](repeating: unreached, count: stopCount)
        // When a stop can be boarded, given the round it was reached in. Distinct from the
        // arrival label because a transfer costs slack that riding on does not.
        var ready = [Int32](repeating: unreached, count: (rounds + 1) * stopCount)

        // The horizon is the only pruning bound, which makes an impossible query cheap
        // instead of making it scan the whole network four times.
        //
        // It is deliberately *not* tightened further with the best door-to-door arrival
        // found so far (as it was before Fase 10's audit found H-03). That tightening is
        // only sound for a single scalar objective: it says "arriving this late cannot beat
        // the best full answer already found", which is true for earliest-arrival but false
        // once a shorter final walk is also a winning criterion — a stop reached later can
        // still be the "least walking" answer, and comparing its network arrival against a
        // bound baked from a *different* egress stop's own walk has no sound formula that
        // does not sometimes throw that candidate away before it is ever produced. See
        // `AUDITORIA-RAPTOR.md` H-03 for the instance that exposed it and why a same-shaped
        // fix belongs in `BruteForceReference`, which shares this rule on purpose.
        let targetBest = query.departure &+ query.horizon

        // MARK: Round 0 — walking into the network
        //
        // Footpaths are deliberately not relaxed here: the access radius is already the
        // walking layer, and letting it chain would allow walks of radius + 300 m.
        //
        // The other half of that trade-off (H-10, confidence medium — not reproduced against
        // real access/egress geometry): a stop reached only by a footpath *from* an access
        // point, and never by riding to it directly, is invisible to round 1 — its own
        // `bestArrival` is never set by round 0, so a ride that would otherwise alight there
        // in round 1 can be pruned by `targetBest` before it gets the chance. In practice
        // `JourneyPlanner` resolves access from `nearbyStops` on the same 800 m radius used
        // here, so a stop within a short footpath of an access point is almost always in the
        // access list too — this is believed to be latent on real queries, not observed.
        var marked = [Bool](repeating: false, count: stopCount)
        for entry in query.access {
            let stop = Int(entry.stop)
            let time = query.departure &+ entry.seconds
            guard time < targetBest, time < arrival[stop] else { continue }
            arrival[stop] = time
            ready[stop] = time              // no slack: this is the first boarding
            bestArrival[stop] = time
            parent[stop] = .access(seconds: entry.seconds)
            marked[stop] = true
        }

        var roundsRun = 0

        for round in 1...rounds {
            let base = round * stopCount
            let previous = (round - 1) * stopCount

            // MARK: 1 — the patterns worth scanning, from their earliest marked position
            var queue: [Int32: Int32] = [:]
            for stop in 0..<stopCount where marked[stop] {
                for slot in timetable.patternSlots(ofStop: stop) {
                    let pattern = timetable.stopPatternPattern[slot]
                    let position = timetable.stopPatternPosition[slot]
                    if let existing = queue[pattern] {
                        if position < existing { queue[pattern] = position }
                    } else {
                        queue[pattern] = position
                    }
                }
            }
            // Sorted so that a tie between two ways of reaching a stop resolves the same
            // way on every run: an ambiguous answer would be untestable.
            let scanOrder = queue.sorted { $0.key < $1.key }

            marked = [Bool](repeating: false, count: stopCount)
            var riddenStops: [Int] = []

            // MARK: 3 — sweep each pattern forwards
            for (patternKey, startPosition) in scanOrder {
                let pattern = Int(patternKey)
                let positions = timetable.stopCount(ofPattern: pattern)
                let trips = timetable.tripCount(ofPattern: pattern)
                var trip = -1
                var boardPosition = 0

                for position in Int(startPosition)..<positions {
                    let stop = Int(timetable.stopIndex(pattern: pattern, position: position))

                    if trip >= 0 {
                        let arrives = timetable.arrival(pattern: pattern, trip: trip, position: position)
                        if arrives < min(bestArrival[stop], targetBest) {
                            arrival[base + stop] = arrives
                            bestArrival[stop] = arrives
                            ready[base + stop] = arrives &+ minTransfer
                            parent[base + stop] = .ride(
                                pattern: patternKey, trip: Int32(trip),
                                boardPosition: Int32(boardPosition),
                                alightPosition: Int32(position))
                            if !marked[stop] { marked[stop] = true; riddenStops.append(stop) }
                        }
                    }

                    // Board here, or hop to an earlier trip of the same pattern. Only the
                    // previous round's label may board: arriving and departing in the same
                    // round would be riding two vehicles for the price of one.
                    let boardable = ready[previous + stop]
                    guard boardable != unreached else { continue }
                    let current = trip >= 0
                        ? timetable.departure(pattern: pattern, trip: trip, position: position)
                        : unreached
                    guard current > boardable else { continue }
                    // Valid because the builder guarantees the trips of a pattern do not
                    // overtake one another.
                    if let earlier = earliestTrip(timetable, pattern: pattern, position: position,
                                                  notBefore: boardable,
                                                  below: trip >= 0 ? trip : trips) {
                        trip = earlier
                        boardPosition = position
                    }
                }
            }

            // MARK: 4 — one walk per round, from the stops just alighted at
            //
            // Not iterated to a fixed point on purpose: straight-line footpaths obey the
            // triangle inequality, so chaining them can never beat the direct walk, and
            // capping it at one hop keeps a transfer from silently becoming a 900 m hike.
            //
            // The ride arrivals — and their parents — are snapshotted before this loop
            // writes anything: a walk into stop X can land before X's own turn as a source
            // comes up (X is in `riddenStops` too, just later in the list), and reading
            // `arrival[base + X]` live at that point would pick up the walk's result
            // instead of the ride's — turning "one hop" into two chained ones without
            // either loop noticing.
            //
            // The parent needs the same snapshot as the value, not just the value: once a
            // walk into X rewrites `parent[base + X]` to `.walk(from: ...)`, a later
            // outgoing walk that reads `rideArrival[X]` (X's ride, correctly) would still
            // chain onto X's now-overwritten `.walk` parent when the chain is later walked
            // backwards — two footpaths presented as one. `rideParent` is what
            // `JourneyReconstruction` follows instead, for exactly the stops this loop
            // uses as a walk source.
            var rideArrival: [Int: Int32] = [:]
            rideArrival.reserveCapacity(riddenStops.count)
            for stop in riddenStops {
                rideArrival[stop] = arrival[base + stop]
                rideParent[base + stop] = parent[base + stop]
            }

            for stop in riddenStops {
                let from = rideArrival[stop]!
                for slot in timetable.footpaths(fromStop: stop) {
                    let target = Int(timetable.footpathTarget[slot])
                    let seconds = timetable.footpathSeconds[slot]
                    let candidate = from &+ seconds
                    guard candidate < min(bestArrival[target], targetBest) else { continue }
                    arrival[base + target] = candidate
                    bestArrival[target] = candidate
                    ready[base + target] = candidate &+ footpathBuffer
                    parent[base + target] = .walk(from: Int32(stop), seconds: seconds)
                    marked[target] = true
                }
            }

            // MARK: 5
            if !marked.contains(true) { break }
            roundsRun = round
        }

        return RaptorResult(stopCount: stopCount, roundsRun: roundsRun,
                            arrival: arrival, parent: parent, bestArrival: bestArrival,
                            rideParent: rideParent)
    }

    /// First trip of `pattern` departing `position` at or after `notBefore`, searched in
    /// `0..<below`.
    ///
    /// Binary search is only sound because the pattern's trips are ordered identically at
    /// every position — the property `TimetableBuilder` splits patterns to preserve. The
    /// upper bound is the trip already boarded: only an earlier one can be an improvement.
    private func earliestTrip(
        _ timetable: Timetable, pattern: Int, position: Int,
        notBefore: Int32, below: Int
    ) -> Int? {
        var low = 0
        var high = below
        while low < high {
            let mid = (low + high) / 2
            if timetable.departure(pattern: pattern, trip: mid, position: position) >= notBefore {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low < below ? low : nil
    }
}
