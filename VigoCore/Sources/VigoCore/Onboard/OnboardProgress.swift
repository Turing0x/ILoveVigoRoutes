import Foundation

/// Moves a resolved ride forward as new GPS fixes arrive.
///
/// Three rules make this honest, and each of them is the reason a naive version would lie:
///
/// 1. **Forwards only, and only a few positions ahead.** The search window starts at the
///    position already reached. That is what keeps a loop pattern — the same stop at positions
///    4 and 30 — pinned to the visit the traveller is actually on, and what stops a GPS wobble
///    from reporting that they have gone backwards.
/// 2. **The delay is recomputed only when a stop is actually passed.** Between stops, "now
///    minus the schedule at the last stop reached" grows by one second per second and would be
///    shown as a delay getting steadily worse. Between stops the last measured value is
///    carried unchanged.
/// 3. **Nothing near the route means nothing is claimed.** Past `offRideMetres` from every stop
///    in the window, `looksOffRide` is set and the caller asks whether the traveller got off,
///    rather than quietly following a bus they are no longer on.
///
/// Carrying the measured delay forward for the rest of *this* ride is sound for the same
/// reason `LiveJourneyAdjustment` gives for a journey with no transfer: one vehicle, one
/// delay. It must never be carried past the alighting into a connecting bus, where the arrival
/// is not later but unknown.
public enum OnboardProgress {

    public struct Update: Sendable, Hashable {
        public let position: Int
        /// Compact stop index of `position`, for the timetable's arrays.
        public let stop: Int32
        /// Signed, positive is late.
        public let delaySeconds: Int32
        /// True when this fix advanced the position — the only time `delaySeconds` is fresh.
        public let passedStop: Bool
        /// True when no stop in the look-ahead window is within `offRideMetres`.
        public let looksOffRide: Bool

        public init(position: Int, stop: Int32, delaySeconds: Int32,
                    passedStop: Bool, looksOffRide: Bool) {
            self.position = position; self.stop = stop; self.delaySeconds = delaySeconds
            self.passedStop = passedStop; self.looksOffRide = looksOffRide
        }
    }

    public static func advance(_ resolved: ResolvedOnboardRide, in timetable: Timetable,
                               to coordinate: Coordinate, now: Date,
                               options: OnboardOptions = OnboardOptions()) -> Update {
        let positions = timetable.stopCount(ofPattern: resolved.pattern)
        let start = min(max(resolved.currentPosition, 0), positions - 1)
        let end = min(start + options.lookAheadPositions, positions - 1)

        var bestPosition = start
        var bestMetres = Double.greatestFiniteMagnitude
        for position in start...end {
            let metres = OnboardPatternLookup.metres(from: coordinate, toPosition: position,
                                                     ofPattern: resolved.pattern,
                                                     in: timetable)
            if metres < bestMetres { bestMetres = metres; bestPosition = position }
        }

        let looksOffRide = bestMetres > options.offRideMetres
        // An off-route fix never moves the position: the last stop known to have been reached
        // is still the last stop known to have been reached, and the caller is told to ask.
        let position = looksOffRide ? start : bestPosition
        let passedStop = position > start
        let delay = passedStop
            ? Int32(timetable.axisSeconds(for: now))
                &- timetable.departure(pattern: resolved.pattern, trip: resolved.trip,
                                       position: position)
            : resolved.delaySeconds

        return Update(position: position,
                      stop: timetable.stopIndex(pattern: resolved.pattern, position: position),
                      delaySeconds: delay, passedStop: passedStop, looksOffRide: looksOffRide)
    }
}
