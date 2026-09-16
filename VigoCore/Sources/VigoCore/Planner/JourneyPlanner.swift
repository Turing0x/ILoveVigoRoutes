import Foundation

public struct PlanQuery: Sendable, Hashable {
    public let origin: Place
    public let destination: Place
    /// Earliest the journey may leave. "Salir ahora" is just `Date()` passed here.
    public let departure: Date
    /// How the traveller gets about on foot (C3).
    ///
    /// A property of the question, not of the app. Somebody may plan one journey for
    /// themselves and the next for a relative, and a setting stored at launch would make
    /// that a trip to the settings screen and back. It is also what lets one `JourneyPlanner`
    /// and one `TimetableStore` serve both profiles.
    public let accessibility: AccessibilityProfile

    public init(origin: Place, destination: Place, departure: Date,
                accessibility: AccessibilityProfile = .standard) {
        self.origin = origin; self.destination = destination; self.departure = departure
        self.accessibility = accessibility
    }
}

/// Every way `JourneyPlanner.plan` can honestly answer, success included.
///
/// The distinction between `outsideFeedWindow` and `noServiceOnDay` is load-bearing, not
/// pedantry: the feed only covers seven days, and "I have no data for that day" is a
/// different fact from "there is no service that day" — confusing the two is exactly the
/// kind of silent wrong answer this project's design explicitly rules out (`README.md`).
public enum PlanOutcome: Sendable {
    case journeys([Journey])
    /// No bus reaches the destination at all (H-19). A walk that merely beats every bus
    /// by raw arrival time is folded into `.journeys` instead of hiding them: under "least
    /// walking" a walk-only journey is the worst possible answer by definition, so a search
    /// that could otherwise offer real alternatives must not present only this one.
    case walkOnly(Journey)
    case noStopsNearOrigin(radiusMetres: Double)
    case noStopsNearDestination(radiusMetres: Double)
    case outsideFeedWindow(ClosedRange<ServiceDate>)
    case noServiceOnDay(ServiceDate)
    case noJourneyFound(horizon: TimeInterval)
    /// The bus the traveller said they were on can no longer be found in the timetable — the
    /// feed was reimported and reshaped the line, or no service of it is running at this hour.
    /// Distinct from every case above because the fix is not another search: it is asking the
    /// traveller again which bus they are on.
    case onboardRideUnresolvable(OnboardRideResolution.Failure)
    case noData
}

public struct PlanResult: Sendable {
    public let outcome: PlanOutcome
    public let feedStatus: FeedStatus
    public let computeDuration: TimeInterval

    /// Whether the timetable behind these journeys was observed or projected (A2).
    ///
    /// **Never merely decorative.** The published feed covers seven days; beyond that the
    /// planner reuses the services of the most recent matching day, and the operator will
    /// have changed some of them by the time that day arrives. A caller that shows these
    /// times without saying so is presenting a guess as the operator's own data, which is
    /// the one thing `README.md` rules out. `PlanOutcomeMessage.estimateNotice` is the
    /// sentence to show.
    public let schedule: ServiceDaySource

    /// A clearly better stop nearby, when the origin was a stop the traveller chose.
    ///
    /// Always `nil` for any other origin: a coordinate already searches every stop within
    /// walking distance, so there is nothing that search could have left out.
    public let nearbyStopHint: NearbyStopHint?

    public init(outcome: PlanOutcome, feedStatus: FeedStatus,
                computeDuration: TimeInterval, schedule: ServiceDaySource = .observed,
                nearbyStopHint: NearbyStopHint? = nil) {
        self.outcome = outcome
        self.feedStatus = feedStatus
        self.computeDuration = computeDuration
        self.schedule = schedule
        self.nearbyStopHint = nearbyStopHint
    }
}

