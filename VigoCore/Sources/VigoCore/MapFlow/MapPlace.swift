import Foundation

/// A place chosen on the map, with enough provenance to know what can be offered for it.
///
/// `Place` alone is not enough. It is what the planner eats, and it deliberately flattens
/// everything that is not a stop into `.coordinate(_, label:)` — the user's position, a
/// resolved address and a tap on the map are indistinguishable inside it. The Fase 3
/// planner already had to bolt `PickedPlace` on the side to recover one bit of that
/// (did this come from the GPS?). The map needs more bits than one: whether there is a real
/// `Stop` behind it (to offer arrivals and the favourite star), what to write under the
/// name, and which glyph to draw.
///
/// So `MapPlace` is `Place` plus provenance. The planner still only ever sees `place`.
public struct MapPlace: Sendable, Hashable, Identifiable {

    /// Where this place came from. Not cosmetic: it decides which actions the sheet offers.
    public enum Origin: Sendable, Hashable {
        /// A stop of the imported feed — tapped on the map, or picked from a search.
        /// The only origin that can offer live arrivals and the favourite star.
        case stop(Stop)
        /// A point of interest owned by Apple Maps (`MapFeature`).
        ///
        /// Carries no MapKit type on purpose: `MKPointOfInterestCategory` would drag MapKit
        /// into a package that must stay platform-agnostic, and its raw value
        /// (`MKPOICategoryStore`) is not something to show a person anyway — the app
        /// translates it into `subtitle` before building this.
        case pointOfInterest
        /// Resolved through Apple's address search, inside the fixed Vigo region.
        case address
        /// One of the user's saved places.
        case savedPlace(SavedPlaceID)
        /// A point the user pressed on the map. `subtitle` carries the reverse-geocoded
        /// street when there was one, and is `nil` when there was not — which is a normal
        /// outcome, not a failure: the coordinate alone is perfectly plannable.
        case droppedPin
        /// Where the device says it is.
        case currentLocation
    }

    public let place: Place
    /// The second line under the name: a street, a translated POI category, "Parada 6930".
    /// Always optional — nothing downstream may depend on it existing.
    public let subtitle: String?
    public let origin: Origin

    public init(place: Place, subtitle: String? = nil, origin: Origin) {
        self.place = place
        self.subtitle = subtitle
        self.origin = origin
    }

    /// The label every GPS-derived place carries. Shared so the automatic origin and an
    /// explicit "Mi ubicación" tap produce the same value.
    public static let currentLocationLabel = "Mi ubicación"

    /// The label a pressed point falls back to when reverse geocoding gave nothing.
    public static let droppedPinLabel = "Punto en el mapa"

    // MARK: - Factories

    public static func stop(_ stop: Stop) -> MapPlace {
        MapPlace(place: .stop(stop),
                 subtitle: stop.vitrasaCode.map { "Parada \($0.value)" },
                 origin: .stop(stop))
    }

    public static func currentLocation(_ coordinate: Coordinate) -> MapPlace {
        MapPlace(place: .coordinate(coordinate, label: currentLocationLabel),
                 subtitle: nil, origin: .currentLocation)
    }

    /// A pressed point. `name` is whatever reverse geocoding produced; `nil` falls back to
    /// a fixed label, so this can never produce a place without a name.
    public static func droppedPin(_ coordinate: Coordinate, name: String? = nil,
                                  subtitle: String? = nil) -> MapPlace {
        MapPlace(place: .coordinate(coordinate, label: name ?? droppedPinLabel),
                 subtitle: subtitle, origin: .droppedPin)
    }

    public static func savedPlace(_ saved: SavedPlace) -> MapPlace {
        MapPlace(place: saved.place,
                 subtitle: saved.anchor.resolvedStop?.name,
                 origin: .savedPlace(saved.id))
    }

    // MARK: - Derived

    public var label: String { place.label }
    public var coordinate: Coordinate { place.coordinate }

    /// The stop behind this place, when there is one. Gates "Ver llegadas" and the star.
    public var stop: Stop? {
        if case .stop(let stop) = origin { return stop }
        return nil
    }

    /// True when the origin is the device's own position, which is the one case the planner
    /// keeps refreshing behind the user's back.
    public var isCurrentLocation: Bool { origin == .currentLocation }

    /// SF Symbol for the sheet header and the highlighted marker.
    ///
    /// A symbol name is presentation, and this is a domain package — but `SavedPlace` has
    /// carried `symbolName` since Fase 4 for the same reason: the alternative is a `switch`
    /// over `Origin` duplicated in every view that draws one of these.
    public var symbolName: String {
        switch origin {
        case .stop: "bus.fill"
        case .pointOfInterest: "mappin.circle.fill"
        case .address: "mappin.and.ellipse"
        case .savedPlace: "bookmark.fill"
        case .droppedPin: "mappin"
        case .currentLocation: "location.fill"
        }
    }

    /// Identity by content. Two taps on the same stop are the same place; a pressed point
    /// and a stop that happen to share a coordinate are not, because their origins differ.
    public var id: Self { self }
}

extension MapPlace {
    /// One end of a saved journey, as the map's own place type.
    ///
    /// Keeps the **saved name** as the label — "Casa", not "Rúa do Areal, 12" — because that
    /// is the whole point of having saved it. When the endpoint is anchored to a stop, the
    /// stop's own name becomes the subtitle, so the name does not hide which stop it means.
    ///
    /// An endpoint whose stop has vanished from the feed still produces a usable place: the
    /// anchor keeps a fallback coordinate precisely so a reimport cannot strand a saved
    /// journey, and the planner only ever needs a coordinate.
    public static func savedEndpoint(_ endpoint: SavedEndpoint) -> MapPlace {
        MapPlace(place: endpoint.place,
                 subtitle: endpoint.anchor.resolvedStop?.name,
                 origin: endpoint.placeID.map { .savedPlace($0) } ?? .address)
    }
}

extension SavedJourney {
    /// The two ends, ready for the map.
    public var mapEnds: (origin: MapPlace, destination: MapPlace) {
        (MapPlace.savedEndpoint(origin), MapPlace.savedEndpoint(destination))
    }
}
