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

    /// How the traveller gets about on foot (C3).
    ///
    /// Selects which measured street network the walking is routed over, and which of the
    /// two speeds applies. **Not cosmetic**: 62 of the 3220 measured transfers have no
    /// wheelchair route at all, because the only pedestrian link between those two stops is
    /// a flight of steps.
    ///
    /// What this deliberately does **not** do is filter stops by the GTFS
    /// `wheelchair_boarding` field. Every one of the feed's 1154 stops declares itself
    /// accessible, and so does every one of its 3801 trips. A filter on those columns would
    /// be a no-op that nonetheless *looked* like a wheelchair mode — the worst possible
    /// outcome, because the person relying on it has the least room to absorb a wrong
    /// answer. `Stop.wheelchairBoarding` is imported and available for the day the operator
    /// starts distinguishing; until then the honest claim this app can make is about the
    /// pavement, not about the kerb or the ramp, and that is the claim the UI makes.
    public var accessibility: AccessibilityProfile

    /// Metres per second for a wheelchair user, used in place of `walkSpeedMetresPerSecond`
    /// when `accessibility` is `.wheelchair`.
    ///
    /// 1.0 m/s. Errs slow for the same reason the walking figure does — an optimistic
    /// estimate offers a bus that cannot be caught — and the margin matters more here, since
    /// the cost of missing it is higher. A number to revise from real use, not a measured
    /// one; it is separate and named so it can be revised without touching the walking one.
    public var wheelchairSpeedMetresPerSecond: Double

    /// The speed that actually applies, given the profile.
    public var effectiveWalkSpeed: Double {
        switch accessibility {
        case .standard:   walkSpeedMetresPerSecond
        case .wheelchair: wheelchairSpeedMetresPerSecond
        }
    }

    /// Straight-line distance from the origin to a stop — or from a stop to the destination
    /// — is multiplied by this before it becomes time.
    ///
    /// There is no street graph in this app — no MKDirections, no OSM routing — so this and
    /// `transferDetourFactor` are what stand in for corners, crossings and Vigo's hills.
    /// They are the reason every walking figure in the UI is labelled an estimate.
    ///
    /// **Two numbers and not one, because the two errors do not cost the same.** Measured
    /// against a real pedestrian street graph over fourteen stop pairs of 150–800 m in Vigo
    /// (`AUDITORIA-MOTOR-VS-CONCELLO.md` §3, F-2), the ratio of street distance to
    /// straight-line distance came out at p50 1.23, p90 1.66, max 1.86, mean 1.33. A single
    /// factor of 1.35 is an excellent estimate of that *mean* and a poor one of any
    /// individual pair: the per-pair error ran from −28 % to +29 %.
    ///
    /// Underestimating an access walk hands the user a bus they cannot catch — the loudest
    /// failure this planner has, and the one that made this split worth doing. Overestimating
    /// one only drops an option that a later departure scan or a nearer stop usually
    /// recovers. So this figure is deliberately pessimistic, between the measured p50 and
    /// p90, while `transferDetourFactor` keeps the mean.
    ///
    /// A stopgap by construction: it narrows a distribution rather than replacing it. The
    /// real fix is a distance that is not straight-line at all — `MKDirections` for this end
    /// of the journey, precomputed street footpaths for the other.
    public var accessDetourFactor: Double

    /// The same, for a walk between two stops inside the network.
    ///
    /// Keeps the measured mean rather than the pessimistic figure `accessDetourFactor` uses.
    /// The asymmetry is deliberate: an overestimated transfer is not merely deprioritised,
    /// it drops out of the footpath graph entirely once it crosses `maxTransferWalkMetres`,
    /// and nothing downstream can recover a connection that was never built.
    public var transferDetourFactor: Double

    /// How long the walk to a first stop — or from a last one — may be, in minutes.
    ///
    /// **Minutes and not metres (B4).** A radius in metres is the same for everybody, which
    /// is precisely wrong for the quantity it stands in for: what bounds a sensible access
    /// walk is how long it takes, and a wheelchair user covers 800 m in thirteen minutes
    /// where a brisk walker covers it in ten. The Concello's own planner does this — it
    /// sends OTP a `maxWalkDistance` computed as `maxWalkTime × walkSpeed`
    /// (`AUDITORIA-MOTOR-VS-CONCELLO.md` §2.5) — and it is the reason their "walk slowly"
    /// setting is coherent and ours was not.
    ///
    /// Fifteen minutes, chosen to reproduce the 800 m straight-line radius the handoff
    /// fixed: at 1.33 m/s through a 1.50 detour factor that is 798 m, so the default profile
    /// reaches exactly as far as it did. Changing how far the app is willing to make someone
    /// walk is a separate decision from expressing it in the right unit, and this commit is
    /// only the second one.
    ///
    /// A wheelchair user gets the same fifteen minutes, which at 1.0 m/s is 600 m. That is
    /// the point: the budget is the time, not the distance.
    public var maxAccessWalkMinutes: Double

    /// The radius that actually applies, in metres: `maxAccessWalkMinutes` at whatever speed
    /// the current profile walks, undoing the detour factor so it is a straight-line radius
    /// the way `nearbyStops` expects.
    ///
    /// Deriving it rather than storing it is what keeps the two from drifting: there is no
    /// way to set a radius that disagrees with the time it is supposed to represent.
    public var accessRadiusMetres: Double {
        maxAccessWalkMinutes * 60 * effectiveWalkSpeed / accessDetourFactor
    }

    /// How far a transfer on foot between two stops may be, in **walked** metres.
    ///
    /// Much shorter than `accessRadiusMetres` on purpose: a 700 m walk is a reasonable way
    /// to start a journey, but as an intermediate transfer it is nearly always worse than
    /// staying on the bus. It also bounds the size of the footpath graph, which is
    /// quadratic in the radius.
    ///
    /// **Walked, not straight-line — the unit changed with B2.** It used to be a
    /// straight-line radius of 300 m, which the detour factor then turned into roughly 405 m
    /// of pavement. 400 keeps that reach while making the number mean the thing a passenger
    /// experiences, and it is the figure `Tools/build_footpaths.py` generated
    /// `footpaths.csv` with: raising it here without regenerating the table widens the
    /// straight-line sweep but finds nothing new to put in it.
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

    /// How far past a criterion's own best answer a journey may cost, in perceived seconds,
    /// and still be worth offering (`JourneyShortlist.plausible`).
    ///
    /// The number that decides where a list of alternatives stops being a list of
    /// alternatives. Fifteen perceived minutes: a journey that no criterion can bring within
    /// a quarter of an hour of its own optimum is not a trade anybody is making, it is the
    /// next departure — and the next departure is what the whole list already is.
    ///
    /// Perceived, not real: the cost includes walking counted more than once and a five
    /// minute charge per transfer, so this is a looser bound on clock time than it looks.
    public var alternativeSlackSeconds: TimeInterval

    /// How far past the feed's last observed day the planner will project a timetable.
    ///
    /// The published GTFS is a rolling seven-day window, so without projection every question
    /// about next month is unanswerable — not answered badly, not answered at all. With it,
    /// the same question gets the services of the most recent matching day, clearly labelled
    /// as an estimate (`ServiceDayResolver`).
    ///
    /// Sixty days rather than the ninety-four the Concello's own planner offers: past two
    /// months a projected timetable is fiction dressed as data, and the marginal question it
    /// answers is rarer than the confidence it would misplace.
    public var maxProjectionDays: Int

    /// How many stops `nearbyStops` may return for the access and egress searches (H-11).
    ///
    /// `TransitRepository.nearbyStops` defaults to 40, a figure sized for a search sheet's
    /// results list, not for the planner — and against the real feed an 800 m radius in
    /// central Vigo already returns exactly 40, meaning that default silently caps both
    /// searches today. A stop just past the cutoff by distance can still be the one Fase 10's
    /// egress front wants: it trades a little more time for a shorter final walk, which is
    /// a real trade only if the stop is in the candidate set to begin with. `accessRadiusMetres`
    /// is the figure meant to bound this; this is headroom above what that radius has ever
    /// produced in practice, not a second radius of its own.
    public var maxNearbyStops: Int

    /// How much sooner another nearby stop must get the traveller there before a search from a
    /// chosen stop mentions it (`NearbyStopHint`).
    ///
    /// A stop picked as origin is the owner's decision, not a suggestion: the alternatives all
    /// leave from it. This is only the threshold for saying "from over there you would arrive
    /// this much earlier". Ten minutes, the owner's own figure: below that the aside is noise
    /// next to a bus that is already at the stop.
    public var nearbyStopHintMinimumGain: TimeInterval

    public init(
        walkSpeedMetresPerSecond: Double = 1.33,
        accessibility: AccessibilityProfile = .standard,
        wheelchairSpeedMetresPerSecond: Double = 1.0,
        accessDetourFactor: Double = 1.50,
        transferDetourFactor: Double = 1.35,
        maxAccessWalkMinutes: Double = 15,
        maxTransferWalkMetres: Double = 400,
        minTransferSeconds: Int = 60,
        footpathBufferSeconds: Int = 30,
        maxRounds: Int = 4,
        searchHorizon: TimeInterval = 3 * 3600,
        maxAlternatives: Int = 4,
        maxDepartureScans: Int = 4,
        maxCandidates: Int = 8,
        maxEgressCandidates: Int = 3,
        extraTransferWorthSeconds: Int = 300,
        maxNearbyStops: Int = 100,
        maxProjectionDays: Int = 60,
        alternativeSlackSeconds: TimeInterval = 900,
        nearbyStopHintMinimumGain: TimeInterval = 600
    ) {
        self.walkSpeedMetresPerSecond = walkSpeedMetresPerSecond
        self.accessibility = accessibility
        self.wheelchairSpeedMetresPerSecond = wheelchairSpeedMetresPerSecond
        self.accessDetourFactor = accessDetourFactor
        self.transferDetourFactor = transferDetourFactor
        self.maxAccessWalkMinutes = maxAccessWalkMinutes
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
        self.maxNearbyStops = maxNearbyStops
        self.maxProjectionDays = maxProjectionDays
        self.alternativeSlackSeconds = alternativeSlackSeconds
        self.nearbyStopHintMinimumGain = nearbyStopHintMinimumGain
    }
}
