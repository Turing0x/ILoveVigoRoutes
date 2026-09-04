import Foundation
import Observation
import VigoCore

/// Owns saved places and saved journeys, the same way `FavouritesStore` owns favourite
/// stops: one `@Observable` instance on `AppEnvironment`, so every screen that reads
/// `places` or `journeys` inside `body` re-renders on any mutation from any screen.
@MainActor
@Observable
final class SavedPlacesStore {
    private let repository: TransitRepository

    private(set) var places: [SavedPlace] = []
    private(set) var journeys: [SavedJourney] = []

    init(repository: TransitRepository) {
        self.repository = repository
        reload()
    }

    /// Re-reads both lists from the database. Called after every mutation here, and by
    /// `AppEnvironment.refreshFeed` after a reimport — a stop-anchored place or journey
    /// endpoint can go from resolved to orphaned the moment `stop` is rewritten.
    func reload() {
        places = (try? repository.savedPlaces()) ?? []
        journeys = (try? repository.savedJourneys()) ?? []
    }

    // MARK: - Places

    @discardableResult
    func createPlace(name: String, symbolName: String, anchor: SavedPlaceAnchorInput) -> SavedPlace? {
        defer { reload() }
        return try? repository.createSavedPlace(name: name, symbolName: symbolName, anchor: anchor)
    }

    func updatePlace(id: SavedPlaceID, _ edit: SavedPlaceEdit) {
        try? repository.updateSavedPlace(id: id, edit)
        reload()
    }

    func deletePlace(id: SavedPlaceID) {
        try? repository.deleteSavedPlace(id: id)
        reload()
    }

    func removePlaces(atOffsets offsets: IndexSet) {
        for index in offsets { try? repository.deleteSavedPlace(id: places[index].id) }
        reload()
    }

    func movePlaces(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = places
        ordered.move(fromOffsets: source, toOffset: destination)
        try? repository.reorderSavedPlaces(ordered.map(\.id))
        places = ordered
    }

    // MARK: - Journeys

    @discardableResult
    func createJourney(
        customLabel: String?, origin: SavedEndpointInput, destination: SavedEndpointInput
    ) -> SavedJourney? {
        defer { reload() }
        return try? repository.createSavedJourney(
            customLabel: customLabel, origin: origin, destination: destination)
    }

    func updateJourney(id: SavedJourneyID, _ edit: SavedJourneyEdit) {
        try? repository.updateSavedJourney(id: id, edit)
        reload()
    }

    func deleteJourney(id: SavedJourneyID) {
        try? repository.deleteSavedJourney(id: id)
        reload()
    }

    func removeJourneys(atOffsets offsets: IndexSet) {
        for index in offsets { try? repository.deleteSavedJourney(id: journeys[index].id) }
        reload()
    }

    func moveJourneys(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = journeys
        ordered.move(fromOffsets: source, toOffset: destination)
        try? repository.reorderSavedJourneys(ordered.map(\.id))
        journeys = ordered
    }
}
