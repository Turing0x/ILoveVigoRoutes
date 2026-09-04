import Foundation

/// Every tunable number the journey planner uses, gathered in one value.
///
/// These are policy, not physics. Each one trades journeys found against journeys a
/// person would actually accept, and every one of them is a plausible thing to want to
/// change later. Keeping them together means the engine stays a pure function of
/// `(Timetable, PlanQuery, PlannerOptions)` and the tests can dial any single number
/// without reaching into the algorithm.
public struct PlannerOptions: Sendable, Hashable {

    // MARK: - Walking

    /// 4.8 km/h. Deliberately unhurried: a walking estimate that is optimistic makes the
    /// app propose journeys that cannot be caught, which is worse than proposing none.
    public var walkSpeedMetresPerSecond: Double

    /// Straight-line distance is multiplied by this before it becomes time.
    ///
    /// There is no street graph in this app — no MKDirections, no OSM routing — so this
    /// factor is what stands in for corners, crossings and Vigo's hills. It is the reason
    /// every walking figure in the UI is labelled an estimate.
    public var walkDetourFactor: Double

    /// How far from the origin (or from the destination) a stop may be and still count as
    /// a way in or out of the network. 800 m is the figure the handoff fixes.
    public var accessRadiusMetres: Double

    /// How far a transfer on foot between two stops may be.
    ///
    /// Much shorter than `accessRadiusMetres` on purpose: a 700 m walk is a reasonable way
    /// to start a journey, but as an intermediate transfer it is nearly always worse than
    /// staying on the bus. It also bounds the size of the footpath graph, which is
    /// quadratic in the radius.
    public var maxTransferWalkMetres: Double

    // MARK: - Transfers

    /// Slack between getting off a vehicle and being able to board another at the same
    /// stop. Covers walking the length of the bus and the driver not waiting.
    public var minTransferSeconds: Int

    /// Extra slack on top of the walking time when a transfer involves changing stop.
    /// The walk estimate is already generous; this is the margin for finding the right
    /// pole on the far pavement.
    public var footpathBufferSeconds: Int

    // MARK: - Search

    /// Maximum number of vehicles in a journey, i.e. RAPTOR rounds. Four vehicles is three
    /// transfers, which is already more than anyone in a city this size will accept; the
    /// bound exists so a pathological query cannot run away.
    public var maxRounds: Int

    /// How far ahead of the requested departure time to look before giving up. Vitrasa's
    /// thinnest Sunday headways are well inside three hours, so a query that finds nothing
    /// in this window is telling the truth rather than being impatient.
    public var searchHorizon: TimeInterval

    /// How much time an extra transfer has to save before it is worth showing.
    ///
    /// RAPTOR's Pareto front routinely contains a journey that swaps a change of bus for
    /// ninety seconds. Nobody wants that alternative, and showing it crowds out the one
    /// they do want.
    public var extraTransferWorthSeconds: Int

    public init(
        walkSpeedMetresPerSecond: Double = 1.33,
        walkDetourFactor: Double = 1.35,
        accessRadiusMetres: Double = 800,
        maxTransferWalkMetres: Double = 300,
        minTransferSeconds: Int = 60,
        footpathBufferSeconds: Int = 30,
        maxRounds: Int = 4,
        searchHorizon: TimeInterval = 3 * 3600,
        extraTransferWorthSeconds: Int = 300
    ) {
        self.walkSpeedMetresPerSecond = walkSpeedMetresPerSecond
        self.walkDetourFactor = walkDetourFactor
        self.accessRadiusMetres = accessRadiusMetres
        self.maxTransferWalkMetres = maxTransferWalkMetres
        self.minTransferSeconds = minTransferSeconds
        self.footpathBufferSeconds = footpathBufferSeconds
        self.maxRounds = maxRounds
        self.searchHorizon = searchHorizon
        self.extraTransferWorthSeconds = extraTransferWorthSeconds
    }
}
