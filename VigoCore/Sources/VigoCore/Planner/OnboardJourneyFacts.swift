import Foundation

/// What a journey planned from on board means, leg by leg.
///
/// **Why these are new functions and not parameters on the existing ones.**
/// `FirstBoardingMatch.firstRide`, `JourneyOrdering.firstBoarding` and
/// `FirstBoardingMatch.hasDeparted` all mean "leg 0's ride", and they mean it correctly: for
/// an ordinary journey that *is* the bus the traveller has to catch, and the distinction
/// between it and `Journey.departure` is documented and tested. On an onboard journey leg 0 is
/// a bus already boarded — `hasDeparted` is true of every one of them, and the countdown at
/// its boarding stop says nothing anybody can use. Redefining those three for this one caller
/// would rot a distinction the rest of the app depends on; asking a different question
/// instead costs one small file.
public enum OnboardJourneyFacts {

    /// The bus the traveller is already on: the first ride of an onboard journey.
    public static func currentRide(_ journey: Journey) -> JourneyLeg? {
        journey.legs.first { if case .ride = $0 { true } else { false } }
    }

    /// Where and when to get off that bus.
    public static func alighting(_ journey: Journey) -> (stop: Stop, at: Date)? {
        guard case .ride(_, _, _, _, _, let alight, _, let arrival, _)? = currentRide(journey) else {
            return nil
        }
        return (alight, arrival)
    }

    /// The next boarding the traveller still has to make — the **second** ride — or `nil` when
    /// this bus goes all the way.
    ///
    /// This is what a live countdown should be shown for on this screen: the stop the traveller
    /// is standing at is not a stop, it is a moving bus, and the realtime source has nothing to
    /// say about that.
    public static func nextBoarding(_ journey: Journey)
        -> (routeShortName: String, board: Stop, departure: Date)? {
        var seenFirstRide = false
        for leg in journey.legs {
            guard case .ride(_, let routeShortName, _, _, let board, _, let departure, _, _) = leg
            else { continue }
            if seenFirstRide { return (routeShortName, board, departure) }
            seenFirstRide = true
        }
        return nil
    }

    /// How much slack the connection has left, or `nil` for a journey with no connection.
    ///
    /// Delegates to `LiveJourneyAdjustment.worstSlack` rather than measuring again: the
    /// onboard journey's own legs already carry the delay the traveller is experiencing, so
    /// the gap that returns is the real one.
    public static func connectionSlack(_ journey: Journey) -> TimeInterval? {
        LiveJourneyAdjustment.worstSlack(journey)
    }
}
