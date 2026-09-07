import Foundation

/// Who currently wants the device's position, and how precisely.
///
/// This lives in `VigoCore` for the same reason `MapNavigationState` does: it is bookkeeping,
/// and bookkeeping is exactly the kind of thing that rots into a pair of booleans that
/// disagree. The failure it is written against was in the shipped app (H-50): `MapScreen` and
/// `MapSearchSheet` each owned a `LocationProvider`, so the sheet ran a second
/// `CLLocationManager` alongside the map's — the map's `onDisappear` does not fire under a
/// sheet — and the sheet's own `onDisappear` then stopped only its half. The other direction
/// was worse: leaving follow mode called `stop()` and then `start()` at the coarse default,
/// silently downgrading a screen that had asked for the fine one.
///
/// Deliberately not `CoreLocation`-aware. `Precision` is an order, not a number of metres; the
/// app maps it to `kCLLocationAccuracyHundredMeters` / `kCLLocationAccuracyBest` in the one
/// place that owns the manager. That is what lets every rule here be checked by `swift test`.
public struct LocationDemand: Sendable, Equatable {

    /// Coarse is enough to answer "which stops are near me". Fine is what walking a route
    /// needs. Ordered, because when two holders disagree the finer request wins: the coarse
    /// holder is served perfectly well by a better fix, never the other way round.
    public enum Precision: Int, Sendable, Comparable {
        case coarse = 0
        case fine = 1

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One holder per view instance.
    ///
    /// A `UUID` rather than a name because two `MapSearchSheet`s can be on screen at once —
    /// the map's own, and the nested one the route sheet presents over it — and named keys
    /// would collapse those two leases into one, so the first to disappear would turn the
    /// location off under the second.
    public struct Holder: Hashable, Sendable {
        public let id: UUID

        public init(id: UUID = UUID()) { self.id = id }
    }

    /// What the caller must actually do to CoreLocation, if anything.
    ///
    /// Returned rather than left to the caller to work out, so "did the winning precision
    /// change?" is decided here, once, where it is tested.
    public enum Effect: Sendable, Equatable {
        case unchanged
        case start(Precision)
        case stop
    }

    private var holders: [Holder: Precision] = [:]

    public init() {}

    /// The finest precision anyone is asking for, or `nil` when nobody is.
    public var precision: Precision? { holders.values.max() }

    public var isIdle: Bool { holders.isEmpty }

    @discardableResult
    public mutating func acquire(_ holder: Holder, precision: Precision = .coarse) -> Effect {
        let before = self.precision
        holders[holder] = precision
        return effect(from: before)
    }

    /// Releasing a holder that never acquired is a no-op, not a `precondition` failure:
    /// `.onDisappear` can outlive the `.task` that would have acquired, and trapping on a tab
    /// switch would be a very expensive way to enforce symmetry.
    @discardableResult
    public mutating func release(_ holder: Holder) -> Effect {
        let before = precision
        holders[holder] = nil
        return effect(from: before)
    }

    private func effect(from before: Precision?) -> Effect {
        let after = precision
        guard before != after else { return .unchanged }
        guard let after else { return .stop }
        return .start(after)
    }
}
