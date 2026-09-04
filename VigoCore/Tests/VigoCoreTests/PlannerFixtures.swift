import Foundation
@testable import VigoCore

/// Synthetic geometry and timetables for the planner tests.
///
/// Distances here are exact rather than approximate: the offsets use the same earth
/// radius as `TransitRepository.haversineMetres`, so a stop built with
/// `northMetres: 250` really is 250 m away and a test can assert on the boundary of a
/// radius without a fudge factor.
enum PlannerFixture {

    /// Praza de América, the origin for all synthetic layouts.
    static let base = Coordinate(latitude: 42.2209973130163, longitude: -8.73283517659561)

    /// Metres per degree of latitude on the sphere `haversineMetres` uses.
    static let metresPerDegree = 6_371_000.0 * .pi / 180.0

    static func stop(
        _ id: String, northMetres: Double = 0, eastMetres: Double = 0, name: String? = nil
    ) -> Stop {
        let latitude = base.latitude + northMetres / metresPerDegree
        let longitude = base.longitude
            + eastMetres / (metresPerDegree * cos(base.latitude * .pi / 180))
        let displayName = name ?? "Parada \(id)"
        return Stop(
            id: StopID(id), gtfsStopCode: "P\(id)", vitrasaCode: VitrasaStopCode(gtfsStopCode: id),
            name: displayName, searchName: TextNormalization.searchFolded(displayName),
            latitude: latitude, longitude: longitude, wheelchairBoarding: nil)
    }
}
