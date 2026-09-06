import Foundation
import Observation
import VigoCore

/// Owns the one active journey, the same way `SavedPlacesStore` owns saved places: one
/// `@Observable` instance on `AppEnvironment`, so the persistent capsule in `RootView` and
/// the "He subido a este bus" button in the route sheet always agree.
@MainActor
@Observable
final class ActiveJourneyStore {
    private let repository: TransitRepository

    /// Ninety minutes, confirmed by the owner: generous on purpose. Vitrasa's longest ride is
    /// well under it, and the margin covers getting off, walking, and not looking at the
    /// phone for a while. Asking too often annoys; closing too soon loses the state.
    static let grace: TimeInterval = 90 * 60

    private(set) var journey: ActiveJourneySnapshot?
    private(set) var staleness: ActiveJourneyStaleness = .active

    init(repository: TransitRepository) {
        self.repository = repository
        reload()
    }

    /// Re-reads from the database and recomputes staleness. Called after every mutation
    /// here, and by `RootView` when the app returns to the foreground — a journey started
    /// before the phone went to sleep for two hours must not still read `.active`.
    func reload(now: Date = Date()) {
        journey = try? repository.activeJourney()
        recomputeStaleness(now: now)
    }

    private func recomputeStaleness(now: Date) {
        guard let journey else { staleness = .active; return }
        staleness = journey.staleness(now: now, grace: Self.grace)
        if case .stale = staleness { try? repository.markActiveJourneyStale() }
    }

    func start(_ snapshot: ActiveJourneySnapshot) {
        try? repository.startActiveJourney(snapshot)
        reload()
    }

    /// Covers both "Terminar" and "Cancelar": the two are distinguished only in the UI
    /// (confirmation dialog or not) — there is no history of finished journeys to tell them
    /// apart in the data, by decision.
    func end() {
        try? repository.endActiveJourney()
        reload()
    }

    /// "Sigo en él": pushes the staleness deadline one more grace window out.
    func extend(now: Date = Date()) {
        guard let journey else { return }
        try? repository.extendActiveJourney(to: journey.scheduledArrival.addingTimeInterval(Self.grace))
        reload(now: now)
    }
}
