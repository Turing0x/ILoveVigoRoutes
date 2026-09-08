import Foundation

/// The smallest lat/lon rectangle holding a set of coordinates, plus the arithmetic a map
/// needs to frame it.
///
/// Pulled out of `JourneyTraceBuilder` in the app, where the same maths lived inline and
/// untested. It matters more now than it did: the map has to frame **several** alternatives
/// at once, so a wrong union is a route drawn half off screen rather than a cosmetic slip.
///
/// No MapKit here. The app turns this into an `MKCoordinateRegion` at the edge.
public struct CoordinateBounds: Sendable, Equatable {
    public let minLatitude: Double
    public let maxLatitude: Double
    public let minLongitude: Double
    public let maxLongitude: Double

    /// `nil` for an empty sequence: there is no rectangle around nothing, and inventing one
    /// centred on Vigo would frame a route that does not exist.
    public init?(_ coordinates: some Sequence<Coordinate>) {
        var iterator = coordinates.makeIterator()
        guard let first = iterator.next() else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        while let next = iterator.next() {
            minLat = Swift.min(minLat, next.latitude)
            maxLat = Swift.max(maxLat, next.latitude)
            minLon = Swift.min(minLon, next.longitude)
            maxLon = Swift.max(maxLon, next.longitude)
        }
        self.init(minLatitude: minLat, maxLatitude: maxLat,
                  minLongitude: minLon, maxLongitude: maxLon)
    }

    public init(minLatitude: Double, maxLatitude: Double,
                minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = Swift.min(minLatitude, maxLatitude)
        self.maxLatitude = Swift.max(minLatitude, maxLatitude)
        self.minLongitude = Swift.min(minLongitude, maxLongitude)
        self.maxLongitude = Swift.max(minLongitude, maxLongitude)
    }

    public func union(_ other: CoordinateBounds) -> CoordinateBounds {
        CoordinateBounds(minLatitude: Swift.min(minLatitude, other.minLatitude),
                         maxLatitude: Swift.max(maxLatitude, other.maxLatitude),
                         minLongitude: Swift.min(minLongitude, other.minLongitude),
                         maxLongitude: Swift.max(maxLongitude, other.maxLongitude))
    }

    /// Folds any number of boxes into one, ignoring the empty ones. `nil` only when there was
    /// nothing at all to frame.
    public static func union(_ boxes: some Sequence<CoordinateBounds?>) -> CoordinateBounds? {
        boxes.compactMap { $0 }.reduce(nil) { total, next in
            total.map { $0.union(next) } ?? next
        }
    }

    public var centre: Coordinate {
        Coordinate(latitude: (minLatitude + maxLatitude) / 2,
                   longitude: (minLongitude + maxLongitude) / 2)
    }

    public var latitudeSpan: Double { maxLatitude - minLatitude }
    public var longitudeSpan: Double { maxLongitude - minLongitude }

    /// Spans with room around the edges, and a floor.
    ///
    /// The floor is what stops a two-stop hop — or a single point, whose span is zero — from
    /// opening zoomed onto the pavement. The factor is what keeps the ends of a journey off
    /// the very edge of the screen, where a sheet or a control usually sits.
    public func paddedSpans(factor: Double = 1.4,
                            minimum: Double = 0.005) -> (latitude: Double, longitude: Double) {
        (latitude: Swift.max(latitudeSpan * factor, minimum),
         longitude: Swift.max(longitudeSpan * factor, minimum))
    }
}

extension Journey {
    /// Every coordinate the journey names by itself: both ends of each walk, and the boarding
    /// and alighting stop of each ride.
    ///
    /// Deliberately excludes the shape polyline, which the app reads separately — a journey
    /// must still be framable when a trip has no `shape_id`, which GTFS permits.
    public var keyCoordinates: [Coordinate] {
        legs.flatMap { leg -> [Coordinate] in
            switch leg {
            case .walk(let from, let to, _, _):
                [from.coordinate, to.coordinate]
            case .ride(_, _, _, _, let board, let alight, _, _, _):
                [Coordinate(board), Coordinate(alight)]
            }
        }
    }

    /// Where the journey starts and ends on the ground, or `nil` for a journey with no legs.
    ///
    /// The first and last leg used to be guaranteed walks — origin to a stop, a stop to the
    /// destination — so the map read those two ends directly. They are not guaranteed any
    /// more: `JourneyReconstruction` leaves out an access or egress walk shorter than
    /// `negligibleWalkSeconds`, because a stop that *is* the door is not a stretch on foot.
    /// When that happens the end of the journey is the boarding or alighting stop, which is
    /// the same place to within the accuracy of the stop's own position.
    public var endpointCoordinates: (origin: Coordinate, destination: Coordinate)? {
        func end(of leg: JourneyLeg, takingStart: Bool) -> Coordinate {
            switch leg {
            case .walk(let from, let to, _, _):
                takingStart ? from.coordinate : to.coordinate
            case .ride(_, _, _, _, let board, let alight, _, _, _):
                takingStart ? Coordinate(board) : Coordinate(alight)
            }
        }
        guard let first = legs.first, let last = legs.last else { return nil }
        return (origin: end(of: first, takingStart: true),
                destination: end(of: last, takingStart: false))
    }
}
