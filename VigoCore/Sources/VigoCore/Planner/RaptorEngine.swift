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

/// A vehicle the traveller is already riding when the search starts.
///
/// The journey does not begin on a pavement: it begins on a bus, from which the only way out
/// is a stop the bus has not reached yet. Expressing that as a seed rather than as an access
/// walk is what stops the planner from offering a boarding at a stop this bus drives past.
public struct OnboardSeed: Sendable, Hashable {
    public let pattern: Int32
    /// Index of the trip **within the pattern**, as everywhere else in `Timetable`.
    public let trip: Int32
    /// Where the traveller is now. The seeded leg runs from here.
    public let boardPosition: Int32
    /// Added to this trip's scheduled times from `boardPosition` on. Signed, positive is late.
    ///
    /// Only this trip's: one vehicle carries one delay honestly, a connection does not
    /// (`LiveJourneyAdjustment`).
    public let delaySeconds: Int32

    public init(pattern: Int32, trip: Int32, boardPosition: Int32, delaySeconds: Int32) {
        self.pattern = pattern; self.trip = trip
        self.boardPosition = boardPosition; self.delaySeconds = delaySeconds
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

    /// A bus already boarded, replacing the walk into the network. `access` must be empty
    /// when this is set: there is no walk in, because the traveller is already inside.
    public let onboard: OnboardSeed?

    public init(access: [StopWalk], egress: [StopWalk], departure: Int32, horizon: Int32,
                onboard: OnboardSeed? = nil) {
        self.access = access; self.egress = egress
        self.departure = departure; self.horizon = horizon
        self.onboard = onboard
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

        // MARK: Round 1, seeded — the bus the traveller is already on
        //
        // Written outside the round loop because there is nothing for round 1 to *find*: the
        // vehicle is not chosen, it is given. Every stop the trip has left is labelled at its
        // own scheduled time (plus the observed delay), which is what an ordinary round 1
        // would have produced had the traveller boarded it — so rounds 2 onwards need no
        // knowledge of any of this and behave exactly as they always did.
        //
        // Two consequences worth stating so they are not later "fixed":
        //
        // - Nothing else can be boarded in round 1, because round 0 marked nothing. That is
        //   correct: round 1 *is* this bus.
        // - `ready` gets the transfer slack that round 0's access deliberately does not, so
        //   the next boarding counts as a transfer — which is what it is.
        if let seed = query.onboard {
            precondition(query.access.isEmpty,
                         "an onboard seed replaces the access walk; both cannot be given")
            let base = stopCount
            let pattern = Int(seed.pattern)
            let trip = Int(seed.trip)
            var riddenStops: [Int] = []
            for position in (Int(seed.boardPosition) + 1)..<timetable.stopCount(ofPattern: pattern) {
                let stop = Int(timetable.stopIndex(pattern: pattern, position: position))
                let arrives = timetable.arrival(pattern: pattern, trip: trip, position: position)
                    &+ seed.delaySeconds
                guard arrives < min(bestArrival[stop], targetBest) else { continue }
                arrival[base + stop] = arrives
                bestArrival[stop] = arrives
                ready[base + stop] = arrives &+ minTransfer
                parent[base + stop] = .ride(
                    pattern: seed.pattern, trip: seed.trip,
                    boardPosition: seed.boardPosition, alightPosition: Int32(position))
                if !marked[stop] { marked[stop] = true; riddenStops.append(stop) }
            }
            relaxFootpaths(timetable, base: base, riddenStops: riddenStops,
                           targetBest: targetBest, footpathBuffer: footpathBuffer,
                           arrival: &arrival, bestArrival: &bestArrival, ready: &ready,
                           parent: &parent, rideParent: &rideParent, marked: &marked)
            // Set by hand because the loop below never runs round 1 on this path, and
            // `JourneyReconstruction` refuses a result that claims no round ran.
            roundsRun = marked.contains(true) ? 1 : 0
        }

        // A seeded query has already had its round 1; `stride` yields nothing when the round
        // budget was spent on it, which is the honest reading of `maxRounds == 1` plus a bus
        // already boarded.
        let firstRound = query.onboard == nil ? 1 : 2
        for round in stride(from: firstRound, through: rounds, by: 1) {
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
                    } else if trip >= 0 {
                        // No earlier trip exists, but `current > boardable` already proved this
                        // position can catch the trip we are already riding — it is just a
                        // later (so, in practice, closer-to-the-passenger) stop on the very same
                        // vehicle. Without this, `boardPosition` stays pinned to wherever the
                        // pattern scan happened to start (the *most upstream* marked stop, not
                        // the nearest one), and reconstruction attributes the access walk to
                        // that far stop instead of a closer one that boards the identical bus.
                        // Real case: standing at Avda. da Florida 82, sent to walk to Avda. da
                        // Florida 197 (400 m away) for line 29, when Avda. da Florida (fronte
                        // 82) — 26 m away, same pattern, same trip — was right there.
                        boardPosition = position
                    }
                }
            }

            // MARK: 4 — one walk per round, from the stops just alighted at
            relaxFootpaths(timetable, base: base, riddenStops: riddenStops,
                           targetBest: targetBest, footpathBuffer: footpathBuffer,
                           arrival: &arrival, bestArrival: &bestArrival, ready: &ready,
                           parent: &parent, rideParent: &rideParent, marked: &marked)

            // MARK: 5
            if !marked.contains(true) { break }
            roundsRun = round
        }

        return RaptorResult(stopCount: stopCount, roundsRun: roundsRun,
                            arrival: arrival, parent: parent, bestArrival: bestArrival,
                            rideParent: rideParent)
    }

    /// The single footpath hop a round is allowed, from the stops that round alighted at.
    ///
    /// Not iterated to a fixed point on purpose: straight-line footpaths obey the triangle
    /// inequality, so chaining them can never beat the direct walk, and capping it at one hop
    /// keeps a transfer from silently becoming a 900 m hike.
    ///
    /// The ride arrivals — and their parents — are snapshotted before the second loop writes
    /// anything: a walk into stop X can land before X's own turn as a source comes up (X is in
    /// `riddenStops` too, just later in the list), and reading `arrival[base + X]` live at that
    /// point would pick up the walk's result instead of the ride's — turning "one hop" into two
    /// chained ones without either loop noticing.
    ///
    /// The parent needs the same snapshot as the value, not just the value: once a walk into X
    /// rewrites `parent[base + X]` to `.walk(from: ...)`, a later outgoing walk that reads
    /// `rideArrival[X]` (X's ride, correctly) would still chain onto X's now-overwritten
    /// `.walk` parent when the chain is later walked backwards — two footpaths presented as
    /// one. `rideParent` is what `JourneyReconstruction` follows instead, for exactly the stops
    /// this loop uses as a walk source.
    ///
    /// A method rather than the loop body it was extracted from because the onboard seed
    /// (`RaptorQuery.onboard`) writes a round-1 slice of its own outside the round loop and
    /// needs exactly this hop afterwards. Two copies of this reasoning would drift apart the
    /// way two copies of `PlanOutcome`'s wording once did.
    private func relaxFootpaths(
        _ timetable: Timetable, base: Int, riddenStops: [Int],
        targetBest: Int32, footpathBuffer: Int32,
        arrival: inout [Int32], bestArrival: inout [Int32], ready: inout [Int32],
        parent: inout [RaptorParent?], rideParent: inout [RaptorParent?],
        marked: inout [Bool]
    ) {
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
