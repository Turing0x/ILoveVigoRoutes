import Foundation

/// One stretch a passenger covers on foot, as the two points it joins.
///
/// A straight line, and named as one. There is no pedestrian routing behind it and there is
/// not meant to be: asking `MKDirections` for the real pavement would be a network round trip
/// per walk leg per alternative — up to eight on a four-alternative answer — with both
/// endpoints leaving the device on every re-plan, which this project only does when the user
/// deliberately presses a place. Everything the app already says about walking is the
/// straight-line figure (`JourneyLegRow` writes "en línea recta", `NearbyStop.distanceMetres`
/// is documented as such), so drawing it dashed says in the picture exactly what the text
/// already says in words.
public struct WalkSegment: Sendable, Hashable {
    public let from: Coordinate
    public let to: Coordinate

    public init(from: Coordinate, to: Coordinate) {
        self.from = from
        self.to = to
    }
}

extension Journey {
    /// The walk legs as drawable geometry, in the order they are walked.
    ///
    /// Exists because the map used to draw none of them: `JourneyTraceBuilder` skipped every
    /// leg that was not a `.ride`, so the bus line floated with nothing joining it to the two
    /// endpoints — and a `walkOnly` journey, which has no ride at all, drew nothing whatsoever.
    ///
    /// A leg whose two ends are the same point contributes nothing. That is the ordinary case
    /// of an origin that *is* the boarding stop: the reconstruction still emits the access leg,
    /// with zero seconds, and a line of zero length under the pin is noise, not information.
    public var walkSegments: [WalkSegment] {
        legs.compactMap { leg in
            guard case .walk(let from, let to, _, _) = leg else { return nil }
            let ends = (from.coordinate, to.coordinate)
            guard ends.0 != ends.1 else { return nil }
            return WalkSegment(from: ends.0, to: ends.1)
        }
    }
}
