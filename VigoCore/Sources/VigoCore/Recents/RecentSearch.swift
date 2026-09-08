import Foundation

/// A place the user picked before, ready to show in "Recientes" and to pick again.
///
/// Deliberately the *place*, not the origin/destination pair — `SavedJourney` already is
/// "this origin with this destination", and two of `MapSearchSheet.Purpose`'s three cases
/// (`.endpoint`, `.standalone`) have no pair to remember in the first place.
///
/// No cap and no time-based expiry: the list grows until the user clears it, one row or all
/// of them, from `MapSearchSheet` — a deliberate departure from the original max-10/LRU plan,
/// made when this was actually built.
public struct RecentSearch: Sendable, Hashable, Identifiable {
    public let dedupKey: String
    public let name: String
    public let subtitle: String?
    public let symbolName: String
    /// "stop" | "address" | "pin" — kept alongside `anchor` because a resolved
    /// `.coordinate` anchor cannot tell an address apart from a dropped pin on its own, and
    /// the two use different icons and, on repicking, different `MapPlace.Origin`s.
    public let originKind: String
    public let anchor: SavedPlaceAnchor
    public let lastUsedAt: Date

    public init(dedupKey: String, name: String, subtitle: String?, symbolName: String,
                originKind: String, anchor: SavedPlaceAnchor, lastUsedAt: Date) {
        self.dedupKey = dedupKey
        self.name = name
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.originKind = originKind
        self.anchor = anchor
        self.lastUsedAt = lastUsedAt
    }

    public var id: String { dedupKey }
    public var coordinate: Coordinate { anchor.coordinate }

    /// The `stopID` behind this recent, resolved or orphaned — used to filter out a recent
    /// that already has its own permanent section once it becomes a favourite.
    public var stopID: StopID? {
        switch anchor {
        case .stop(let stop): stop.id
        case .orphanedStop(let id, _): id
        case .coordinate: nil
        }
    }

    /// What the planner needs. A `stopID` gone from the feed still resolves to a usable
    /// coordinate under the name that was saved — the same "don't strand it" rule
    /// `SavedPlace`/`SavedEndpoint` already follow for the identical situation.
    public var place: Place {
        if case .stop(let stop) = anchor { return .stop(stop) }
        return .coordinate(anchor.coordinate, label: name)
    }

    /// Mirrors `MapPlace.savedEndpoint`'s own fallback: a resolved stop keeps `.stop`
    /// (arrivals, the favourite star); anything else — including an orphaned stop — falls
    /// back to whichever kind best explains what this originally was.
    public var origin: MapPlace.Origin {
        if case .stop(let stop) = anchor { return .stop(stop) }
        return originKind == "address" ? .address : .droppedPin
    }

    public var mapPlace: MapPlace {
        MapPlace(place: place, subtitle: subtitle, origin: origin)
    }
}
