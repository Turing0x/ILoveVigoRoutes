import Foundation
import Observation
import VigoCore

/// The app-side owner of the map flow.
///
/// Deliberately thin. Every decision about *where the flow is* lives in
/// `MapNavigationState` (`VigoCore`), where `swift test` can reach it without a simulator;
/// what is left here is the part that genuinely needs a device — reading the database,
/// remembering a preference, and later the planner call and CoreLocation.
///
/// The state is exposed read-only and mutated only through the methods below, so the
/// invariants `MapNavigationState` enforces cannot be sidestepped from a view.
@MainActor
@Observable
final class MapScreenModel {
    private let repository: TransitRepository
    private let planner: JourneyPlanner
    private let resolver: any MapPlaceResolving
    private let defaults: UserDefaults

    private(set) var state = MapNavigationState()

    /// Every stop in the feed, read once and re-read after a reimport. 1149 rows.
    private(set) var allStops: [Stop] = []

    /// What the stops layer should draw right now, or why it is drawing nothing.
    private(set) var layer: MapStopsLayer.Content = .stops([])

    /// Whether the stops layer is on at all.
    ///
    /// **Off by default, and that is the point of the setting**: the owner's complaint was
    /// that a map speckled with 1149 pins is noise, not information. `UserDefaults.bool`
    /// already returns `false` for a key that was never written, so "off" needs no seeding.
    var stopsVisible: Bool {
        didSet {
            guard stopsVisible != oldValue else { return }
            defaults.set(stopsVisible, forKey: Self.stopsVisibleKey)
            recomputeLayer()
        }
    }

    static let stopsVisibleKey = "map.stopsVisible"

    /// How the alternatives are ordered, remembered between launches.
    ///
    /// `UserDefaults` and not the database, by the line this project already draws: a trivial
    /// presentation preference with no relation to the user's data goes here (as
    /// `map.stopsVisible` does), and things the user creates, edits, reorders and deletes go to
    /// SQLite. An ordering criterion is the first kind.
    var ordering: JourneyOrdering {
        get { state.ordering }
        set {
            guard newValue != state.ordering else { return }
            state.setOrdering(newValue)
            defaults.set(newValue.rawValue, forKey: Self.orderingKey)
            Task { await rebuildTraces() }
        }
    }

    static let orderingKey = "route.ordering"

    private var viewport: MapStopsLayer.Viewport?

    init(repository: TransitRepository,
         planner: JourneyPlanner,
         resolver: any MapPlaceResolving = MapKitPlaceResolver(),
         defaults: UserDefaults = .standard) {
        self.repository = repository
        self.planner = planner
        self.resolver = resolver
        self.defaults = defaults
        self.stopsVisible = defaults.bool(forKey: Self.stopsVisibleKey)
        // An unwritten key, or one holding a criterion a later version removed, falls back to
        // the default rather than to whatever `rawValue` happens to be first.
        if let stored = defaults.string(forKey: Self.orderingKey),
           let restored = JourneyOrdering(rawValue: stored) {
            state.setOrdering(restored)
        }
    }

    // MARK: - Paradas

    func loadStops() {
        allStops = (try? repository.allStops()) ?? []
        recomputeLayer()
    }

    func viewportChanged(to viewport: MapStopsLayer.Viewport) {
        self.viewport = viewport
        recomputeLayer()
    }

    private func recomputeLayer() {
        guard stopsVisible, let viewport else {
            layer = .stops([])
            return
        }
        layer = MapStopsLayer.content(from: allStops, in: viewport)
    }

    /// How many stops are in view but not drawn, or `nil` when there is nothing to explain.
    ///
    /// Only ever non-`nil` for `.tooMany`. An empty patch of map says nothing, because there
    /// is nothing to say — which is the distinction `MapStopsLayer` exists to keep.
    var tooManyCount: Int? {
        if case .tooMany(let count) = layer { return count }
        return nil
    }

    // MARK: - Selección

    /// A place chosen from anywhere that is not the map itself — a search result, a saved
    /// place. Lands on the same card a tap on the map opens, which is what keeps the search
    /// from becoming a second, parallel way of choosing somewhere.
    func select(_ place: MapPlace) {
        state.select(place)
    }

    /// The map's selection binding resolved to one of our own stop markers.
    func selectStop(id: StopID) {
        guard let stop = allStops.first(where: { $0.id == id }) else { return }
        state.select(.stop(stop))
    }

