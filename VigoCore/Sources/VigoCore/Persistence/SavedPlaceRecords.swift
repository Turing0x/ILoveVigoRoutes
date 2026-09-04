import Foundation
import GRDB

// MARK: - Identifiers

public struct SavedPlaceID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func generate() -> Self { .init(UUID().uuidString) }
    public var description: String { rawValue }

    // Encoded as a bare string so database rows and JSON stay flat, like `StopID`.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

public struct SavedJourneyID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func generate() -> Self { .init(UUID().uuidString) }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

// MARK: - Anchors

/// Where a saved place points, resolved against the feed currently in the database.
///
/// Never a persisted `Stop` blob: `GTFSImporter` deletes and rewrites the `stop` table
/// wholesale on every refresh, so a stop-anchored place is stored as a `stopID` plus a
/// fallback coordinate, and resolved fresh on every read. `.orphanedStop` is what that
/// resolution produces when the feed no longer has that `stopID` — still usable, because
/// the planner only ever needs a coordinate (see `SavedPlace.place`).
public enum SavedPlaceAnchor: Sendable, Hashable {
    case stop(Stop)
    case orphanedStop(StopID, fallback: Coordinate)
    case coordinate(Coordinate)

    public var coordinate: Coordinate {
        switch self {
        case .stop(let stop): Coordinate(stop)
        case .orphanedStop(_, let fallback): fallback
        case .coordinate(let coordinate): coordinate
        }
    }

    public var resolvedStop: Stop? {
        if case .stop(let stop) = self { stop } else { nil }
    }

    public var isOrphaned: Bool {
        if case .orphanedStop = self { true } else { false }
    }
}

/// What a caller passes in when creating or re-anchoring a place — before resolution.
public enum SavedPlaceAnchorInput: Sendable, Hashable {
    case stopID(StopID, fallback: Coordinate)
    case coordinate(Coordinate)

    public static func stop(_ stop: Stop) -> Self {
        .stopID(stop.id, fallback: Coordinate(stop))
    }
}

extension SavedPlaceAnchorInput {
    /// The coordinate every anchor kind must store, even a stop-anchored one — it is what
    /// keeps a place usable once its stop_id is no longer in the feed.
    var coordinate: Coordinate {
        switch self {
        case .stopID(_, let fallback): fallback
        case .coordinate(let coordinate): coordinate
        }
    }
    var kindString: String {
        switch self {
        case .stopID: "stop"
        case .coordinate: "coordinate"
        }
    }
    var stopIDString: String? {
        if case .stopID(let id, _) = self { return id.rawValue }
        return nil
    }
}

// MARK: - Saved place

public struct SavedPlace: Sendable, Hashable, Identifiable {
    public let id: SavedPlaceID
    /// The user's own name. Templates (Casa, Trabajo, Hospital, Centro de salud, …) only
    /// prefill this and `symbolName` at creation time; nothing downstream is a singleton —
    /// two places can share a template and coexist with independent names.
    public let name: String
    /// SF Symbol name.
    public let symbolName: String
    public let anchor: SavedPlaceAnchor
    public let createdAt: Date
    public let sortIndex: Int

    public init(id: SavedPlaceID, name: String, symbolName: String, anchor: SavedPlaceAnchor,
                createdAt: Date, sortIndex: Int) {
        self.id = id; self.name = name; self.symbolName = symbolName
        self.anchor = anchor; self.createdAt = createdAt; self.sortIndex = sortIndex
    }

    public var coordinate: Coordinate { anchor.coordinate }

    /// What the planner receives. Always `.coordinate`, never `.stop`: `JourneyPlanner`
    /// derives access and egress purely from `Place.coordinate` (see `JourneyPlanner.plan`),
    /// so routing is identical either way, and this is what puts the user's own name —
    /// "Casa", not "Praza de América 1" — on the planner row and on the journey's walk leg.
    public var place: Place { .coordinate(anchor.coordinate, label: name) }
}

// MARK: - Saved journey

/// One end of a saved journey.
///
/// `placeID` is a live link: while it resolves, name, icon and anchor come from the saved
/// place, so renaming "Casa" renames it here too. The remaining fields are a snapshot taken
/// at save time, consulted only once the link is gone — which is what makes deleting a
/// saved place degrade a journey referencing it instead of breaking it.
public struct SavedEndpoint: Sendable, Hashable {
    public let placeID: SavedPlaceID?
    public let name: String
    public let symbolName: String
    public let anchor: SavedPlaceAnchor

    public init(placeID: SavedPlaceID?, name: String, symbolName: String, anchor: SavedPlaceAnchor) {
        self.placeID = placeID; self.name = name; self.symbolName = symbolName; self.anchor = anchor
    }

    public var isDetached: Bool { placeID == nil }
    public var coordinate: Coordinate { anchor.coordinate }
    public var place: Place { .coordinate(anchor.coordinate, label: name) }
}