/// The public facade: resolves places to stops, checks the feed can answer the question at
/// all, runs RAPTOR against a cached `Timetable`, reconstructs and fits the alternatives,
/// and never lets a "no journey" answer look like a crash.
public struct JourneyPlanner: Sendable {
    let repository: TransitRepository
    let store: TimetableStore
    let options: PlannerOptions
    /// Must be the same calendar `store` builds its timetables with, or the planner would
    /// label an answer by one rule and compute it by another.
    let holidays: HolidayCalendar

    public init(repository: TransitRepository, store: TimetableStore,
                options: PlannerOptions = PlannerOptions(),
                holidays: HolidayCalendar = .bundled) {
        self.repository = repository
        self.store = store
        self.options = options
        self.holidays = holidays
    }

    public func plan(_ query: PlanQuery) async throws -> PlanResult {
        let started = Date()
        // The profile belongs to the request, so every walking figure in this search comes
        // from options that already know it — the speed, the detour factors and, through
        // `store`, which measured street network the transfers were routed over.
        var options = self.options
        options.accessibility = query.accessibility
        let walk = WalkModel(options: options)

        var hint: NearbyStopHint?
        func finish(_ outcome: PlanOutcome, feedStatus: FeedStatus,
                    schedule: ServiceDaySource = .observed) -> PlanResult {
            PlanResult(outcome: outcome, feedStatus: feedStatus,
                       computeDuration: Date().timeIntervalSince(started),
                       schedule: schedule, nearbyStopHint: hint)
        }

        let feedStatus = try repository.feedStatus()
        guard feedStatus.hasData else { return finish(.noData, feedStatus: feedStatus) }

        let originCoordinate = query.origin.coordinate
        let destinationCoordinate = query.destination.coordinate
        let access = try repository.nearbyStops(
            latitude: originCoordinate.latitude, longitude: originCoordinate.longitude,
            radiusMetres: options.accessRadiusMetres, limit: options.maxNearbyStops)
        guard !access.isEmpty else {
            return finish(.noStopsNearOrigin(radiusMetres: options.accessRadiusMetres), feedStatus: feedStatus)
        }
        let egress = try repository.nearbyStops(
            latitude: destinationCoordinate.latitude, longitude: destinationCoordinate.longitude,
            radiusMetres: options.accessRadiusMetres, limit: options.maxNearbyStops)
        guard !egress.isEmpty else {
            return finish(.noStopsNearDestination(radiusMetres: options.accessRadiusMetres), feedStatus: feedStatus)
        }

        let day = ServiceDate(query.departure, calendar: repository.calendar)
        // A2. The feed's seven-day window is no longer the end of the conversation: a day
        // past it can borrow the services of the most recent day of the same kind, and the
        // answer says so. `.outsideFeedWindow` now means what it says — nobody can answer
        // this, not even by estimate — rather than "the feed is a week long".
        let resolver = try repository.serviceDayResolver(
            holidays: holidays, maxProjectionDays: options.maxProjectionDays)
        guard let resolved = resolver.resolve(day) else {
            let reported = feedStatus.window ?? (day...day)
            // Inside the window with nothing running is a different fact from beyond it,
            // and the two send the user to different places: one waits for a refresh, the
            // other picks another day.
            if let window = feedStatus.window, window.contains(day) {
                return finish(.noServiceOnDay(day), feedStatus: feedStatus)
            }
            return finish(.outsideFeedWindow(reported), feedStatus: feedStatus)
        }
        guard try !repository.activeServiceIDs(on: resolved.template).isEmpty else {
            return finish(.noServiceOnDay(day), feedStatus: feedStatus)
        }
        let schedule = resolved.source

        let timetable = try await store.timetable(anchor: day, profile: query.accessibility)
        let radiusWalks = access.compactMap { nearby -> StopWalk? in
            guard let index = timetable.index(of: nearby.stop.id) else { return nil }
            return StopWalk(stop: index, seconds: Int32(walk.seconds(metres: nearby.distanceMetres,
                                                                     as: .accessEgress)))
        }
        // A stop chosen as origin is where the traveller is standing, not a point to search
        // around. Searching the radius from it let a bus from a stop five minutes' walk away
        // replace every bus from the chosen one in the same RAPTOR round — the 5720 → Concello
        // case, where the 4C at the traveller's own stop was never offered. A stop with no
        // service in this timetable gets no access at all rather than a quiet fall back to the
        // radius: the hint below is where the other stops are allowed to speak.
        let anchor: Stop?
        let accessWalks: [StopWalk]
        switch query.origin {
        case .stop(let stop):
            anchor = stop
            accessWalks = timetable.index(of: stop.id).map { [StopWalk(stop: $0, seconds: 0)] } ?? []
        case .coordinate:
            anchor = nil
            accessWalks = radiusWalks
        }
        let egressWalks = egress.compactMap { nearby -> StopWalk? in
            guard let index = timetable.index(of: nearby.stop.id) else { return nil }
            return StopWalk(stop: index, seconds: Int32(walk.seconds(metres: nearby.distanceMetres,
                                                                     as: .accessEgress)))
        }
        // RAPTOR is pure CPU, and `scan` runs it up to `maxDepartureScans` times in a row
        // with no suspension point in between. `plan` itself is not actor-isolated, so
        // calling it from `@MainActor` code (the planner screen) would otherwise run every
        // one of those passes on the main thread — invisible at one pass, a visible stall
        // once several run back to back. Detaching hands the whole batch to a background
        // thread; only the tiny result crosses back.
        let (alternatives, unanchored) = try await Task.detached(priority: .userInitiated) {
            let alternatives = self.scan(timetable: timetable, access: accessWalks,
                                         egress: egressWalks, query: query, options: options)
            // Only a chosen stop needs the comparison; for a coordinate this second pass would
            // be the first one again.
            let unanchored = anchor == nil ? [] : self.scan(timetable: timetable, access: radiusWalks,
                                                            egress: egressWalks, query: query,
                                                            options: options)
            return (alternatives, unanchored)
        }.value
        if let anchor {
            hint = NearbyStopHint.choose(origin: anchor, anchored: alternatives,
                                         unanchored: unanchored,
                                         minimumGain: options.nearbyStopHintMinimumGain)
        }

        // A direct walk has no radius limit of its own, but one that would take longer than
        // the bus search is willing to look is not a "faster than the bus" fallback — it is
        // the same "nothing reasonable found" as an empty bus search.
        let directWalkSeconds = walk.seconds(from: originCoordinate, to: destinationCoordinate,
                                             as: .accessEgress)
        let walkIsViable = TimeInterval(directWalkSeconds) <= options.searchHorizon
        func walkOnlyJourney() -> Journey {
            Journey(legs: [.walk(from: query.origin, to: query.destination,
                                 seconds: directWalkSeconds,
                                 metres: walk.metres(from: originCoordinate, to: destinationCoordinate))],
                    departure: query.departure,
                    arrival: query.departure.addingTimeInterval(TimeInterval(directWalkSeconds)),
                    transfers: 0)
        }

        guard !alternatives.isEmpty else {
            guard walkIsViable else {
                return finish(.noJourneyFound(horizon: options.searchHorizon), feedStatus: feedStatus,
                              schedule: schedule)
            }
            return finish(.walkOnly(walkOnlyJourney()), feedStatus: feedStatus, schedule: schedule)
        }
        // H-19: the walk is folded into the same pool the bus alternatives came from,
        // rather than replacing them outright whenever it happens to arrive first. Under
        // "menos caminata" a walk-only journey is the worst possible answer by construction
        // (`JourneyOrdering.egressWalkSeconds` counts the whole thing as final walk), so a
        // bus that leaves it undominated — a real trade of time for not walking the whole
        // way — is exactly the alternative that criterion exists to surface, not to hide
        // behind a walk that merely has the earliest raw arrival.
        guard walkIsViable else {
            return finish(.journeys(alternatives), feedStatus: feedStatus, schedule: schedule)
        }
        return finish(.journeys(ranked(alternatives + [walkOnlyJourney()], options)),
                      feedStatus: feedStatus, schedule: schedule)
    }

