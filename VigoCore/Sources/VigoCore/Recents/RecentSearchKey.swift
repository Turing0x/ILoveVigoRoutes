import Foundation

/// Whether picking a place should be remembered in "Recientes", and — when yes — the dedup
/// identity and origin-kind to store for it. Pure on purpose, so every dedup/exclusion rule
/// can run under `swift test` instead of only being checkable in the simulator.
public enum RecentSearchKey {
    public struct Candidate: Sendable, Hashable {
        public let dedupKey: String
        public let originKind: String
    }

    /// `nil` for `.currentLocation` (a live thing, not a search — the "Mi ubicación" row
    /// already offers it every time) and `.savedPlace` (already has its own permanent
    /// section, so remembering it here would only duplicate it). `.pointOfInterest` never
    /// reaches this funnel through `MapSearchSheet.pick(_:)` in the first place — a map POI
    /// tap goes straight to `MapNavigationState.select` — but is excluded here too, for the
    /// same underlying reason: it is not something the user searched for.
    public static func candidate(for place: MapPlace) -> Candidate? {
        switch place.origin {
        case .currentLocation, .savedPlace, .pointOfInterest:
            return nil
        case .stop(let stop):
            return Candidate(dedupKey: "stop:\(stop.id.rawValue)", originKind: "stop")
        case .address:
            return Candidate(dedupKey: pointKey(coordinate: place.coordinate, name: place.label),
                             originKind: "address")
        case .droppedPin:
            return Candidate(dedupKey: pointKey(coordinate: place.coordinate, name: place.label),
                             originKind: "pin")
        }
    }

    /// The same identity a `SavedPlace`'s anchor would produce, so a recent that already
    /// duplicates a saved place can be filtered out by comparing the two keys directly,
    /// without a second scheme.
    public static func dedupKey(name: String, anchor: SavedPlaceAnchor) -> String {
        switch anchor {
        case .stop(let stop): "stop:\(stop.id.rawValue)"
        case .orphanedStop(let id, _): "stop:\(id.rawValue)"
        case .coordinate(let coordinate): pointKey(coordinate: coordinate, name: name)
        }
    }

    /// Rounded to four decimals (~11 m — `Coordinate.rounded(toDecimals:)`, the same figure
    /// `MapSearchSheet` throttles "Cerca de ti" on) and folded (`TextNormalization
    /// .searchFolded`), so GPS jitter and accent differences don't each mint a new row.
    private static func pointKey(coordinate: Coordinate, name: String) -> String {
        let rounded = coordinate.rounded(toDecimals: 4)
        let folded = TextNormalization.searchFolded(name)
        return "pt:\(rounded.latitude):\(rounded.longitude):\(folded)"
    }
}