public struct SavedEndpointInput: Sendable, Hashable {
    public let placeID: SavedPlaceID?
    public let name: String
    public let symbolName: String
    public let anchor: SavedPlaceAnchorInput

    public init(placeID: SavedPlaceID?, name: String, symbolName: String, anchor: SavedPlaceAnchorInput) {
        self.placeID = placeID; self.name = name; self.symbolName = symbolName; self.anchor = anchor
    }

    /// A live-linked endpoint: the snapshot is taken from the place as it is right now.
    public static func savedPlace(_ place: SavedPlace) -> Self {
        SavedEndpointInput(placeID: place.id, name: place.name, symbolName: place.symbolName,
                           anchor: place.anchor.asInput)
    }

    /// An endpoint that is never linked to a saved place — e.g. a one-off address picked
    /// just for this journey.
    public static func adHoc(name: String, symbolName: String = "mappin",
                             anchor: SavedPlaceAnchorInput) -> Self {
        SavedEndpointInput(placeID: nil, name: name, symbolName: symbolName, anchor: anchor)
    }
}

extension SavedPlaceAnchor {
    fileprivate var asInput: SavedPlaceAnchorInput {
        switch self {
        case .stop(let stop): .stopID(stop.id, fallback: Coordinate(stop))
        case .orphanedStop(let id, let fallback): .stopID(id, fallback: fallback)
        case .coordinate(let coordinate): .coordinate(coordinate)
        }
    }
}

public struct SavedJourney: Sendable, Hashable, Identifiable {
    public let id: SavedJourneyID
    /// `nil` means "derive from the endpoints", which is what makes a rename of a saved
    /// place show up in the journey's title. A non-nil value is the user's override.
    public let customLabel: String?
    public let origin: SavedEndpoint
    public let destination: SavedEndpoint
    public let createdAt: Date
    public let sortIndex: Int

    public init(id: SavedJourneyID, customLabel: String?, origin: SavedEndpoint,
                destination: SavedEndpoint, createdAt: Date, sortIndex: Int) {
        self.id = id; self.customLabel = customLabel
        self.origin = origin; self.destination = destination
        self.createdAt = createdAt; self.sortIndex = sortIndex
    }

    public var displayLabel: String { customLabel ?? "\(origin.name) → \(destination.name)" }

    /// Ready to hand to `JourneyPlanner.plan(_:)`. Departure is always "now" — a saved
    /// journey is a shortcut to plan immediately, not a stored schedule.
    public var query: PlanQuery {
        PlanQuery(origin: origin.place, destination: destination.place, departure: Date())
    }
}

// MARK: - Partial updates

/// Distinguishing "leave alone" from "clear" with `String??` is unreadable; this says it
/// out loud. Every field left `nil` here is left untouched by `updateSavedPlace`.
public struct SavedPlaceEdit: Sendable {
    public var name: String?
    public var symbolName: String?
    public var anchor: SavedPlaceAnchorInput?

    public init(name: String? = nil, symbolName: String? = nil, anchor: SavedPlaceAnchorInput? = nil) {
        self.name = name; self.symbolName = symbolName; self.anchor = anchor
    }
}

public enum SavedJourneyLabelEdit: Sendable, Hashable {
    /// Leave `customLabel` as it is.
    case unchanged
    /// Set an explicit label, overriding the derived one.
    case custom(String)
    /// Clear `customLabel` back to `nil`, so the label derives from the endpoints again —
    /// and starts propagating their renames.
    case derived
}

public struct SavedJourneyEdit: Sendable {
    public var label: SavedJourneyLabelEdit
    public var origin: SavedEndpointInput?
    public var destination: SavedEndpointInput?

    public init(label: SavedJourneyLabelEdit = .unchanged,
                origin: SavedEndpointInput? = nil, destination: SavedEndpointInput? = nil) {
        self.label = label; self.origin = origin; self.destination = destination
    }
}

// MARK: - GRDB rows

/// `internal`, like `CachedArrivalsRow`: nothing outside VigoCore should be able to
/// persist a raw row shape directly, only through the repository's CRUD surface.
struct SavedPlaceRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "savedPlace"
    var id: String
    var name: String
    var symbolName: String
    var kind: String            // "stop" | "coordinate"
    var stopID: String?         // set only when kind == "stop"
    var latitude: Double        // always populated, including for stop-anchored places
    var longitude: Double
    var createdAt: Date
    var sortIndex: Int
}

struct SavedJourneyRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "savedJourney"
    var id: String
    var customLabel: String?
    var createdAt: Date
    var sortIndex: Int
    // Origin: live link + frozen snapshot.
    var originPlaceID: String?
    var originName: String
    var originSymbolName: String
    var originKind: String
    var originStopID: String?
    var originLatitude: Double
    var originLongitude: Double
    // Destination: same shape.
    var destinationPlaceID: String?
    var destinationName: String
    var destinationSymbolName: String
    var destinationKind: String
    var destinationStopID: String?
    var destinationLatitude: Double
    var destinationLongitude: Double
}
