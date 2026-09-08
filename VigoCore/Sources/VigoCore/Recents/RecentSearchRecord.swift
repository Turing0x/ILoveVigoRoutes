import Foundation
import GRDB

/// `internal`, like `SavedPlaceRow`: nothing outside `VigoCore` persists a raw row shape,
/// only through `TransitRepository`'s CRUD surface.
struct RecentSearchRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "recentSearch"
    var dedupKey: String
    var name: String
    var subtitle: String?
    var symbolName: String
    var originKind: String     // "stop" | "address" | "pin"
    var stopID: String?        // set only when originKind == "stop"
    var latitude: Double       // fallback, always populated
    var longitude: Double
    var lastUsedAt: Date
}
