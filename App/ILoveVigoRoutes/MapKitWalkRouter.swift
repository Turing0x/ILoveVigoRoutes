import Foundation
import MapKit
import VigoCore

/// Measures walking legs with `MKDirections`, so the two open-air walks of a journey stop
/// being straight-line estimates.
///
/// **Why this is an actor with a cache and a ceiling.** `MKDirections` is a network service
/// with an undocumented rate limit, and a route list refreshes every time the user changes a
/// criterion, reorders, or re-plans. Without memoisation the same four walks would be looked
/// up over and over; without a ceiling a pathological screen could fan out dozens of requests
/// at once and get every one of them throttled.
///
/// Every failure is `nil`, never an error and never a throw. The planner's estimate is a
/// perfectly usable answer, and a walking figure that disappears because the network did is a
/// worse outcome than one that is approximate. This is the same contract `WalkRouter`'s doc
/// comment sets out.
actor MapKitWalkRouter: WalkRouter {

    /// Coordinates are rounded before they become a cache key: the origin is usually the
    /// device's position, which jitters by metres between fixes, and an un-rounded key would
    /// miss on every single refresh. Four decimals is about 11 m — the same resolution
    /// `Coordinate.rounded(toDecimals:)` is used at elsewhere in this app, and far finer than
    /// the error this whole mechanism exists to remove.
    private struct Key: Hashable {
        let from: Coordinate
        let to: Coordinate

        init(_ from: Coordinate, _ to: Coordinate) {
            self.from = from.rounded(toDecimals: 4)
            self.to = to.rounded(toDecimals: 4)
        }
    }

    /// `nil` is cached too, and on purpose. A walk MapKit declined to route once — a point on
    /// an island, a coordinate in the water — will be declined again, and re-asking on every
    /// refresh would spend the rate limit on a question with a known answer.
    private var cache: [Key: Int?] = [:]
    private var inFlight = 0

    /// How many lookups may be outstanding at once.
    ///
    /// Four: the list shows at most `PlannerOptions.maxAlternatives` journeys, so this lets
    /// one screenful proceed and makes anything beyond it wait for the estimate instead of
    /// queueing behind a request nobody is looking at any more.
    private let ceiling = 4

    /// Walks longer than this are not looked up at all.
    ///
    /// A walk-only journey across the city can be several kilometres, and `MKDirections`
    /// would happily route it — but the refinement exists to decide whether a bus can be
    /// caught, and no bus is caught at the end of a forty-minute walk. Skipping them keeps
    /// the rate limit for the cases that matter.
    private let maxMetres: Double = 3_000

    func walkSeconds(from: Coordinate, to: Coordinate) async -> Int? {
        let key = Key(from, to)
        if let cached = cache[key] { return cached }

        let metres = TransitRepository.haversineMetres(
            from.latitude, from.longitude, to.latitude, to.longitude)
        guard metres > 20, metres <= maxMetres else { return nil }
        guard inFlight < ceiling else { return nil }

        inFlight += 1
        defer { inFlight -= 1 }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)))
        request.transportType = .walking
        // One route. Alternatives are a different question and cost the same rate limit.
        request.requestsAlternateRoutes = false

        let seconds: Int?
        do {
            let response = try await MKDirections(request: request).calculate()
            // MapKit's own travel time, not distance divided by an assumed speed: it already
            // accounts for crossings and the gradient this app has no elevation data for.
            seconds = response.routes.first.map { Int($0.expectedTravelTime.rounded(.up)) }
        } catch {
            seconds = nil
        }
        cache[key] = seconds
        return seconds
    }

    /// Drops everything remembered. Only for a feed refresh, where the stops themselves may
    /// have moved; nothing about a pavement goes stale on its own.
    func invalidate() { cache.removeAll() }
}
