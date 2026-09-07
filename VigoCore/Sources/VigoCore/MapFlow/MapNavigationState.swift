import Foundation

/// Every piece of "where am I in the map flow" state, as a value type with pure transitions.
///
/// This exists as a `struct` in `VigoCore`, and not as the `@Observable` class the app
/// actually holds, for one reason: it can be exercised end to end by `swift test` on the
/// Mac, with no simulator and no device. The app-side model owns one of these, forwards
/// gestures to it, and adds only what genuinely needs a device — the planner call, the
/// geocoder, `@AppStorage`, CoreLocation.
///
/// The rule this type enforces is that **the views never decide transitions**. A view
/// translates a gesture into one method call here and then draws whatever `mode` says. The
/// alternative — a handful of `@State` booleans that can contradict each other
/// (`isSearching && selected != nil && isRouting`) — is the classic way a screen like this
/// rots, and it is untestable by construction.
public struct MapNavigationState: Sendable {

    /// Which surface is in front. Payload only for what is genuinely scoped to that surface;
    /// the route ends and results live in stored properties because they must survive going
    /// into a journey's detail and back out.
    public enum Mode: Sendable, Hashable {
        /// Clean map. No sheet — the tab bar has to stay reachable while other tabs exist.
        case browsing
        case searching
        /// A place is selected and its card is up. No route asked for yet.
        case place(MapPlace)
        /// Origin and destination are set; `route` says whether the answer is in.
        case routing
        /// One alternative, leg by leg.
        case journeyDetail
    }

    /// The planner's answer, in the three shapes the UI actually draws.
    ///
    /// Not `Equatable`: `PlanOutcome` is not, and making it so would mean editing Fase 3's
    /// planner for the convenience of a test. The accessors below are what the tests and the
    /// views read anyway.
    public enum RouteState: Sendable {
        case idle
        case planning
        /// `walkOnly` is `true` for `PlanOutcome.walkOnly`, where the single "alternative"
        /// is the direct walk. Kept as a flag rather than a separate case so the list has
        /// one shape to draw.
        case alternatives([Journey], walkOnly: Bool)
        /// Any outcome that is not a journey. The text for each is not this type's job.
        case failed(PlanOutcome)

        public var isPlanning: Bool { if case .planning = self { true } else { false } }

        public var journeys: [Journey] {
            if case .alternatives(let journeys, _) = self { return journeys }
            return []
        }

        public var isWalkOnly: Bool {
            if case .alternatives(_, let walkOnly) = self { return walkOnly }
            return false
        }

        public var failure: PlanOutcome? {
            if case .failed(let outcome) = self { return outcome }
            return nil
        }
    }

    /// When the journey should leave.
    public enum Departure: Sendable, Hashable {
        case now
        case at(Date)

        public func date(now: Date) -> Date {
            switch self {
            case .now: now
            case .at(let date): date
            }
        }
    }

    // MARK: - State

    public private(set) var mode: Mode = .browsing
    public private(set) var origin: MapPlace?
    public private(set) var destination: MapPlace?
    public private(set) var route: RouteState = .idle
    /// Which alternative is highlighted on the map and in the list. Always a valid index
    /// into `route.journeys` when there are any, `0` otherwise.
    public private(set) var selectedAlternative = 0

    /// How the alternatives are ordered for the person reading them.
    ///
    /// Presentation, never a new question: changing it reorders journeys already computed and
    /// never re-plans. A tap on the menu that cost four RAPTOR passes and up to sixteen
    /// `shapePoint` reads would be a very expensive way to sort a list of four.
    public private(set) var ordering: JourneyOrdering = .default

    /// How the traveller gets about on foot (C3).
    ///
    /// **Not the same kind of setting as `ordering`.** Changing the ordering reorders
    /// journeys already computed; changing this one changes which journeys exist, because
    /// 62 of the measured transfers have no wheelchair route at all. So it invalidates the
    /// current answer rather than resorting it, and `setAccessibility` says so by clearing
    /// the route — leaving stale walking journeys on screen under a wheelchair label would
    /// be the worst lie this app could tell.
    public private(set) var accessibility: AccessibilityProfile = .standard
    public var departure: Departure = .now

