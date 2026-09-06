import Foundation
@testable import VigoCore

/// A minimal `RaptorResult`-shaped answer, without the parent pointers: nothing here needs
/// to rebuild a journey, only to compare arrival labels.
struct BruteForceResult: Equatable {
    let stopCount: Int
    let roundsRun: Int
    let arrival: [Int32]
    let bestArrival: [Int32]

    func arrival(round: Int, stop: Int) -> Int32? {
        let value = arrival[round * stopCount + stop]
        return value == RaptorResult.unreached ? nil : value
    }
}

/// Exhaustive reference for what `RaptorEngine` is defined to compute: round `k` is the best
/// label reachable using at most `k` vehicles, boarding only off the *previous* round's
/// label, with one footpath hop per round from the stops just ridden to.
///
/// This shares the algorithm's rules with `RaptorEngine`, deliberately not its
/// implementation: no binary search for the earliest catchable trip (every trip of every
/// pattern at every eligible stop is tried), no pattern-position queue (every stop is
/// rescanned every round), no incremental scan-order bookkeeping. A bug in any of the real
/// engine's optimisations shows up as a mismatch against this, because nothing here shares
/// the buggy code path.
enum BruteForceReference {
    static func run(_ timetable: Timetable, _ query: RaptorQuery,
                    options: PlannerOptions) -> BruteForceResult {
        let stopCount = timetable.stopCount
        let rounds = max(1, options.maxRounds)
        let unreached = RaptorResult.unreached
        let minTransfer = Int32(options.minTransferSeconds)
        let footpathBuffer = Int32(options.footpathBufferSeconds)

        var arrival = [Int32](repeating: unreached, count: (rounds + 1) * stopCount)
        var bestArrival = [Int32](repeating: unreached, count: stopCount)
        var ready = [Int32](repeating: unreached, count: (rounds + 1) * stopCount)

        // No tightening against `bestEgress` here — see `RaptorEngine.run` (H-03): sound
        // only for a single scalar objective, and this reference has to share the corrected
        // rule or a contrast against the fixed engine would show mismatches that are not
        // engine bugs at all.
        let targetBest = query.departure &+ query.horizon

        for entry in query.access {
            let stop = Int(entry.stop)
            let time = query.departure &+ entry.seconds
            guard time < targetBest, time < bestArrival[stop] else { continue }
            arrival[stop] = time
            ready[stop] = time
            bestArrival[stop] = time
        }

        var roundsRun = 0

        for round in 1...rounds {
            let base = round * stopCount
            let previous = (round - 1) * stopCount
            var rideMarked = [Bool](repeating: false, count: stopCount)
            var anyMarked = false

            // Every trip of every pattern serving a boardable stop, ridden to every later
            // position it stops at — no shortcut for "the earliest one that still works".
            for stop in 0..<stopCount {
                let boardTime = ready[previous + stop]
                guard boardTime != unreached else { continue }
                for slot in timetable.patternSlots(ofStop: stop) {
                    let pattern = Int(timetable.stopPatternPattern[slot])
                    let position = Int(timetable.stopPatternPosition[slot])
                    let positions = timetable.stopCount(ofPattern: pattern)
                    let trips = timetable.tripCount(ofPattern: pattern)
                    for trip in 0..<trips {
                        let departs = timetable.departure(pattern: pattern, trip: trip, position: position)
                        guard departs >= boardTime else { continue }
                        for laterPosition in (position + 1)..<positions {
                            let alightStop = Int(timetable.stopIndex(pattern: pattern, position: laterPosition))
                            let arrives = timetable.arrival(pattern: pattern, trip: trip, position: laterPosition)
                            guard arrives < min(bestArrival[alightStop], targetBest) else { continue }
                            bestArrival[alightStop] = arrives
                            arrival[base + alightStop] = arrives
                            ready[base + alightStop] = arrives &+ minTransfer
                            rideMarked[alightStop] = true
                            anyMarked = true
                        }
                    }
                }
            }

            // One footpath hop, only from stops just reached by riding this round — never
            // from a stop only just reached on foot, which is what keeps a transfer from
            // becoming a two-hop hike. Snapshotted before any write, for the same reason
            // `RaptorEngine` snapshots it: a walk into a ride-marked stop must not become the
            // "from" for that stop's own outgoing walk.
            var rideArrival: [Int: Int32] = [:]
            for stop in 0..<stopCount where rideMarked[stop] { rideArrival[stop] = arrival[base + stop] }

            for stop in 0..<stopCount where rideMarked[stop] {
                let from = rideArrival[stop]!
                for slot in timetable.footpaths(fromStop: stop) {
                    let target = Int(timetable.footpathTarget[slot])
                    let seconds = timetable.footpathSeconds[slot]
                    let candidate = from &+ seconds
                    guard candidate < min(bestArrival[target], targetBest) else { continue }
                    bestArrival[target] = candidate
                    arrival[base + target] = candidate
                    ready[base + target] = candidate &+ footpathBuffer
                    anyMarked = true
                }
            }

            guard anyMarked else { break }
            roundsRun = round
        }

        return BruteForceResult(stopCount: stopCount, roundsRun: roundsRun,
                                arrival: arrival, bestArrival: bestArrival)
    }
}