    /// The map's selection resolved to nothing.
    ///
    /// Called for a genuinely `nil` binding **and** for the empty `MapSelection` that
    /// deselection actually produces — verified on device in the Fase 5 spike. The two are
    /// indistinguishable from here on purpose: the view flattens both into this call.
    func clearSelection() {
        state.clearSelection()
    }

    var selectedStop: Stop? { state.selectedPlace?.stop }

    /// A point of interest Apple owns. Everything shown comes from the `MapFeature` itself —
    /// no `MKMapItemRequest`, so tapping a POI costs no network round trip.
    func selectPointOfInterest(title: String?, rawCategory: String?, coordinate: Coordinate) {
        let label = title ?? MapPlaceLabels.pointOfInterestName(rawCategory: rawCategory)
            ?? "Lugar"
        state.select(MapPlace(
            place: .coordinate(coordinate, label: label),
            subtitle: MapPlaceLabels.pointOfInterestName(rawCategory: rawCategory),
            origin: .pointOfInterest))
    }

    /// A point the user pressed.
    ///
    /// Selects immediately with the fallback label so the card appears under the finger, then
    /// replaces it if reverse geocoding has something better. The guard before applying is
    /// what stops a slow answer from renaming a place the user has since moved on from —
    /// press two points quickly and the first reply must not land on the second card.
    func dropPin(at coordinate: Coordinate) async {
        state.select(.droppedPin(coordinate))
        let resolved = await resolver.resolve(coordinate: coordinate)
        guard let current = state.selectedPlace,
              current.origin == .droppedPin,
              current.coordinate == coordinate
        else { return }
        state.select(.droppedPin(coordinate, name: resolved.name, subtitle: resolved.subtitle))
    }

    /// Fed from `LocationProvider`, and kept even when the user has pinned an origin of their
    /// own — the card's distance needs it regardless.
    func updateCurrentLocation(_ coordinate: Coordinate) {
        state.updateCurrentLocation(coordinate)
    }

    // MARK: - Búsqueda

    func beginSearch() { state.beginSearch() }

    /// The sheet closed, from whatever it was showing: all the way out to the clean map.
    ///
    /// One door out for every mode, rather than a different rule per gesture — the same
    /// argument behind `MapNavigationState.dismiss` being a single table. `dismiss()` is the
    /// one that walks back a level; this is the X and the drag-to-close.
    func closeSheet() {
        state.reset()
        drawn = DrawnRoute()
        plannedAt = nil
    }

    /// A saved journey, planned whole. Both ends come from what the user stored, so there is
    /// nothing to ask the GPS.
    func route(savedJourney: SavedJourney) async {
        let ends = savedJourney.mapEnds
        state.route(from: ends.origin, to: ends.destination)
        await plan()
    }

    // MARK: - Ruta

    /// What the map is drawing: the alternatives and their traces, always in step.
    ///
    /// The two travel together on purpose. `JourneyOverviewMapContent` indexes one by the
    /// other, so a version of this where the journeys came from `state` and the traces from
    /// here could be caught mid-update with the two disagreeing.
    ///
    /// It also outlives a re-plan. `state.route` empties the moment a query starts, and
    /// drawing from it meant the route under the sheet vanished for the duration — which on a
    /// manual refresh is a blink of exactly the thing the user asked to keep. This is replaced
    /// only when there is something new to replace it with.
    struct DrawnRoute {
        var journeys: [Journey] = []
        var traces: [[JourneyTrace]] = []

        var isEmpty: Bool { journeys.isEmpty }
    }

    /// Built once per result and never in `body`: reading a ridden shape is a SQLite hit per
    /// ride leg, and with four alternatives that is up to sixteen.
    private(set) var drawn = DrawnRoute()
    private(set) var planningFailure: String?

    /// When the answer on screen was computed, or `nil` when there is none.
    ///
    /// Shown to the user rather than acted on. A route list is a photograph of a moment, and
    /// the moment matters: miss the bus and every time on it is wrong. Nothing re-plans on its
    /// own — that would shuffle the list under a finger already reading it, and could move the
    /// highlighted alternative out from under the map — so the app says how old the answer is
    /// and leaves the decision where it belongs.
    private(set) var plannedAt: Date?

    /// Why "Cómo llegar" cannot run yet, or `nil` when it can.
    ///
    /// Read before the fact rather than after: the alternative is a button that looks live,
    /// spins, and then explains itself. The feed check mirrors what `JourneyPlanner` would
    /// answer with `.noData`, said early.
    var routeBlockedReason: String? {
        if allStops.isEmpty {
            return "Todavía se están descargando los horarios del Concello."
        }
        if state.currentLocation == nil && state.origin == nil {
            return "Necesito saber desde dónde sales. Activa la ubicación o elige un origen."
        }
        return nil
    }

