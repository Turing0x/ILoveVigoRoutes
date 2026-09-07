import Foundation
import CoreLocation
import Observation
import VigoCore

/// The app's one `CLLocationManager`, leased.
///
/// `LocationProvider` stays exactly what it was — a thin wrapper over CoreLocation — and this
/// owns the single instance of it plus the `LocationDemand` that decides when it runs. Screens
/// no longer call `start()`/`stop()`: they take a lease for as long as they are on screen and
/// say how precise they need it, and the arithmetic of "is anyone left, and who wants the
/// finest fix" happens in `VigoCore` under `swift test`.
///
/// Why this exists at all (H-50): `MapScreen` and `MapSearchSheet` each declared
/// `@State private var location = LocationProvider()` with an *eager* initialiser, so a fresh
/// `CLLocationManager` — a synchronous XPC round trip to `locationd` — was built and thrown
/// away on every re-evaluation of the body that presented them, during the very transition
/// that was stuttering. And because both survived, two managers delivered fixes at once
/// whenever the search sheet sat over the map.
@MainActor
@Observable
final class SharedLocation {
    private let provider = LocationProvider()
    private var demand = LocationDemand()

    init() {
        provider.onAuthorizationChange = { [weak self] in self?.reapply() }
    }

    var coordinate: CLLocationCoordinate2D? { provider.coordinate }
    var isAuthorized: Bool { provider.isAuthorized }
    var isDenied: Bool { provider.isDenied }
    var failure: String? { provider.failure }

    func requestPermissionIfNeeded() { provider.requestPermissionIfNeeded() }

    /// Takes (or updates) this holder's lease. Idempotent: acquiring at a precision already in
    /// force does nothing at all.
    func acquire(_ holder: LocationDemand.Holder,
                 precision: LocationDemand.Precision = .coarse) {
        apply(demand.acquire(holder, precision: precision))
    }

    func release(_ holder: LocationDemand.Holder) {
        apply(demand.release(holder))
    }

    /// Re-states the current demand to CoreLocation, for the one case where nothing about the
    /// demand changed but its answer did: permission arriving after the lease was taken.
    private func reapply() {
        guard let precision = demand.precision else { return provider.stop() }
        start(precision)
    }

    private func apply(_ effect: LocationDemand.Effect) {
        switch effect {
        case .unchanged:
            break
        case .stop:
            provider.stop()
        case .start(let precision):
            start(precision)
        }
    }

    /// `start(accuracy:)` re-applies `desiredAccuracy` and is idempotent on an already-running
    /// manager, so a precision change needs no `stop()` in between — which is what made the old
    /// `stop(); start()` pair on leaving follow mode a downgrade rather than a change (H-50).
    private func start(_ precision: LocationDemand.Precision) {
        provider.start(accuracy: precision == .fine ? kCLLocationAccuracyBest
                                                    : kCLLocationAccuracyHundredMeters)
    }
}