    /// True while the origin is still whatever the device last reported.
    ///
    /// Same contract Fase 3 settled on for `PlannerModel`, and for the same reason: the
    /// default origin is "where I am" and it keeps up with the device, but the moment the
    /// user picks one by hand — or swaps the two ends — a later fix must not quietly
    /// overwrite it.
    public private(set) var originFollowsLocation = true

    /// Last known device position. Held here so `routeQuery` is a pure function of the
    /// state, with nothing to ask CoreLocation at the moment of planning.
    public private(set) var currentLocation: Coordinate?

    /// True while the map is following the user along an open journey.
    ///
    /// What this turns on is not a screen — the map is already the screen — but three things
    /// that cost something to keep on: a camera that tracks heading, the screen kept awake,
    /// and a finer location accuracy. All three are worth it while walking to a stop and
    /// wasteful the rest of the time, so the flag has to switch off on its own whenever the
    /// journey underneath it stops being the one being followed.
    public private(set) var isFollowing = false

    public init() {}

    // MARK: - Selection

    /// The place card, from any source: a stop marker, an Apple POI, a pressed point, a
    /// search result.
    public mutating func select(_ place: MapPlace) {
        mode = .place(place)
    }

    /// The place whose card is showing, if any.
    public var selectedPlace: MapPlace? {
        if case .place(let place) = mode { return place }
        return nil
    }

    /// What the map's selection binding must call when it resolves to nothing.
    ///
    /// **Not the same as a `nil` binding.** Verified on device in the Fase 5 spike:
    /// deselecting by tapping empty map leaves a *non-nil* `MapSelection` whose `value` and
    /// `feature` are both `nil`, because `MapSelection.init(_ feature: MapFeature?)` accepts
    /// `nil`. Treating "binding is not nil" as "something is selected" would leave the sheet
    /// up forever. Only clears the card — a route in progress is not cancelled by
    /// deselecting a pin.
    public mutating func clearSelection() {
        if case .place = mode { mode = .browsing }
    }

    // MARK: - Search

    public mutating func beginSearch() { mode = .searching }

    public mutating func cancelSearch() {
        if case .searching = mode { mode = .browsing }
    }

    // MARK: - Routing

    /// "Cómo llegar" on the selected place. The destination is that place; the origin is the
    /// device's position unless the user has already pinned one.
    ///
    /// - Returns: `true` when the flow moved to `.routing`. `false` means there was nothing
    ///   to route to (no place selected), or no origin available — both of which the caller
    ///   must be able to tell apart from "planning failed".
    @discardableResult
    public mutating func routeToSelectedPlace() -> Bool {
        guard let place = selectedPlace else { return false }
        return route(to: place)
    }

    /// Same thing from anywhere: a saved journey, a search result taken straight to a route.
    @discardableResult
    public mutating func route(to place: MapPlace) -> Bool {
        if originFollowsLocation || origin == nil {
            guard let currentLocation else { return false }
            origin = .currentLocation(currentLocation)
        }
        destination = place
        route = .idle
        selectedAlternative = 0
        mode = .routing
        return true
    }

    /// Both ends at once — a saved journey tapped from the search sheet, where there is
    /// nothing to ask the GPS because the user stored both ends themselves.
    ///
    /// Turns off location following for the same reason `setOrigin` does: an origin that came
    /// from something the user saved is theirs, and a later fix must not quietly replace it.
    @discardableResult
    public mutating func route(from origin: MapPlace, to destination: MapPlace) -> Bool {
        self.origin = origin
        self.destination = destination
        originFollowsLocation = false
        route = .idle
        selectedAlternative = 0
        mode = .routing
        return true
    }

    public mutating func setOrigin(_ place: MapPlace) {
        origin = place
        // An origin the user picked is theirs, even when they picked "Mi ubicación" from a
        // list: that is a snapshot of a moment, not a subscription to the GPS. Only
        // `updateCurrentLocation` re-arms following, and only while it is still armed.
        originFollowsLocation = false
        invalidateResult()
    }

