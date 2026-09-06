import Foundation

/// Which journeys, out of everything the searches found, are worth offering at all.
///
/// Two steps that used to live inside `JourneyPlanner.ranked` as one. Pulled out and made pure
/// because both are easy to get subtly wrong in ways no end-to-end test would show, and out
/// here `swift test` can hand them a hand-built front and check the answer.
public enum JourneyShortlist {

    /// The undominated journeys.
    ///
    /// A journey dominates another when it leaves no earlier (less time waiting at the stop),
    /// boards its first vehicle no later, arrives no later, asks for no more transfers **and
    /// leaves no more walking at the end**, while being strictly better on at least one of the
    /// five. Journeys that tie on all five — a different line at the same times — are both
    /// kept: neither is worse, and the pair is a genuine choice.
    ///
    /// **The walking axis is what Fase 10 adds, and without it the rest of the phase is
    /// pointless.** On the three axes this had before, take X (arrives 9:40, one transfer, two
    /// minutes on foot at the end) against Y (arrives 9:38, no transfer, fifteen minutes on
    /// foot): Y wins on all three, X is discarded, and under "least walking" X was the answer.
    /// The candidate `JourneyReconstruction.egressCandidates` now goes out of its way to
    /// generate would be thrown away right here, before anyone could order by it.
    ///
    /// **The boarding axis is H-05.** `departure` (leaving later is better — less time
    /// standing at the stop) is not the same instant as `JourneyOrdering.firstBoarding`
    /// (boarding earlier is better — the question "sale antes" actually asks), and they can
    /// disagree whenever the access walks differ: a journey that boards the very first bus can
    /// still leave home *later* than one that boards a later bus from right outside the door.
    /// Without its own axis, "sale antes" could be asked to order a set from which its own
    /// answer had already been dropped, by a rival that only won on how long someone stands at
    /// the stop.
    ///
    /// The honest cost, accepted: every axis added means less dominance and a bigger front.
    /// That is why `maxCandidates` is larger than `maxAlternatives`, and why `cut` cannot
    /// simply take the first few by arrival.
    public static func undominated(_ journeys: [Journey]) -> [Journey] {
        // A walk-only journey never boards anything (`firstBoarding` is `nil`), and is
        // ordered last by that criterion — treated the same way here: no actual boarding
        // dominates it, and it dominates nothing on this axis, exactly as if it boarded at
        // the end of time. In practice every `Journey` reaching this filter has a ride
        // (`JourneyReconstruction.reconstruct` returns `nil` for one that does not), so this
        // only matters for callers, such as tests, that build one by hand.
        func boardsNoLaterOrEqual(_ a: Date?, _ b: Date?) -> Bool {
            switch (a, b) {
            case (nil, nil), (_, nil): return true
            case (nil, _): return false
            case (let x?, let y?): return x <= y
            }
        }
        func boardsStrictlyEarlier(_ a: Date?, _ b: Date?) -> Bool {
            switch (a, b) {
            case (_, nil): return false
            case (nil, _): return true
            case (let x?, let y?): return x < y
            }
        }
        func dominates(_ a: Journey, _ b: Journey) -> Bool {
            let aWalk = JourneyOrdering.egressWalkSeconds(a)
            let bWalk = JourneyOrdering.egressWalkSeconds(b)
            let aBoard = JourneyOrdering.firstBoarding(a)
            let bBoard = JourneyOrdering.firstBoarding(b)
            guard a.departure >= b.departure, a.arrival <= b.arrival,
                  a.transfers <= b.transfers, aWalk <= bWalk,
                  boardsNoLaterOrEqual(aBoard, bBoard) else { return false }
            return a.departure > b.departure || a.arrival < b.arrival
                || a.transfers < b.transfers || aWalk < bWalk
                || boardsStrictlyEarlier(aBoard, bBoard)
        }
        return journeys.filter { candidate in
            !journeys.contains { dominates($0, candidate) }
        }
    }

    /// Cuts the front down to `limit` **without favouring any one criterion**.
    ///
    /// Taking the first `limit` by arrival would put the old default back through the side
    /// door: whatever the user picks afterwards, the pool it picks from would have been chosen
    /// for speed, and on a large front the least-walking journey simply would not be in it —
    /// leaving a menu that reorders options all selected for the same thing.
    ///
    /// So the cut takes turns: the best still unpicked by each criterion, in rotation. That
    /// guarantees every criterion's own optimum survives the cut, whatever the limit is. The
    /// result comes back sorted by arrival, so callers can keep reading `first` as "soonest".
    public static func cut(_ journeys: [Journey], to limit: Int) -> [Journey] {
        guard limit > 0 else { return [] }
        guard journeys.count > limit else { return journeys.sorted { $0.arrival < $1.arrival } }

        var pools = JourneyOrdering.allCases.map { $0.apply(journeys, limit: journeys.count) }
        var picked: [Journey] = []
        var chosen = Set<Journey>()
        var wheel = 0

        while picked.count < limit {
            var tookOne = false
            for offset in 0..<pools.count {
                let index = (wheel + offset) % pools.count
                // Each pool is that criterion's whole order; skip past whatever another
                // criterion already claimed.
                while let next = pools[index].first {
                    pools[index].removeFirst()
                    if chosen.insert(next).inserted {
                        picked.append(next)
                        tookOne = true
                        break
                    }
                }
                if tookOne {
                    wheel = index + 1
                    break
                }
            }
            guard tookOne else { break }
        }
        return picked.sorted { $0.arrival < $1.arrival }
    }
}
