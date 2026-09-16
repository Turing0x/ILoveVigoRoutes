import Foundation

/// "From that other stop you would get there sooner", said next to a search from a chosen stop.
///
/// When the traveller picks a stop as the origin, every alternative leaves from that stop —
/// they are standing there, and a planner that quietly sends them on a five-minute walk to
/// somewhere else has answered a question nobody asked. What it must not do either is hide
/// that a stop round the corner is clearly better. This is that fact, kept apart from the
/// alternatives so it can never be mistaken for one of them.
public struct NearbyStopHint: Sendable, Hashable {
    /// Where the better journey boards.
    public let stop: Stop
    /// The walk from the chosen stop to `stop`, in seconds.
    public let walkSeconds: Int
    /// How much sooner it arrives, walk included. `nil` when nothing leaves from the chosen
    /// stop at all, so there is nothing to be sooner than.
    public let arrivesEarlierBy: TimeInterval?
    /// The journey itself, for a caller that wants to show more than one line of text.
    public let journey: Journey

    public init(stop: Stop, walkSeconds: Int, arrivesEarlierBy: TimeInterval?, journey: Journey) {
        self.stop = stop
        self.walkSeconds = walkSeconds
        self.arrivesEarlierBy = arrivesEarlierBy
        self.journey = journey
    }

    /// The hint for `anchored` (everything found leaving from `origin`) against `unanchored`
    /// (the same search from every stop within walking distance), or `nil` when there is
    /// nothing worth saying.
    ///
    /// Only a journey that boards somewhere other than `origin` can be the hint — the chosen
    /// stop recommending itself is not a hint. It must arrive at least `minimumGain` sooner
    /// than the soonest bus from `origin`; when no bus leaves from `origin`, any journey
    /// that boards elsewhere is worth mentioning, because it is the only way there.
    static func choose(origin: Stop, anchored: [Journey], unanchored: [Journey],
                       minimumGain: TimeInterval) -> NearbyStopHint? {
        let anchoredBest = anchored.filter { $0.firstBoarding != nil }.map(\.arrival).min()
        let elsewhere = unanchored
            .filter { journey in
                guard let board = journey.firstBoarding else { return false }
                return board.id != origin.id
            }
            .min { $0.arrival < $1.arrival }
        guard let candidate = elsewhere, let board = candidate.firstBoarding else { return nil }

        let gain = anchoredBest.map { $0.timeIntervalSince(candidate.arrival).rounded() }
        if let gain, gain < minimumGain { return nil }

        let walkSeconds: Int
        if case .walk(_, _, let seconds, _) = candidate.legs.first {
            walkSeconds = seconds
        } else {
            walkSeconds = 0
        }
        return NearbyStopHint(stop: board, walkSeconds: walkSeconds,
                              arrivesEarlierBy: gain, journey: candidate)
    }
}

extension Journey {
    /// The stop of the first vehicle boarded, or `nil` for a journey made entirely on foot.
    var firstBoarding: Stop? {
        for leg in legs {
            if case .ride(_, _, _, _, let board, _, _, _, _) = leg { return board }
        }
        return nil
    }
}
