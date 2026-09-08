import Foundation

/// Policy for recognising and following a bus the traveller is already riding.
///
/// Separate from `PlannerOptions`, which is search policy: nothing here changes what RAPTOR
/// explores, only how a GPS fix and a line name are turned into "this trip, at this position",
/// and how that position is kept up to date afterwards.
public struct OnboardOptions: Sendable, Hashable {
    /// How far a fix may sit from a stop of the pattern and still be taken as "on that
    /// stretch of the route".
    ///
    /// Four hundred metres, not the planner's 800 m access radius: this is a snap onto a
    /// sequence of stops, not a walk the traveller has to make. It is added to the fix's own
    /// reported horizontal accuracy, so a bad fix widens the net rather than being rejected.
    public var maxSnapMetres: Double

    /// How late a trip may be running and still be a candidate at a position.
    ///
    /// Deliberately asymmetric with `earlyWindowSeconds`. A Vitrasa bus in traffic runs late
    /// far more often than early, and the schedule is the only clock available here — the
    /// realtime source cannot say which vehicle this is (`FirstBoardingMatch`).
    public var lateWindowSeconds: Int32
    public var earlyWindowSeconds: Int32

    /// Beyond this distance from every stop in the look-ahead window, the ride is no longer
    /// believed. The UI asks whether the traveller got off rather than guessing.
    public var offRideMetres: Double

    /// How many positions ahead `OnboardProgress` will look for the traveller's new position.
    ///
    /// A window, not the whole pattern, and it is what makes progress monotone: a loop that
    /// visits the same stop twice cannot teleport the traveller back to the earlier visit,
    /// and neither can a GPS wobble.
    public var lookAheadPositions: Int

    /// How close two candidate scores have to be before the answer is called ambiguous and
    /// the traveller is asked which direction they are going.
    public var ambiguityMargin: Double
    public var maxAmbiguousCandidates: Int

    /// How long after the last position update the ride is still believed without asking.
    ///
    /// Thirty minutes, not the active journey's ninety: a Vitrasa ride lasts ten to forty
    /// minutes, and an onboard ride has no committed arrival to measure against — only the
    /// last time the traveller's position was seen.
    public var staleGraceSeconds: TimeInterval

    public init(maxSnapMetres: Double = 400,
                lateWindowSeconds: Int32 = 25 * 60,
                earlyWindowSeconds: Int32 = 10 * 60,
                offRideMetres: Double = 600,
                lookAheadPositions: Int = 8,
                ambiguityMargin: Double = 0.15,
                maxAmbiguousCandidates: Int = 4,
                staleGraceSeconds: TimeInterval = 30 * 60) {
        self.maxSnapMetres = maxSnapMetres
        self.lateWindowSeconds = lateWindowSeconds
        self.earlyWindowSeconds = earlyWindowSeconds
        self.offRideMetres = offRideMetres
        self.lookAheadPositions = lookAheadPositions
        self.ambiguityMargin = ambiguityMargin
        self.maxAmbiguousCandidates = maxAmbiguousCandidates
        self.staleGraceSeconds = staleGraceSeconds
    }
}