    public mutating func setDestination(_ place: MapPlace) {
        destination = place
        invalidateResult()
    }

    /// Back to an origin that tracks the device.
    public mutating func followCurrentLocation() {
        originFollowsLocation = true
        if let currentLocation { origin = .currentLocation(currentLocation) }
        invalidateResult()
    }

    public mutating func swapEnds() {
        swap(&origin, &destination)
        // After a swap the origin is whatever used to be the destination — a place the user
        // chose. Letting the GPS keep writing over it would silently undo the swap.
        originFollowsLocation = false
        invalidateResult()
    }

    /// A fresh fix from the device. Ignored as an origin once the origin belongs to the user.
    public mutating func updateCurrentLocation(_ coordinate: Coordinate) {
        currentLocation = coordinate
        guard originFollowsLocation else { return }
        origin = .currentLocation(coordinate)
    }

    /// Drops a stale answer whenever the question changes. Without this the map would go on
    /// drawing the previous route's polylines under newly edited endpoints.
    private mutating func invalidateResult() {
        route = .idle
        selectedAlternative = 0
        // Whatever was being followed no longer exists as an answer.
        isFollowing = false
        if case .journeyDetail = mode { mode = .routing }
    }

    /// The query to hand `JourneyPlanner`, or `nil` when the state cannot form one.
    ///
    /// Pure: `now` is passed in rather than read, so a test can pin the clock.
    public func routeQuery(now: Date) -> PlanQuery? {
        guard let origin, let destination else { return nil }
        return PlanQuery(origin: origin.place, destination: destination.place,
                         departure: departure.date(now: now),
                         accessibility: accessibility)
    }

    // MARK: - Planning

    public mutating func planningStarted() {
        route = .planning
        selectedAlternative = 0
        isFollowing = false
    }

    /// How the schedule behind the current answer was arrived at (A2).
    ///
    /// Held on the state rather than derived at render time because the view that shows it
    /// is not the one that ran the plan, and a projected answer must not survive into the
    /// next search: `planningFinished` resets it every time, so a stale "estimated" banner
    /// over firm data is unrepresentable.
    public private(set) var schedule: ServiceDaySource = .observed

    /// The sentence to show above the alternatives, or `nil` when there is nothing to
    /// qualify — either because the data is the operator's own, or because there are no
    /// journeys on screen to qualify in the first place.
    ///
    /// Gated on `route` rather than on `schedule` alone. Six different transitions reset the
    /// route to `.idle` (clearing an endpoint, picking a new place, `reset`), and requiring
    /// each of them to remember to clear the schedule as well is exactly the kind of
    /// bookkeeping that rots — one missed site and an "estimated" banner floats above a
    /// perfectly firm set of results. Tying the notice to the thing it annotates makes the
    /// stale state unreachable instead of merely unlikely.
    public var estimateNotice: String? {
        guard case .alternatives = route else { return nil }
        return PlanOutcomeMessage.estimateNotice(schedule)
    }

    /// Folds a `PlanOutcome` into the three shapes the UI draws.
    public mutating func planningFinished(_ outcome: PlanOutcome,
                                          schedule: ServiceDaySource = .observed) {
        self.schedule = schedule
        switch outcome {
        case .journeys(let journeys):
            // An empty list is not a success with nothing in it; it is the same "found
            // nothing" as `noJourneyFound`, and must not render as an empty list.
            route = journeys.isEmpty
                ? .failed(.noJourneyFound(horizon: 0))
                : .alternatives(journeys, walkOnly: false)
        case .walkOnly(let journey):
            route = .alternatives([journey], walkOnly: true)
        default:
            route = .failed(outcome)
        }
        selectedAlternative = 0
    }

    /// Planning threw rather than returning an outcome. Kept distinct so the caller can say
    /// so honestly instead of dressing it up as "no route found".
    public mutating func planningFailed() {
        route = .idle
        schedule = .observed
    }

    // MARK: - Alternatives

    public mutating func selectAlternative(at index: Int) {
        guard visibleJourneys.indices.contains(index) else { return }
        guard index != selectedAlternative else { return }
        selectedAlternative = index
        // Following is about *this* journey. Highlighting another one and carrying the
        // follow over would point the camera down a route the user just stopped choosing.
        isFollowing = false
    }

