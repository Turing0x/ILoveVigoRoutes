import Foundation
import GRDB

/// `internal`, like `ActiveJourneyRow` and `SavedPlaceRow`: nothing outside `VigoCore`
/// persists a raw row shape, only through `TransitRepository`'s CRUD surface.
///
/// The flat columns duplicate part of `payload` on purpose, the same precedent
/// `ActiveJourneyRow` set: the capsule at the bottom of every tab shows the line, the stop the
/// bus is at and how late it is running, and doing that should not mean decoding a whole ride.
struct OnboardRideRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "onboardRide"
    /// Constant `"current"`, never a `UUID`: a traveller is on one bus at a time, and encoding
    /// that in the primary key makes declaring one an upsert instead of depending on code
    /// remembering to clear the previous row.
    static let currentID = "current"

    var id: String
    var declaredAt: Date
    var updatedAt: Date
    var routeShortName: String
    var normalizedLine: String
    var headsign: String?
    var tripID: String?
    var currentStopID: String?
    var currentStopName: String
    var currentLatitude: Double
    var currentLongitude: Double
    var currentPosition: Int
    var observedDelaySeconds: Int
    var payload: Data

    init(_ ride: OnboardRide, payload: Data) {
        self.id = Self.currentID
        self.declaredAt = ride.declaredAt
        self.updatedAt = ride.updatedAt
        self.routeShortName = ride.routeShortName
        self.normalizedLine = ride.normalizedLine
        self.headsign = ride.headsign
        self.tripID = ride.tripID?.rawValue
        self.currentStopID = ride.currentStop.stopID?.rawValue
        self.currentStopName = ride.currentStop.name
        self.currentLatitude = ride.currentStop.latitude
        self.currentLongitude = ride.currentStop.longitude
        self.currentPosition = ride.currentPosition
        self.observedDelaySeconds = ride.observedDelaySeconds
        self.payload = payload
    }
}
