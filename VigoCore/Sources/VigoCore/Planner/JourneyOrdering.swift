import Foundation

/// How a list of alternatives is sorted for the person reading it.
///
/// Three criteria and not one, because they answer different questions and the same set of
/// journeys can come out in three different orders. Naming them is half the work:
///
/// - **Menos caminata** — how far you still have to walk once you get off. A comfort question.
/// - **Sale antes** — when the first bus passes your stop. Note this means *more* waiting at
///   the stop, not less; it is the preference of somebody who would rather be moving.
/// - **Llega antes** — door to door, final walk included. The only one that answers *do I get
///   there in time*, which is why it stays in the menu even though it is no longer the default.
///
/// The criterion is presentation, never a new question: switching it reorders journeys already
/// computed and never re-runs the planner. That is deliberate — a tap on the menu must not
/// cost four RAPTOR passes and up to sixteen `shapePoint` reads.
public enum JourneyOrdering: String, Sendable, Hashable, CaseIterable, Codable {
    /// The default. What makes you walk least once you are off the bus.
    case leastWalkAtEnd
    /// The first bus that passes your stop.
    case earliestBoarding
    /// Door to door, final walk included. The order that existed before Fase 10.
    case earliestArrival

    public static let `default`: JourneyOrdering = .leastWalkAtEnd

    public var label: String {
        switch self {
        case .leastWalkAtEnd:   "Menos caminata"
        case .earliestBoarding: "Sale antes"
        case .earliestArrival:  "Llega antes"
        }
    }

    public var symbolName: String {
        switch self {
        case .leastWalkAtEnd:   "figure.walk"
        case .earliestBoarding: "bus"
        case .earliestArrival:  "flag.checkered"
        }
    }

    /// Sorts and cuts, in that order.
    ///
    /// Cutting first would defeat the whole thing: the journey that walks least is often not
    /// among the first few by arrival, so a shortlist taken before sorting would be a
    /// shortlist chosen by a criterion nobody picked.
    public func apply(_ journeys: [Journey], limit: Int) -> [Journey] {
        let sorted = journeys.sorted(by: isBefore)
        guard limit >= 0 else { return sorted }
        return Array(sorted.prefix(limit))
    }

    private func isBefore(_ a: Journey, _ b: Journey) -> Bool {
        switch self {
        case .leastWalkAtEnd:
            let aWalk = Self.egressWalkSeconds(a), bWalk = Self.egressWalkSeconds(b)
            if aWalk != bWalk { return aWalk < bWalk }
            // Total walking as the first tie-break, which is the owner's decision: it stops
            // the app rewarding a journey that saves 200 m at the end and adds 600 m at the
            // start, without stopping the criterion being about the final walk.
            if a.walkingSeconds != b.walkingSeconds { return a.walkingSeconds < b.walkingSeconds }
            return a.arrival < b.arrival

        case .earliestBoarding:
            let aBoard = Self.firstBoarding(a), bBoard = Self.firstBoarding(b)
            // A walk-only journey never boards anything. It sorts last rather than first: it
            // is an answer to a different question, and putting it at the head of a list of
            // buses would read as "this is the first bus".
            switch (aBoard, bBoard) {
            case (nil, nil): break
            case (nil, _): return false
            case (_, nil): return true
            case (let x?, let y?) where x != y: return x < y
            default: break
            }
            if a.arrival != b.arrival { return a.arrival < b.arrival }
            return a.transfers < b.transfers

        case .earliestArrival:
            // Reproduces exactly the sort that lived in `JourneyPlanner.ranked` before this
            // phase, inverted departure tie-break included: at equal arrival, leaving *later*
            // wins, because that is less time standing at the stop. Choosing this criterion
            // makes the app behave as it did, and there is a test that says so.
            if a.arrival != b.arrival { return a.arrival < b.arrival }
            if a.departure != b.departure { return a.departure > b.departure }
            return a.transfers < b.transfers
        }
    }

    /// Seconds of the **last** walking leg: the one from the alighting stop to the door.
    ///
    /// For a walk-only journey that is the whole journey, not zero — it is all final walk.
    /// Reading the last leg rather than the last walk *between stops* is what makes that true.
    public static func egressWalkSeconds(_ journey: Journey) -> Int {
        guard case .walk(_, _, let seconds, _) = journey.legs.last else { return 0 }
        return seconds
    }