    // MARK: - Alternatives across departures

    /// Runs RAPTOR once per departure time and collects what each run finds.
    ///
    /// One run only ever varies the vehicles taken: every journey it returns leaves at the
    /// same moment and differs in transfers. That is a poor answer to "show me the options"
    /// in a city where the real choice is usually *this* bus or the next one, so each pass
    /// restarts the search one second after the earliest boarding the previous pass used —
    /// which forces the next run onto a strictly later vehicle. `maxDepartureScans` bounds
    /// the work and the search horizon bounds how far ahead the last pass may look, so the
    /// loop always terminates.
    private func scan(timetable: Timetable, access: [StopWalk], egress: [StopWalk],
                     query: PlanQuery, options: PlannerOptions) -> [Journey] {
        let start = Int32(timetable.axisSeconds(for: query.departure))
        // The one place an external `Date` enters the axis `RaptorEngine` does its `&+`/`&-`
        // arithmetic on (H-16, `Timetable`'s own doc comment has the full argument). `plan`
        // already turned away anything outside the feed's window before this is ever
        // called, so this is a documentation-as-code check, not a defence against a caller
        // that could otherwise reach here — ten days is generous headroom either side of the
        // roughly two the timetable itself ever spans.
        assert(abs(start) < Int32(10 * 86_400), "departure is nowhere near the timetable's axis")
        let deadline = start &+ Int32(options.searchHorizon)
        var departure = start
        var collected: [Journey] = []

        for _ in 0..<max(1, options.maxDepartureScans) {
            let batch = search(timetable: timetable, access: access, egress: egress,
                               departure: departure, deadline: deadline, query: query,
                               options: options)
            guard !batch.isEmpty else { break }
            collected.append(contentsOf: batch)
            guard ranked(collected, options).count < options.maxCandidates,
                  let boarding = firstBoardingSeconds(of: batch, timetable: timetable)
            else { break }
            departure = boarding &+ 1
            guard departure <= deadline else { break }
        }
        return ranked(collected, options)
    }

