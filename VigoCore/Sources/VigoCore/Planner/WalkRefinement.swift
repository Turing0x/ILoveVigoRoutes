import Foundation

/// Something that can measure a walk on a real street network.
///
/// Deliberately tiny and deliberately fallible. `nil` means "I could not find out" — no
/// network, a rate limit, a route the router refuses — and every caller treats that as "keep
/// the estimate", never as "there is no walk". A router that fails must degrade this app to
/// exactly what it did before the router existed.
///
/// The protocol lives here and every implementation lives in the app, because the only real
/// one is `MKDirections` and pulling MapKit into `VigoCore` would put a network call inside
/// the package `swift test` runs on the Mac.
public protocol WalkRouter: Sendable {
    /// Walking seconds between two points, or `nil` when it cannot be established.
    func walkSeconds(from: Coordinate, to: Coordinate) async -> Int?
}

/// Replaces a journey's estimated access and egress walks with measured ones.
///
/// **Why only these two.** B2 solved the transfers by measuring every pair of stops offline,
/// which works because both ends are known in advance. These two cannot be precomputed: one
/// end is wherever the user happens to be. So they are still the straight-line estimate times
/// a factor, and `PlannerOptions.accessDetourFactor` is a stopgap that says so in its own doc
/// comment — measured against a real street graph its per-pair error runs from −28 % to +29 %.
///
/// **Why it annotates rather than plans.** Refining before the search would mean a network
/// round trip per candidate stop — up to a hundred of them — before any answer could appear,
/// and no answer at all without a connection. Refining afterwards costs at most two lookups
/// per journey shown, happens while the results are already on screen, and leaves the app
/// working offline exactly as it does today. It is the same shape `FirstBoardingLive` uses for
/// realtime, for the same reasons.
///
/// **What it is allowed to conclude.** That the walk is longer or shorter than estimated, and
/// therefore that the door-to-door times move. And, when the measured access walk no longer
/// fits before the bus leaves, that this alternative cannot be caught — which is the failure
/// this whole thread of work started from.
public enum WalkRefinement {

    /// A journey's two open-air walks, measured.
    public struct Refinement: Sendable, Hashable {
        /// Measured seconds for the walk from the origin to the first stop, or `nil` when the
        /// router could not say and the estimate stands.
        public let accessSeconds: Int?
        /// The same for the last stop to the destination.
        public let egressSeconds: Int?
        /// The estimate these replace, so a view can say by how much it was wrong.
        public let estimatedAccessSeconds: Int
        public let estimatedEgressSeconds: Int

        /// Signed difference on the access walk: positive means the real walk is longer than
        /// the app promised. `nil` when unmeasured.
        public var accessError: Int? {
            accessSeconds.map { $0 - estimatedAccessSeconds }
        }

        public var egressError: Int? {
            egressSeconds.map { $0 - estimatedEgressSeconds }
        }

        /// Whether anything was actually measured. A refinement of two `nil`s is the identity
        /// and callers may drop it.
        public var isEmpty: Bool { accessSeconds == nil && egressSeconds == nil }
    }

    /// What the measured walks mean for the journey on screen.
    public struct Outcome: Sendable, Hashable {
        /// When the traveller now has to set off. Later if the walk turned out shorter,
        /// earlier if longer.
        public let departure: Date
        /// When they now arrive.
        public let arrival: Date
        /// **The measured access walk no longer fits before the bus leaves.**
        ///
        /// Only ever set against a real `now`: it is a statement about a bus that is about to
        /// go, not about a journey planned for tomorrow morning.
        public let boardingUnreachable: Bool
        /// Seconds left over between finishing the measured access walk and the bus leaving.
        /// Negative is how late the traveller would be.
        public let secondsToSpare: Int?
    }

    /// Seconds of the journey's first leg if it is a walk from the origin, else zero — a
    /// journey can begin at a stop the traveller is already standing at.
    public static func estimatedAccessSeconds(_ journey: Journey) -> Int {
        guard case .walk(_, _, let seconds, _) = journey.legs.first,
              FirstBoardingMatch.firstRide(of: journey) != nil else { return 0 }
        return seconds
    }

    /// Seconds of the journey's last leg if it is a walk. Shares
    /// `JourneyOrdering.egressWalkSeconds`, which is the same question asked for ordering, so
    /// the two cannot disagree about what "the walk at the end" means.
    public static func estimatedEgressSeconds(_ journey: Journey) -> Int {
        JourneyOrdering.egressWalkSeconds(journey)
    }

    /// Applies a refinement to a journey.
    ///
    /// - Parameter now: the traveller's clock, for `boardingUnreachable`. Pass `nil` — as a
    ///   query for another day should — to state only what the measurements imply about the
    ///   times, and claim nothing about whether a bus can still be caught.
    public static func outcome(for journey: Journey, refinement: Refinement,
                               now: Date?) -> Outcome? {
        guard !refinement.isEmpty else { return nil }

        let accessDelta = TimeInterval(refinement.accessError ?? 0)
        let egressDelta = TimeInterval(refinement.egressError ?? 0)

        // A longer access walk moves the *departure* earlier: the bus leaves when it leaves,
        // so the whole difference comes out of the traveller's own time. It does not move the
        // arrival, which is why the two deltas are applied to different ends.
        let departure = journey.departure.addingTimeInterval(-accessDelta)
        let arrival = journey.arrival.addingTimeInterval(egressDelta)

        var unreachable = false
        var spare: Int?
        if let now, let measuredAccess = refinement.accessSeconds,
           let ride = FirstBoardingMatch.firstRide(of: journey) {
            let readyAt = now.addingTimeInterval(TimeInterval(measuredAccess))
            let margin = ride.departure.timeIntervalSince(readyAt)
            spare = Int(margin.rounded())
            // Strictly negative, not "within a minute": being told a bus is unreachable when
            // it is leaving exactly as you arrive is a worse error than being told it is
            // tight. The row already says how many seconds are left.
            unreachable = margin < 0
        }

        return Outcome(departure: departure, arrival: arrival,
                       boardingUnreachable: unreachable, secondsToSpare: spare)
    }

    /// Measures both open-air walks of one journey.
    ///
    /// Two lookups at most, and fewer when a leg is not a walk. Nothing here retries: a
    /// router that failed once for this journey has said all it is going to say, and the
    /// estimate is a perfectly usable answer.
    public static func measure(_ journey: Journey, using router: some WalkRouter) async -> Refinement {
        var accessSeconds: Int?
        var egressSeconds: Int?

        if case .walk(let from, let to, _, _) = journey.legs.first,
           journey.legs.count > 1 {
            accessSeconds = await router.walkSeconds(from: from.coordinate, to: to.coordinate)
        }
        if journey.legs.count > 1, case .walk(let from, let to, _, _) = journey.legs.last {
            egressSeconds = await router.walkSeconds(from: from.coordinate, to: to.coordinate)
        }
        return Refinement(accessSeconds: accessSeconds, egressSeconds: egressSeconds,
                          estimatedAccessSeconds: estimatedAccessSeconds(journey),
                          estimatedEgressSeconds: estimatedEgressSeconds(journey))
    }
}
