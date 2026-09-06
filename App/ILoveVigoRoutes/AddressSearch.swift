import Foundation
import MapKit
import VigoCore

/// One row in the "Direcciones" section, before it has coordinates.
///
/// Deliberately a plain value and not an `MKLocalSearchCompletion`: that is a main-actor
/// class which only its own completer may outlive, and letting it reach the view would drag
/// MapKit into every place that merely wants to draw a row.
struct AddressSuggestion: Identifiable, Sendable, Hashable {
    let title: String
    let subtitle: String

    /// Doubles as the token `MapKitAddressSearchService.resolve(_:)` looks its
    /// `MKLocalSearchCompletion` up by. Derived from the content, not a random `UUID`
    /// (H-19): the completer re-emits "refinements" for one fragment, several times, and a
    /// fresh random id on every emission made `ForEach` treat each one as new content, and
    /// made `resolving == suggestion.id` stop matching mid-resolution the moment a
    /// refinement landed. Joined with a newline rather than plain concatenation, so a
    /// title/subtitle pair split one way cannot collide with a different pair split another
    /// — real completion text is single-line, so this never collides in practice.
    var id: String { "\(title)\n\(subtitle)" }
}

enum AddressSearchError: Error, Sendable, Equatable {
    /// No network, or MapKit throttled us.
    case unavailable
    /// The completion resolved to nothing. Rare, but MapKit allows it.
    case notFound
    /// It resolved somewhere the bus network does not reach.
    case outsideCoverage
}

/// The one place address lookup can be swapped, mirroring `RealtimeArrivalsProviding` and
/// `GTFSFeedDownloading` in VigoCore: tests get a stub, the app gets MapKit.
///
/// `@MainActor` rather than `Sendable` because the only real implementation is bound to a
/// delegate-based API that must be driven from the main actor, and everything that calls it
/// is a view or a view model, which is already there.
@MainActor
protocol AddressSearching: AnyObject {
    func suggestions(for query: String) async -> [AddressSuggestion]
    func resolve(_ suggestion: AddressSuggestion) async throws -> Place
}

/// The box address results are constrained to.
///
/// Fixed on purpose. Biasing the search to the user's live coordinate would send their
/// position to Apple, and `NSLocationWhenInUseUsageDescription` promises it never leaves the
/// device — a promise worth more than the negligible gain in result quality for a city this
/// size. Everything the user could plausibly plan a bus journey to is inside this box anyway.
///
/// Roughly 28 km across: Vigo plus Redondela, Nigrán, Baiona and Cangas, which is where the
/// imported feed has stops, and not much else.
enum VigoSearchRegion {
    /// Same Praza de América centre as `LocationProvider`, kept here as a value rather than
    /// reading its main-actor-isolated static member: this region deliberately has no link
    /// to live location and must also be usable by non-UI tests.
    static let centre = CLLocationCoordinate2D(latitude: 42.2328, longitude: -8.7226)
    static let span = MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.30)
    static let region = MKCoordinateRegion(center: centre, span: span)

    static func contains(_ coordinate: Coordinate) -> Bool {
        let centre = region.center
        return abs(coordinate.latitude - centre.latitude) <= span.latitudeDelta / 2
            && abs(coordinate.longitude - centre.longitude) <= span.longitudeDelta / 2
    }
}
