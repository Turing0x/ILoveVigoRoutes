import Foundation
import CoreLocation
import Observation

/// Thin wrapper over CoreLocation.
///
/// Only ever asks for when-in-use, and only requests a location while a screen that needs
/// one is visible. Nothing is stored and nothing leaves the device.
@MainActor
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    private(set) var authorization: CLAuthorizationStatus
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var failure: String?

    /// Praza de América, used so the map and nearby list have somewhere sensible to sit
    /// before permission is granted. Never presented as the user's position.
    nonisolated static let vigoCentre = CLLocationCoordinate2D(latitude: 42.2328, longitude: -8.7226)

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    func requestPermissionIfNeeded() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// Hundred metres is enough to answer "which stops are near me", and cheap. Following
    /// someone along a route is a different question, so that screen asks for better fixes
    /// and this one goes back to the default as soon as it leaves.
    func start(accuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters) {
        guard isAuthorized else { return }
        manager.desiredAccuracy = accuracy
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Called after `authorization` changes, so whoever owns the lease can re-apply it.
    ///
    /// This used to be `if isAuthorized { start() }` right here, which was CoreLocation
    /// deciding that the manager should be running (H-50). Whether it should, and at what
    /// precision, is `LocationDemand`'s answer — `SharedLocation` re-applies the current demand
    /// instead, so permission granted mid-session starts at the precision whichever screen is
    /// actually up asked for, rather than at this class's default.
    var onAuthorizationChange: (@MainActor () -> Void)?

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.onAuthorizationChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coordinate = last.coordinate
        Task { @MainActor in
            self.coordinate = coordinate
            self.failure = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.failure = message }
    }
}