// MARK: - Randomized small timetables

/// A seeded PRNG so a mismatch found today is a mismatch that can be found again tomorrow.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// A random small timetable plus a query to run against it, built directly from
/// `Timetable`'s own arrays rather than through `TimetableBuilder` — there is no GTFS feed
/// to import here, only the invariants RAPTOR relies on: trips of a pattern do not overtake
/// one another.
enum RandomPlannerFixture {
    static func makeInstance(rng: inout SeededGenerator) -> (Timetable, RaptorQuery, PlannerOptions) {
        let stopCount = Int.random(in: 3...7, using: &rng)
        let stops = (0..<stopCount).map { PlannerFixture.stop("RND\($0)", name: "S\($0)") }
        var stopIndexByID: [StopID: Int32] = [:]
        for (index, stop) in stops.enumerated() { stopIndexByID[stop.id] = Int32(index) }

        let patternCount = Int.random(in: 1...4, using: &rng)
        var patternStopsOffset: [Int32] = [0]
        var patternStops: [Int32] = []
        var patternTripsOffset: [Int32] = [0]
        var tripRefs: [TripRef] = []
        var patternTimesOffset: [Int32] = [0]
        var tripArrival: [Int32] = []
        var tripDeparture: [Int32] = []
        var patternRouteID: [RouteID] = []
        var patternRouteShortName: [String] = []

        // (pattern, position) pairs per stop, built up as patterns are generated.
        var slotsPerStop: [[(pattern: Int32, position: Int32)]] = Array(repeating: [], count: stopCount)

        for pattern in 0..<patternCount {
            let visited = Int.random(in: 2...min(4, stopCount), using: &rng)
            let sequence = Array((0..<stopCount).shuffled(using: &rng).prefix(visited))
            for (position, stop) in sequence.enumerated() {
                patternStops.append(Int32(stop))
                slotsPerStop[stop].append((pattern: Int32(pattern), position: Int32(position)))
            }
            patternStopsOffset.append(Int32(patternStops.count))

            // Base times, strictly increasing along the pattern (dwell of zero).
            var base: Int32 = Int32.random(in: 0...3_600, using: &rng)
            var baseTimes: [Int32] = [base]
            for _ in 1..<visited {
                base &+= Int32.random(in: 60...900, using: &rng)
                baseTimes.append(base)
            }

            let tripCount = Int.random(in: 1...3, using: &rng)
            // A fixed positive headway per trip index keeps every trip strictly later than
            // the last at *every* position, which is exactly the no-overtaking guarantee
            // `TimetableBuilder` enforces on the real feed.
            let headway = Int32.random(in: 300...1_800, using: &rng)
            for trip in 0..<tripCount {
                let offset = Int32(trip) &* headway
                tripRefs.append(TripRef(
                    tripID: TripID("P\(pattern)T\(trip)"),
                    serviceDate: ServiceDate(yyyymmdd: 20_260_101),
                    dayOffsetSeconds: 0, headsign: nil))
                for time in baseTimes {
                    let t = time &+ offset
                    tripArrival.append(t)
                    tripDeparture.append(t)
                }
            }
            patternTripsOffset.append(Int32(tripRefs.count))
            patternTimesOffset.append(Int32(tripArrival.count))
            patternRouteID.append(RouteID("R\(pattern)"))
            patternRouteShortName.append("L\(pattern)")
        }

        var stopPatternsOffset: [Int32] = [0]
        var stopPatternPattern: [Int32] = []
        var stopPatternPosition: [Int32] = []
        for stop in 0..<stopCount {
            for slot in slotsPerStop[stop] {
                stopPatternPattern.append(slot.pattern)
                stopPatternPosition.append(slot.position)
            }
            stopPatternsOffset.append(Int32(stopPatternPattern.count))
        }

        // A random, not-necessarily-metric footpath graph: the reference and the engine are
        // both being checked against the *same* one-hop-per-round rule, not against real
        // geometry, so the triangle inequality is not a requirement here.
        var footpathsByOrigin: [[(target: Int32, seconds: Int32)]] = Array(repeating: [], count: stopCount)
        if stopCount > 1 {
            let pairCount = Int.random(in: 0...stopCount, using: &rng)
            for _ in 0..<pairCount {
                let a = Int.random(in: 0..<stopCount, using: &rng)
                var b = Int.random(in: 0..<stopCount, using: &rng)
                while b == a { b = Int.random(in: 0..<stopCount, using: &rng) }
                let seconds = Int32.random(in: 30...300, using: &rng)
                footpathsByOrigin[a].append((target: Int32(b), seconds: seconds))
                footpathsByOrigin[b].append((target: Int32(a), seconds: seconds))
            }
        }
        var footpathOffset: [Int32] = [0]
        var footpathTarget: [Int32] = []
        var footpathSeconds: [Int32] = []
        for stop in 0..<stopCount {
            for path in footpathsByOrigin[stop] {
                footpathTarget.append(path.target)
                footpathSeconds.append(path.seconds)
            }
            footpathOffset.append(Int32(footpathTarget.count))
        }

        let anchor = ServiceDate(yyyymmdd: 20_260_101)
        let timetable = Timetable(
            stops: stops, stopIndexByID: stopIndexByID,
            patternStopsOffset: patternStopsOffset, patternStops: patternStops,
            patternTripsOffset: patternTripsOffset, tripRefs: tripRefs,
            patternTimesOffset: patternTimesOffset,
            tripArrival: tripArrival, tripDeparture: tripDeparture,
            patternRouteID: patternRouteID, patternRouteShortName: patternRouteShortName,
            stopPatternsOffset: stopPatternsOffset,
            stopPatternPattern: stopPatternPattern, stopPatternPosition: stopPatternPosition,
            footpathOffset: footpathOffset, footpathTarget: footpathTarget,
            footpathSeconds: footpathSeconds,
            anchorDay: anchor, anchorMidnight: Date(timeIntervalSince1970: 0),
            coveredDays: [anchor], feedFingerprint: nil)

        let accessCount = Int.random(in: 1...min(3, stopCount), using: &rng)
        let access = (0..<stopCount).shuffled(using: &rng).prefix(accessCount).map {
            StopWalk(stop: Int32($0), seconds: Int32.random(in: 0...300, using: &rng))
        }
        let egressCount = Int.random(in: 1...min(3, stopCount), using: &rng)
        let egress = (0..<stopCount).shuffled(using: &rng).prefix(egressCount).map {
            StopWalk(stop: Int32($0), seconds: Int32.random(in: 0...300, using: &rng))
        }

        let departure = Int32.random(in: 0...3_600, using: &rng)
        let horizon = Int32.random(in: 1_800...7_200, using: &rng)
        let options = PlannerOptions(
            minTransferSeconds: Int.random(in: 0...120, using: &rng),
            footpathBufferSeconds: Int.random(in: 0...120, using: &rng),
            maxRounds: Int.random(in: 1...4, using: &rng))

        let query = RaptorQuery(access: Array(access), egress: Array(egress),
                                departure: departure, horizon: horizon)
        return (timetable, query, options)
    }
}
