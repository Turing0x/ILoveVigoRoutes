import Foundation

/// What a live countdown at the first stop actually implies for the rest of the journey.
///
/// **The gap this closes.** `FirstBoardingMatch` already finds the realtime arrival that is
/// most likely this journey's first bus, and the alternatives list already shows its
/// countdown. What it does not do is carry that fact any further: the row goes on showing the
/// timetable's arrival time while the badge next to it says the bus is eight minutes late.
/// Those two numbers cannot both be right, and the one the passenger plans around — "do I get
/// there in time" — is the wrong one.
///
/// **What it deliberately does not do.** Nothing here re-plans. Realtime annotates and never
/// decides; that was settled in Fase 3 and is unchanged. A late bus does not make the planner
/// go looking for a different one, because the realtime source cannot see the network — only
/// the stop the passenger is standing at — and a search half-informed by live data would
/// produce answers nobody could reason about.
///
/// **And the honest limit.** A delay can be carried to the arrival of a journey that never
/// changes vehicle, because the same bus is late for the whole trip. It cannot be carried
/// across a transfer: the connection either still works, in which case the rest runs to
/// timetable, or it does not, in which case the arrival is not "later" but *unknown* — the
/// next vehicle might be twenty minutes behind. So a journey with transfers gets a warning,
/// never an adjusted time it cannot justify.
public enum LiveJourneyAdjustment {

    /// What the live countdown says about this journey, beyond the countdown itself.
    public struct Adjustment: Sendable, Hashable {
        /// Signed: positive is late, negative is early. Derived from the countdown, so it
        /// inherits its resolution — the source reports whole minutes.
        public let delay: TimeInterval

        /// The arrival implied by that delay, or `nil` when it cannot honestly be implied.
        ///
        /// `nil` for any journey that changes vehicle. See the type's doc comment: past a
        /// transfer the arrival is not later, it is unknown.
        public let adjustedArrival: Date?

        /// True when the delay is at least as large as the slack at some transfer, so the
        /// connection the plan depends on may no longer exist.
        public let connectionAtRisk: Bool

        /// The tightest transfer in the journey, once the delay is taken off it. Negative
        /// means the passenger arrives after the next bus has left. `nil` for a direct
        /// journey, which has no transfer to lose.
        public let worstConnectionSlack: TimeInterval?
    }

    /// How late a bus has to be before saying anything about it.
    ///
    /// Two minutes. The realtime source reports whole minutes and the planner's own walking
    /// figures are estimates, so anything under this is inside the noise of both — and a
    /// warning that fires on noise is a warning nobody reads.
    public static let significantDelay: TimeInterval = 120

    /// What `live` implies for `journey`, or `nil` when it implies nothing worth saying.
    ///
    /// - Parameter now: the caller's clock, passed rather than read, so a test does not
    ///   depend on the hour it runs at — the same contract `FirstBoardingMatch` uses.
    public static func adjust(_ journey: Journey, live: Arrival, now: Date) -> Adjustment? {
        guard let ride = FirstBoardingMatch.firstRide(of: journey) else { return nil }
        let implied = now.addingTimeInterval(TimeInterval(live.minutes * 60))
        let delay = implied.timeIntervalSince(ride.departure)
        guard abs(delay) >= significantDelay else { return nil }

        let slack = worstSlack(journey)
        // Only lateness can break a connection. A bus running early leaves *more* slack, and
        // treating a negative delay as risk would warn about the good case.
        let atRisk = slack.map { delay > 0 && delay >= $0 } ?? false

        return Adjustment(
            delay: delay,
            // Carried only when there is no transfer to invalidate it. A direct journey is
            // one vehicle from the first stop to the last, so its whole timetable slides by
            // the same amount the bus is late.
            adjustedArrival: journey.transfers == 0
                ? journey.arrival.addingTimeInterval(delay) : nil,
            connectionAtRisk: atRisk,
            worstConnectionSlack: slack)
    }

    /// The smallest gap in the journey between getting off one vehicle and the next one
    /// leaving, with any walking in between already taken out.
    ///
    /// This is the number a delay eats into. It is computed from the legs rather than from
    /// `PlannerOptions` on purpose: the plan on screen is what the passenger is going to
    /// follow, and its own timings are what decide whether it still holds — not the policy
    /// minimums the search happened to use when it was built.
    ///
    /// `public` since the onboard mode, which needs it on its own. There, no delay has to be
    /// applied on top: `planOnboard` already builds the first leg with the lateness the
    /// traveller is actually experiencing, so the gap this returns is the real one and
    /// applying `adjust` to it as well would count the same minutes twice.
    public static func worstSlack(_ journey: Journey) -> TimeInterval? {
        var worst: TimeInterval?
        var lastAlight: Date?
        var walkBetween: TimeInterval = 0

        for leg in journey.legs {
            switch leg {
            case .walk(_, _, let seconds, _):
                if lastAlight != nil { walkBetween += TimeInterval(seconds) }
            case .ride(_, _, _, _, _, _, let departure, let arrival, _):
                if let alight = lastAlight {
                    let slack = departure.timeIntervalSince(alight) - walkBetween
                    if worst == nil || slack < worst! { worst = slack }
                }
                lastAlight = arrival
                walkBetween = 0
            }
        }
        return worst
    }
}
