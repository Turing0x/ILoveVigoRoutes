import Foundation
import Observation
import VigoCore

/// Owns the one bus the traveller says they are riding, the way `ActiveJourneyStore` owns the
/// one journey being followed. One `@Observable` on `AppEnvironment`, so the capsule at the
/// bottom of every tab, the declaration sheet and the planning sheet can never disagree.
///
/// The two stores are siblings, not layers: the app keeps at most one of the two states, and
/// the repository enforces that in a single transaction (`startOnboardRide`,
/// `acceptOnboardRide`). Everything either store does afterwards is a `reload`.
@MainActor
@Observable
final class OnboardRideStore {
    private let repository: TransitRepository
    private let timetableStore: TimetableStore

    /// Thirty minutes since the last confirmed position, not the active journey's ninety.
    ///
    /// A different clock measuring a different thing: an active journey has a scheduled
    /// arrival to be late for, while this only knows when the traveller was last seen moving
    /// along the route. The app cannot track location in the background, so a ride whose
    /// position has not moved in half an hour is a question, not a fact.
    static let grace: TimeInterval = 30 * 60

    private(set) var ride: OnboardRide?
    private(set) var staleness: OnboardRideStaleness = .active
    /// Set when the last fix fell far from the route. The bar asks whether the traveller got
    /// off rather than quietly following a bus they are no longer on.
    private(set) var looksOffRide = false

    init(repository: TransitRepository, timetableStore: TimetableStore) {
        self.repository = repository
        self.timetableStore = timetableStore
        reload()
    }

    func reload(now: Date = Date()) {
        ride = try? repository.onboardRide()
        recomputeStaleness(now: now)
    }

    private func recomputeStaleness(now: Date) {
        guard let ride else { staleness = .active; looksOffRide = false; return }
        staleness = ride.staleness(now: now, grace: Self.grace)
    }

    /// Declaring a bus ends any active journey — the repository does both in one write.
    func declare(_ ride: OnboardRide) {
        try? repository.startOnboardRide(ride)
        looksOffRide = false
        reload()
    }

    func end() {
        try? repository.endOnboardRide()
        looksOffRide = false
        reload()
    }

    /// Applies a new GPS fix: resolves the stored ride against today's timetable, asks
    /// `OnboardProgress` where the traveller now is, and persists the answer.
    ///
    /// Only writes when the position actually moved. A fix every second that changes nothing
    /// would otherwise rewrite the row every second for no gain — and the delay figure is only
    /// fresh when a stop was passed anyway.
    func advance(to coordinate: Coordinate, now: Date = Date()) async {
        guard let ride else { return }
        let day = ServiceDate(now, calendar: repository.calendar)
        guard let timetable = try? await timetableStore.timetable(anchor: day) else { return }
        guard case .success(let resolved) = OnboardRideResolution.resolve(ride, in: timetable,
                                                                          now: now) else { return }
        let update = OnboardProgress.advance(resolved, in: timetable, to: coordinate, now: now)
        looksOffRide = update.looksOffRide
        guard update.passedStop else { return }

        let stop = timetable.stops[Int(update.stop)]
        let scheduled = timetable.date(forAxisSeconds: Int(timetable.departure(
            pattern: resolved.pattern, trip: resolved.trip, position: update.position)))
        let moved = ride.advanced(to: .from(stop), position: update.position,
                                  scheduledAtCurrent: scheduled,
                                  observedDelaySeconds: Int(update.delaySeconds), at: now)
        try? repository.updateOnboardRide(moved)
        reload(now: now)
    }

    /// The traveller accepted a plan made from this ride: it becomes the active journey, and
    /// the loose ride is gone. One transaction, so neither of the two capsules can be orphaned.
    func accept(_ journey: Journey, destinationLabel: String) -> ActiveJourneySnapshot? {
        guard let ride else { return nil }
        let snapshot = ActiveJourneySnapshot(
            journey, originLabel: "En el \(ride.routeShortName)",
            destinationLabel: destinationLabel)
        try? repository.acceptOnboardRide(as: snapshot)
        reload()
        return snapshot
    }
}
