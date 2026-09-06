import Foundation
import GRDB

/// `internal`, like `SavedPlaceRow`: nothing outside `VigoCore` persists a raw row shape,
/// only through `TransitRepository`'s CRUD surface.
///
/// The flat columns duplicate part of `payload` on purpose — Fase 13's notification handler
/// needs the destination without deserializing a whole journey, the same precedent
/// `cachedArrivals` already set by keeping queryable columns next to its own blob.
struct ActiveJourneyRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "activeJourney"
    /// Constant `"current"`, never a `UUID`: at most one active journey can exist, and
    /// encoding that in the primary key makes starting one an `INSERT OR REPLACE` instead of
    /// depending on code remembering to clear the previous row first.
    static let currentID = "current"

    var id: String
    var startedAt: Date
    var state: String                    // "active" | "stale"
    var destinationName: String
    var destinationStopID: String?
    var destinationLatitude: Double
    var destinationLongitude: Double
    var scheduledArrival: Date
    var payload: Data
}
