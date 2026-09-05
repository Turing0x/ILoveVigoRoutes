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

    /// How many alternatives are **shown** at once.
    ///
    /// Four is what fits on screen without scrolling past the fold, and past that the list
    /// stops being a choice and becomes a timetable.
    ///
    /// Since Fase 10 this is applied where the ordering is — `MapNavigationState.visibleJourneys`
    /// — and no longer inside the engine, which cuts by `maxCandidates` instead. The two must
    /// stay distinct: cutting the pool to what fits on screen, before the user's criterion has
    /// been applied, would pick those four by the criterion they did not choose.
    public var maxAlternatives: Int

    /// How many times RAPTOR may be re-run from a later departure to fill that list.
    ///
    /// A single run only ever varies the number of transfers: every alternative it finds
    /// leaves at the same time. What a passenger actually wants next to "this bus" is "the
    /// one after it", and that is a second search starting just after the first boarding.
    /// The bound is what stops a pathological query turning into an unbounded scan.
    public var maxDepartureScans: Int

    /// How many journeys survive the filters and reach the ordering step.
    ///
    /// Not the same number as `maxAlternatives`, which is how many are *shown*. Once the
    /// default ordering is "least walking at the end", cutting the shortlist by arrival before
    /// the user's preference is applied would decide the answer by the criterion they did not
    /// pick. This is the pool that preference chooses from.
    public var maxCandidates: Int

    /// How many alighting stops may be reconstructed per round.
    ///
    /// A destination usually has several stops within `accessRadiusMetres`, and they trade
    /// against each other: one is reached sooner, another leaves a shorter walk. Reconstructing
    /// only the fastest — as the planner did before Fase 10 — means the journey that walks
    /// least is not filtered out later, it is **never generated**, and a "least walking"
    /// ordering would be reordering options that were all chosen for speed.
    ///
    /// Three because the Pareto front here is small by nature: only stops that buy closeness
    /// with time are on it at all.
    public var maxEgressCandidates: Int

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
        maxAlternatives: Int = 4,
        maxDepartureScans: Int = 4,
        maxCandidates: Int = 8,
        maxEgressCandidates: Int = 3,
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
        self.maxAlternatives = maxAlternatives
        self.maxDepartureScans = maxDepartureScans
        self.maxCandidates = maxCandidates
        self.maxEgressCandidates = maxEgressCandidates
        self.extraTransferWorthSeconds = extraTransferWorthSeconds
    }
}