    // MARK: - Coste generalizado

    /// What one criterion thinks a journey costs, in **perceived** seconds — measured from
    /// the journey's own departure, so it prices the *journey* and not the hour it happens
    /// to leave at.
    ///
    /// Not a fourth ordering. `isBefore` still decides what the user sees, and it stays a
    /// lexicographic answer to a plain question. This exists for the one job ordering cannot
    /// do: deciding what does not belong on the list at all.
    ///
    /// **Why "from its own departure" and not from a common clock.** The first draft charged
    /// every journey for the wall-clock time from the query onwards. Measured against the
    /// real feed it worked far too well: a Príncipe → Cunqueiro search went from five
    /// options to one, because the four it dropped were the 9:37, 9:39, 9:50 and 10:01
    /// buses. Those are not junk — they are *the next buses*, which is most of what a list
    /// of alternatives is for. Charging for lateness deletes the list. Charging for
    /// inefficiency does not.
    ///
    /// **What it does catch**, from the same measurement, on Suárez Llanos → Bembrive:
    ///
    ///     sale 9:31  llega 10:08  camina 0 s  1 transbordo   C3i+6
    ///     sale 9:46  llega 10:30  camina 0 s  2 transbordos  5B+H2+6
    ///
    /// The second is worse on arrival, worse on transfers and no better on foot, and it
    /// survives `undominated` purely by leaving later — the "less time waiting at the stop"
    /// axis (H-05), which has no upper bound on how much lateness it will excuse. Pareto
    /// dominance cannot rule that out; a scalar cost can.
    ///
    /// The weights are policy, and the local analogue of the profiles the Concello's own
    /// planner sends to OpenTripPlanner: `walkReluctance` 10 for "fastest" against 35 for
    /// "least walking", `transferPenalty` 600 (`AUDITORIA-MOTOR-VS-CONCELLO.md` §2.5).
    /// Theirs are in OTP's units; these are seconds per second, so the same relationship
    /// reads as 1.0 against 3.0.
    public func generalizedCostSeconds(_ journey: Journey) -> Double {
        // Door to door for *this* journey: from the moment its own walk to the stop starts.
        // Waiting at the stop before the first bus is inside it, so a journey does not get
        // cheaper by dawdling; what is outside it is how long the traveller waited at home,
        // which is not a property of the journey.
        let travel = journey.arrival.timeIntervalSince(journey.departure)
        let walkTotal = Double(journey.walkingSeconds)
        let transfers = Double(journey.transfers) * Self.transferPenaltySeconds

        switch self {
        case .earliestArrival, .earliestBoarding:
            // Deliberately the same. Plausibility asks "is this a decent journey", and
            // "sale antes" does not change what makes one decent — it changes which decent
            // one is shown first, and that is `isBefore`'s business. Giving this criterion a
            // cost of its own that rewarded leaving early would let it re-admit exactly the
            // 9:46-with-two-transfers this filter exists to drop.
            return travel + walkTotal + transfers

        case .leastWalkAtEnd:
            // The final walk counted a second time, at twice its weight again: it is what
            // this criterion is *about*, and the `walkTotal` term alone cannot tell it apart
            // from the same minutes walked at the start. This is what keeps a slower journey
            // that drops you at the door on the list.
            return travel + walkTotal
                + 2.0 * Double(Self.egressWalkSeconds(journey)) + transfers
        }
    }

    /// What one change of vehicle is worth, in perceived seconds.
    ///
    /// Five minutes. Deliberately the same figure as `PlannerOptions.extraTransferWorthSeconds`,
    /// which is the answer this project already gave to the same question one level up — a
    /// transfer that saves less than five minutes is not worth offering. Two different
    /// numbers for one belief would drift apart.
    public static let transferPenaltySeconds: Double = 300

    /// When the first bus leaves, or `nil` for a journey that never boards one.
    ///
    /// **Not `Journey.departure`**, which is when the passenger has to start walking towards
    /// the stop — earlier by the whole access leg, and by a different amount for each
    /// alternative. "Sale antes" is about the bus.
    public static func firstBoarding(_ journey: Journey) -> Date? {
        for leg in journey.legs {
            if case .ride(_, _, _, _, _, _, let departure, _, _) = leg { return departure }
        }
        return nil
    }
}
