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
        if case .journeyDetail = mode { mode = .routing }
    }

    /// The query to hand `JourneyPlanner`, or `nil` when the state cannot form one.
    ///
    /// Pure: `now` is passed in rather than read, so a test can pin the clock.
    public func routeQuery(now: Date) -> PlanQuery? {
        guard let origin, let destination else { return nil }
        return PlanQuery(origin: origin.place, destination: destination.place,
                         departure: departure.date(now: now))
    }

    // MARK: - Planning

    public mutating func planningStarted() {
        route = .planning
        selectedAlternative = 0
    }

    /// Folds a `PlanOutcome` into the three shapes the UI draws.
    public mutating func planningFinished(_ outcome: PlanOutcome) {
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
    }

    // MARK: - Alternatives

    public mutating func selectAlternative(at index: Int) {
        guard route.journeys.indices.contains(index) else { return }
        selectedAlternative = index
    }

    public var currentJourney: Journey? {
        let journeys = route.journeys
        guard journeys.indices.contains(selectedAlternative) else { return nil }
        return journeys[selectedAlternative]
    }

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
        destination = nil
        route = .idle
        selectedAlternative = 0
        departure = .now
    }
}