    /// The alternatives actually shown, in the chosen order.
    ///
    /// The planner hands back a larger pool than fits on screen (`maxCandidates`), precisely so
    /// that the criterion picked here decides which of them are seen. Cutting that pool any
    /// earlier would choose the visible four by a criterion the user did not pick — which is
    /// the whole failure mode Fase 10 exists to avoid.
    public var visibleJourneys: [Journey] {
        ordering.apply(route.journeys, limit: visibleLimit)
    }

    /// How many alternatives are shown at once. Mirrors `PlannerOptions.maxAlternatives`, which
    /// the state has no reason to depend on the planner for.
    public var visibleLimit = 4

    /// Changes the criterion, and resets what was pointing at the old order.
    ///
    /// `selectedAlternative` is an index into `visibleJourneys`, so reordering silently makes
    /// it point at a different journey: the map would highlight one route while the list
    /// highlighted another. Back to the top, and following off — the same argument already
    /// written into `selectAlternative(at:)`.
    /// Switches profile and drops the current answer, which was computed for the other one.
    ///
    /// Returns whether the caller needs to plan again. `false` when nothing changed, so a
    /// repeated tap on the current profile does not cost a search.
    @discardableResult
    public mutating func setAccessibility(_ profile: AccessibilityProfile) -> Bool {
        guard profile != accessibility else { return false }
        accessibility = profile
        route = .idle
        selectedAlternative = 0
        isFollowing = false
        schedule = .observed
        return true
    }

    public mutating func setOrdering(_ ordering: JourneyOrdering) {
        guard ordering != self.ordering else { return }
        self.ordering = ordering
        selectedAlternative = 0
        isFollowing = false
    }

    public var currentJourney: Journey? {
        let journeys = visibleJourneys
        guard journeys.indices.contains(selectedAlternative) else { return nil }
        return journeys[selectedAlternative]
    }

    // MARK: - Seguimiento

    /// Starts following, but only from an open journey.
    ///
    /// Following a route nobody is looking at would keep the screen awake and the GPS at full
    /// accuracy for nothing, so the precondition is part of the state machine rather than a
    /// check the view is trusted to remember.
    @discardableResult
    public mutating func startFollowing() -> Bool {
        guard case .journeyDetail = mode, currentJourney != nil else { return false }
        isFollowing = true
        return true
    }

    public mutating func stopFollowing() { isFollowing = false }

    /// Opens the highlighted alternative leg by leg. No-op when there is nothing to open.
    @discardableResult
    public mutating func openSelectedAlternative() -> Bool {
        guard currentJourney != nil else { return false }
        mode = .journeyDetail
        return true
    }

    // MARK: - Going back

    /// One level back, from anywhere. Written as one table on purpose: "back" from a sheet
    /// that can be dragged down, tapped away, or closed with an X has to land somewhere
    /// predictable, and scattering that decision across three gesture handlers is how it
    /// stops being predictable.
    ///
    /// `.journeyDetail` → `.routing` (the alternatives are still there, and going straight
    /// to a clean map from a leg list is the jarring bit users notice first).
    /// `.routing` → the destination's card, which is where the route was asked for.
    /// `.place` / `.searching` → the clean map. `.browsing` → nowhere; it is the floor.
    public mutating func dismiss() {
        // Following is a level of its own, above the leg list: someone who taps back while
        // the camera is chasing them means "stop chasing me", not "close the journey".
        if isFollowing {
            isFollowing = false
            return
        }
        switch mode {
        case .journeyDetail:
            mode = .routing
        case .routing:
            if let destination {
                mode = .place(destination)
            } else {
                mode = .browsing
            }
        case .place, .searching:
            mode = .browsing
        case .browsing:
            break
        }
    }

    /// All the way out: clean map, no route, no selection. The X on the sheet, and what a
    /// new search should start from.
    public mutating func reset() {
        mode = .browsing
        isFollowing = false
        destination = nil
        route = .idle
        selectedAlternative = 0
        departure = .now
    }
}