    /// "Cómo llegar" on the selected place.
    func routeToSelectedPlace() async {
        guard state.routeToSelectedPlace() else {
            // With a place selected, the only way this fails is having no position and no
            // pinned origin. Saying so beats a spinner that never resolves.
            planningFailure = state.selectedPlace == nil
                ? nil
                : "Necesito saber desde dónde sales. Activa la ubicación o elige un origen."
            return
        }
        await plan()
    }

    /// Runs the planner for whatever origin and destination the state currently holds.
    func plan() async {
        guard let query = state.routeQuery(now: Date()) else { return }
        planningFailure = nil
        state.planningStarted()
        do {
            let result = try await planner.plan(query)
            state.planningFinished(result.outcome)
            plannedAt = Date()
            await redraw()
        } catch {
            // A thrown error is not the same as "no route found", and must not borrow its
            // wording — `PlanOutcome` has seven honest ways to say the latter.
            state.planningFailed()
            plannedAt = nil
            drawn = DrawnRoute()
            planningFailure = (error as? CustomStringConvertible)?.description
                ?? error.localizedDescription
        }
    }

    /// Ask again, now.
    ///
    /// The gesture that answers "the bus I was told about has gone". With `.now` as the
    /// departure this genuinely produces the next one, because the query is built from the
    /// clock at the moment it runs; with a fixed departure time the answer is the same one and
    /// only its age changes, which is honest — nothing about a 15:40 departure moves because
    /// it is now 15:20.
    ///
    /// The realtime annotations ride along with whatever `ThrottledRealtimeProvider` is willing
    /// to serve. **The 20 s throttle is not bypassed**: those endpoints have no official API,
    /// and the handoff makes not hammering them an obligation rather than a courtesy. Inside
    /// the window this returns the cached answer, and no text promises otherwise.
    func refresh() async {
        await plan()
    }

    func setOrigin(_ place: MapPlace) async {
        state.setOrigin(place)
        await plan()
    }

    func setDestination(_ place: MapPlace) async {
        state.setDestination(place)
        await plan()
    }

    func swapEnds() async {
        state.swapEnds()
        await plan()
    }

    func setDeparture(_ departure: MapNavigationState.Departure) async {
        guard state.departure != departure else { return }
        state.departure = departure
        await plan()
    }

    func selectAlternative(at index: Int) { state.selectAlternative(at: index) }

    @discardableResult
    func openSelectedAlternative() -> Bool { state.openSelectedAlternative() }

    func dismiss() { state.dismiss() }

    @discardableResult
    func startFollowing() -> Bool { state.startFollowing() }
    func stopFollowing() { state.stopFollowing() }

    /// Traces for the highlighted alternative only, for whatever draws exactly one.
    var selectedTraces: [JourneyTrace] {
        drawn.traces.indices.contains(state.selectedAlternative)
            ? drawn.traces[state.selectedAlternative] : []
    }

    /// Rebuilds what the map draws from the journeys already planned.
    ///
    /// Needed when the visible set changes without a new answer — which is what changing the
    /// ordering does. It never re-plans: the criterion is presentation.
    private func rebuildTraces() async {
        await redraw()
    }

    /// Replaces what the map draws with the result that just came in.
    ///
    /// The single writer of `drawn`, so its two halves cannot drift apart.
    private func redraw() async {
        let journeys = state.visibleJourneys
        guard !journeys.isEmpty else {
            drawn = DrawnRoute()
            return
        }
        let repository = self.repository
        // Off the main actor. `.task` alone would still run this here, because reading the
        // shapes has no suspension point of its own.
        let traces = await Task.detached(priority: .userInitiated) {
            journeys.map { JourneyTraceBuilder.traces(for: $0, repository: repository) }
        }.value
        drawn = DrawnRoute(journeys: journeys, traces: traces)
    }

    /// Straight-line distance from the device to a place, already worded. `nil` when there is
    /// no fix yet, which is a normal state and not worth a placeholder.
    func distanceText(to place: MapPlace) -> String? {
        guard let from = state.currentLocation else { return nil }
        let metres = TransitRepository.haversineMetres(
            from.latitude, from.longitude, place.coordinate.latitude, place.coordinate.longitude)
        return MapPlaceLabels.straightLineDistance(metres: metres)
    }
}
