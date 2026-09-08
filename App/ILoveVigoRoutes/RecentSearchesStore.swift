import Foundation
import Observation
import VigoCore

/// Owns "Recientes", the same way `SavedPlacesStore` owns saved places: one `@Observable`
/// instance on `AppEnvironment`, so every screen that reads `items` re-renders on any
/// mutation from any screen.
///
/// No cap, no time-based expiry: the list grows until the user clears it, one row at a time
/// or all at once, from `MapSearchSheet`.
@MainActor
@Observable
final class RecentSearchesStore {
    private let repository: TransitRepository

    private(set) var items: [RecentSearch] = []

    init(repository: TransitRepository) {
        self.repository = repository
        reload()
    }

    /// Re-reads from the database. Called after every mutation here, and by
    /// `AppEnvironment.refreshFeed` after a reimport — a stop-anchored recent can go from
    /// resolved to orphaned the moment `stop` is rewritten.
    func reload() {
        items = (try? repository.recentSearches()) ?? []
    }

    /// A no-op for a place that should not be remembered (`.currentLocation`, `.savedPlace`)
    /// — `RecentSearchKey.candidate(for:)` decides that, inside the repository.
    func record(_ place: MapPlace) {
        try? repository.recordRecentSearch(place)
        reload()
    }

    func delete(dedupKey: String) {
        try? repository.deleteRecentSearch(dedupKey: dedupKey)
        reload()
    }

    func clear() {
        try? repository.clearRecentSearches()
        reload()
    }
}
