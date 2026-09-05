import Foundation
import CoreLocation
import VigoCore

/// What reverse geocoding managed to say about a coordinate. Both fields optional, because
/// both are decoration: a pressed point is plannable with no name at all.
struct ResolvedPoint: Sendable, Equatable {
    var name: String?
    var subtitle: String?

    static let unknown = ResolvedPoint(name: nil, subtitle: nil)
}

/// The seam where "what is at this coordinate?" can be swapped, mirroring `AddressSearching`
/// and, in `VigoCore`, `RealtimeArrivalsProviding` and `GTFSFeedDownloading`.
@MainActor
protocol MapPlaceResolving: AnyObject {
    func resolve(coordinate: Coordinate) async -> ResolvedPoint
}

/// Reverse geocoding through Apple, under two rules.
///
/// **Only for a point the user pressed on purpose.** Never the device's own position, never
/// on a loop as the map moves. `NSLocationWhenInUseUsageDescription` promises the user's
/// location does not leave the device, and `AddressSearch.swift` already spends a paragraph
/// on why address search is biased to a fixed Vigo box rather than to wherever the user is.
/// Geocoding a tapped point sends *that* coordinate — which the user chose, and which is not
/// where they are — and nothing else.
///
/// **Failure is normal, not exceptional.** No network, Apple throttling, or a point in the
/// middle of the ría all produce `.unknown`, and the caller falls back to "Punto en el mapa".
/// That is why this returns a value instead of throwing: there is nothing for a caller to
/// handle differently.
@MainActor
final class MapKitPlaceResolver: MapPlaceResolving {
    private let geocoder = CLGeocoder()

    func resolve(coordinate: Coordinate) async -> ResolvedPoint {
        // Only one lookup at a time: pressing three points quickly should answer the last
        // one, not race three replies into the same card.
        if geocoder.isGeocoding { geocoder.cancelGeocode() }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(
            location, preferredLocale: Locale(identifier: "es_ES")).first
        else { return .unknown }

        return ResolvedPoint(name: Self.streetLine(placemark) ?? placemark.name,
                             subtitle: placemark.locality)
    }

    /// "Rúa do Areal, 12" when there is a street and a number, just the street when there is
    /// no number, `nil` when there is no street at all.
    private static func streetLine(_ placemark: CLPlacemark) -> String? {
        guard let street = placemark.thoroughfare else { return nil }
        guard let number = placemark.subThoroughfare else { return street }
        return "\(street), \(number)"
    }
}

extension MapPlace {
    /// Bridges what `PlacePickerView` hands back into the map's own place type.
    ///
    /// The picker can return a stop, the device's position, or a coordinate that came from an
    /// address, a saved place or a tap on its own mini-map — and `PickedPlace` only
    /// distinguishes the first two. The rest are recorded as `.address`, which is what they
    /// almost always are; the origin only decides the glyph and whether stop actions are
    /// offered, and neither of those would be more correct under another guess.
    init(picked: PickedPlace) {
        if picked.isCurrentLocation {
            self = .currentLocation(picked.place.coordinate)
        } else if case .stop(let stop) = picked.place {
            self = .stop(stop)
        } else {
            self = MapPlace(place: picked.place, subtitle: nil, origin: .address)
        }
    }
}

extension PlacePickerRole: Identifiable {
    var id: Self { self }
}
