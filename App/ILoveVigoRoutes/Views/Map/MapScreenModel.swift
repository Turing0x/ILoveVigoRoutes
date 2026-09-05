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

    private var viewport: MapStopsLayer.Viewport?

    init(repository: TransitRepository, defaults: UserDefaults = .standard) {
        self.repository = repository
        self.defaults = defaults
        self.stopsVisible = defaults.bool(forKey: Self.stopsVisibleKey)
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
}