    private func search(timetable: Timetable, access: [StopWalk], egress: [StopWalk],
                       departure: Int32, deadline: Int32, query: PlanQuery,
                       options: PlannerOptions) -> [Journey] {
        let raptorQuery = RaptorQuery(access: access, egress: egress,
                                      departure: departure, horizon: deadline &- departure)
        let result = RaptorEngine(options: options).run(timetable, raptorQuery)
        return JourneyReconstruction.alternatives(
            timetable: timetable, result: result, query: raptorQuery,
            origin: query.origin, destination: query.destination, options: options)
    }

    /// The earliest moment any journey in `batch` gets on a vehicle. Restarting after it is
    /// what makes the next pass find a later bus rather than the same one again. A journey
    /// with no ride at all cannot say anything about that, and is ignored.
    private func firstBoardingSeconds(of batch: [Journey], timetable: Timetable) -> Int32? {
        var earliest: Int32?
        for journey in batch {
            for leg in journey.legs {
                guard case .ride(_, _, _, _, _, _, let departure, _, _) = leg else { continue }
                let seconds = Int32(timetable.axisSeconds(for: departure))
                if earliest == nil || seconds < earliest! { earliest = seconds }
                break
            }
        }
        return earliest
    }

    /// Turns everything collected into the pool actually worth offering: no duplicates, no
    /// dominated options, nothing no criterion would want, soonest arrival first.
    ///
    private func ranked(_ journeys: [Journey], _ options: PlannerOptions) -> [Journey] {
        var seen = Set<Journey>()
        var unique: [Journey] = []
        for journey in journeys where seen.insert(journey).inserted { unique.append(journey) }
        let front = JourneyShortlist.plausible(JourneyShortlist.undominated(unique),
                                               slack: options.alternativeSlackSeconds)
        return JourneyShortlist.cut(front, to: options.maxCandidates)
    }
}
