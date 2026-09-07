import Foundation
import Observation
import VigoCore

/// Measured walking times for the alternatives currently on screen (B3).
///
/// The walking counterpart of `FirstBoardingLive`, and built the same way for the same
/// reasons: the answer appears immediately from the estimate, and the measurement arrives
/// afterwards if it can. Nothing waits for the network, and nothing breaks without it.
///
/// What it buys is the failure this whole thread of work started from. The straight-line
/// estimate's per-pair error runs from −28 % to +29 %, and on the wrong side of that a
/// journey is offered whose first bus cannot physically be reached. Once the real walk is
/// known, the row can say so.
@MainActor
@Observable
final class WalkRefinementLive {
    private let router: MapKitWalkRouter
    private(set) var refinements: [Journey: WalkRefinement.Refinement] = [:]
    private var task: Task<Void, Never>?

    init(router: MapKitWalkRouter) {
        self.router = router
    }

    /// What the measured walks imply for one journey, or `nil` while nothing is known.
    ///
    /// `now` comes from the caller so a row's countdown and its "you cannot make this" verdict
    /// are computed against one instant.
    func outcome(for journey: Journey, now: Date?) -> WalkRefinement.Outcome? {
        guard let refinement = refinements[journey] else { return nil }
        return WalkRefinement.outcome(for: journey, refinement: refinement, now: now)
    }

    /// Measures the open-air walks of every journey given, in order.
    ///
    /// Sequentially rather than in parallel: `MapKitWalkRouter` has a ceiling of four
    /// outstanding requests and returns `nil` past it, so a `TaskGroup` here would convert
    /// the fifth journey's walk into a permanent "unknown" for no gain. In order, because the
    /// first alternative is the one being looked at.
    func refresh(for journeys: [Journey]) {
        task?.cancel()
        guard !journeys.isEmpty else {
            refinements = [:]
            return
        }
        let router = self.router
        task = Task { [weak self] in
            for journey in journeys {
                guard !Task.isCancelled else { return }
                let refinement = await WalkRefinement.measure(journey, using: router)
                guard !Task.isCancelled else { return }
                guard !refinement.isEmpty else { continue }
                // Published one at a time rather than in a batch at the end: each row that
                // can be corrected should be corrected as soon as its answer is in, not when
                // the slowest of four has finished.
                self?.refinements[journey] = refinement
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
