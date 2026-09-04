import Foundation

/// Where a journey starts or ends. Not always a stop — the handoff asks for "mi ubicación,
/// parada buscada, favorita, o punto del mapa", and only the middle two are stops.
public enum Place: Sendable, Hashable {
    case stop(Stop)
    /// The user's current location, a favourite without a stop, or a tap on the map.
    case coordinate(Coordinate, label: String)

    public var coordinate: Coordinate {
        switch self {
        case .stop(let stop): return Coordinate(stop)
        case .coordinate(let coordinate, _): return coordinate
        }
    }

    public var label: String {
        switch self {
        case .stop(let stop): return stop.name
        case .coordinate(_, let label): return label
        }
    }
}
