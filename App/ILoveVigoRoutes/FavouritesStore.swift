import Foundation
import Observation
import VigoCore

/// The one place that reads or writes favourite state.
///
/// Before this existed, `StopDetailModel` snapshotted `isFavourite` in its `init` and
/// `FavouritesModel` kept its own `[Stop]`: starring a stop in one screen left every other
/// screen showing the opposite until it happened to reload. Being `@Observable` and owned
/// by `AppEnvironment` means every view that reads `contains(_:)` or `stops` inside `body`
/// is re-rendered on any mutation, wherever that mutation came from.
@MainActor
@Observable
final class FavouritesStore {
    private let repository: TransitRepository

    /// Favourites that still resolve against the imported feed, in the user's order.
    private(set) var stops: [Stop] = []
    /// Every favourited stop_id, including ones the current feed no longer contains.
    /// `contains(_:)` reads this stored set rather than hitting SQLite, which is what lets
    /// `@Observable` track the dependency correctly wherever a star button reads it.
    private(set) var ids: Set<StopID> = []
    /// Favourited stop_ids the current feed does not know about. Surfaced, not hidden —
    /// the same honesty principle the rest of the app applies to realtime data.
    private(set) var unresolvedIDs: [StopID] = []

    init(repository: TransitRepository) {
        self.repository = repository
        reload()
    }

    func contains(_ id: StopID) -> Bool { ids.contains(id) }

    /// Re-reads favourites from the database. Called after every mutation here, and by
    /// `AppEnvironment.refreshFeed` after a reimport rewrites the `stop` table wholesale —
    /// every cached `Stop` in `stops` would otherwise be stale.
    func reload() {
        let rows = (try? repository.favouriteStopRows()) ?? []
        stops = (try? repository.favouriteStops()) ?? []
        ids = Set(rows.map(\.stopID))
        let resolved = Set(stops.map(\.id))
        unresolvedIDs = rows.map(\.stopID).filter { !resolved.contains($0) }
    }

    func set(_ stop: Stop, favourite: Bool) {
        try? repository.setFavourite(stop.id, favourite)
        reload()
    }

    func toggle(_ stop: Stop) {
        set(stop, favourite: !contains(stop.id))
    }

    func remove(atOffsets offsets: IndexSet) {
        for index in offsets {
            try? repository.setFavourite(stops[index].id, false)
        }
        reload()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = stops
        ordered.move(fromOffsets: source, toOffset: destination)
        try? repository.reorderFavourites(ordered.map(\.id))
        stops = ordered
    }

    /// Drops a favourite whose stop no longer exists in the feed. There is nothing to
    /// un-favourite through `setFavourite(_:_:)` for a stop we cannot fetch, so this goes
    /// straight to the row.
    func forget(_ id: StopID) {
        try? repository.setFavourite(id, false)
        reload()
    }
}
