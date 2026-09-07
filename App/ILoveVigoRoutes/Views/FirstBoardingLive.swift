import Foundation
import Observation
import VigoCore

/// Live annotations for the first boarding of each alternative on screen.
///
/// **One request per distinct boarding stop, not per alternative.** Four alternatives
/// routinely leave from the same pole, and the handoff's §8 obligation — be a good citizen
/// with sources that publish no official API — makes fanning out four identical requests the
/// wrong default. `ThrottledRealtimeProvider` already enforces a 20 s floor underneath, so
/// grouping here is about not asking at all rather than about being rate-limited.
///
/// The realtime source is never polled in the background. This refreshes only while
/// something is on screen asking for it, exactly like `StopDetailModel`.
@MainActor
@Observable
final class FirstBoardingLive {
    private let arrivals: ArrivalsService
    /// Keyed by boarding stop, so several alternatives sharing one share its answer.
    private(set) var matches: [StopID: Arrival] = [:]
    private var task: Task<Void, Never>?

    init(arrivals: ArrivalsService) {
        self.arrivals = arrivals
    }

    /// The live arrival believed to be this journey's first bus, or `nil` when there is none
    /// close enough to claim. `nil` renders as **nothing at all** — never as a timetable time
    /// dressed up as live.
    func match(for journey: Journey) -> Arrival? {
        guard let ride = FirstBoardingMatch.firstRide(of: journey) else { return nil }
        return matches[ride.board.id]
    }

    /// What the live countdown implies beyond itself (D1), or `nil` when it implies nothing:
    /// no match, or a bus running roughly to time.
    ///
    /// `now` is passed in so the whole row is drawn against one instant. Reading the clock
    /// here and again in the view would let a row show a countdown and an implied arrival
    /// computed a second apart, which is invisible until it straddles a minute boundary.
    func adjustment(for journey: Journey, now: Date) -> LiveJourneyAdjustment.Adjustment? {
        guard let live = match(for: journey) else { return nil }
        return LiveJourneyAdjustment.adjust(journey, live: live, now: now)
    }

    /// Looks up every distinct boarding stop among `journeys` and keeps the arrivals that
    /// match. Cancels whatever was in flight, so a stale result cannot land on a newer list.
    func refresh(for journeys: [Journey]) {
        task?.cancel()
        guard !journeys.isEmpty else {
            matches = [:]
            return
        }
        let arrivals = self.arrivals
        task = Task { [weak self] in
            var rides: [StopID: (routeShortName: String, board: Stop, departure: Date)] = [:]
            for journey in journeys {
                guard let ride = FirstBoardingMatch.firstRide(of: journey) else { continue }
                // First one wins: alternatives are sorted by arrival, so the earliest
                // departure from a shared stop is the one a countdown should describe.
                if rides[ride.board.id] == nil { rides[ride.board.id] = ride }
            }

            var found: [StopID: Arrival] = [:]
            for (stopID, ride) in rides {
                guard !Task.isCancelled else { return }
                let now = Date()
                let result = await arrivals.arrivals(for: ride.board, now: now)
                if let match = FirstBoardingMatch.match(
                    arrivals: result.arrivals, routeShortName: ride.routeShortName,
                    scheduledDeparture: ride.departure, now: now) {
                    found[stopID] = match
                }
            }
            guard !Task.isCancelled else { return }
            self?.matches = found
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
