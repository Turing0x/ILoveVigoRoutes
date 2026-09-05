import SwiftUI
import MapKit
import VigoCore

/// One drawable stretch of a journey: the part of a trip's shape actually ridden, or the
/// straight line of a leg walked.
struct JourneyTrace: Identifiable, Sendable {
    enum Kind: Sendable, Equatable {
        /// Follows the real streets, from `shapePoint`.
        case ride
        /// A straight line, drawn dashed because that is exactly what it is. See
        /// `WalkSegment` for why there is no pedestrian routing behind it.
        case walk
    }

    let id: Int
    let kind: Kind
    let coordinates: [CLLocationCoordinate2D]
}

/// Turns a `Journey` into what a map needs: the real traces from `shapePoint`, and a region
/// that holds the whole thing.
///
/// Lives outside the views because the map draws several journeys at once — the highlighted
/// alternative and the others behind it — and a journey that looked different depending on
/// which of them it was would be a bug waiting to happen.
enum JourneyTraceBuilder {

    static func traces(for journey: Journey, repository: TransitRepository) -> [JourneyTrace] {
        var found: [JourneyTrace] = []
        for (index, leg) in journey.legs.enumerated() {
            guard case .ride(_, _, _, let tripID, let board, let alight, _, _, _) = leg,
                  let trip = try? repository.trip(id: tripID),
                  let shapeID = trip.shapeID,
                  let points = try? repository.shape(id: shapeID), points.count > 1
            else { continue }

            let coordinates = points.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            found.append(JourneyTrace(
                id: index,
                kind: .ride,
                coordinates: trim(coordinates,
                                  boardCoordinate: Coordinate(board),
                                  alightCoordinate: Coordinate(alight))))
        }

        // The walks, after the rides and with ids that cannot collide with a leg index.
        //
        // Which legs are walked, and in what direction, is decided by `Journey.walkSegments`
        // in `VigoCore` — a pure function `swift test` covers on the Mac, unlike everything
        // above it here, which needs SQLite.
        for (offset, segment) in journey.walkSegments.enumerated() {
            found.append(JourneyTrace(
                id: journey.legs.count + offset,
                kind: .walk,
                coordinates: [segment.from.clLocation, segment.to.clLocation]))
        }
        return found
    }

    /// The smallest region that holds the whole journey — every trace point plus every stop
    /// and endpoint it names — with a margin so nothing sits against the edge.
    ///
    /// Framing on the first point of the first trace, as this used to, cuts long journeys in
    /// half: the map opens on the boarding stop and the destination is off screen.
    static func region(for journey: Journey, traces: [JourneyTrace]) -> MKCoordinateRegion {
        region(for: [journey], traces: [traces])
    }

    /// The same, for several alternatives at once, so the map can open showing all of them.
    ///
    /// `traces` is parallel to `journeys`; a journey whose trip carries no `shape_id` — which
    /// GTFS permits — simply contributes its stops and endpoints, via `keyCoordinates`.
    static func region(for journeys: [Journey], traces: [[JourneyTrace]]) -> MKCoordinateRegion {
        var boxes: [CoordinateBounds?] = []
        for (index, journey) in journeys.enumerated() {
            var coordinates = journey.keyCoordinates
            if traces.indices.contains(index) {
                coordinates += traces[index].flatMap(\.coordinates).map {
                    Coordinate(latitude: $0.latitude, longitude: $0.longitude)
                }
            }
            boxes.append(CoordinateBounds(coordinates))
        }

        guard let bounds = CoordinateBounds.union(boxes) else {
            return MKCoordinateRegion(center: LocationProvider.vigoCentre,
                                      span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04))
        }
        let spans = bounds.paddedSpans()
        return MKCoordinateRegion(
            center: bounds.centre.clLocation,
            span: MKCoordinateSpan(latitudeDelta: spans.latitude, longitudeDelta: spans.longitude))
    }

    /// The shape covers the whole trip; a passenger only rode part of it. Cuts the polyline
    /// down to the stretch between the two shape points closest to the boarding and
    /// alighting stops.
    ///
    /// Closest-point matching, not sequence lookup: GTFS does not promise a shape point
    /// exactly at every stop, only that the stops sit near the line it draws.
    private static func trim(
        _ coordinates: [CLLocationCoordinate2D], boardCoordinate: Coordinate, alightCoordinate: Coordinate
    ) -> [CLLocationCoordinate2D] {
        func nearestIndex(to target: Coordinate) -> Int {
            var bestIndex = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (index, point) in coordinates.enumerated() {
                let distance = TransitRepository.haversineMetres(
                    point.latitude, point.longitude, target.latitude, target.longitude)
                if distance < bestDistance { bestDistance = distance; bestIndex = index }
            }
            return bestIndex
        }
        let boardIndex = nearestIndex(to: boardCoordinate)
        let alightIndex = nearestIndex(to: alightCoordinate)
        let lower = min(boardIndex, alightIndex)
        let upper = max(boardIndex, alightIndex)
        guard lower < upper else { return coordinates }
        return Array(coordinates[lower...upper])
    }
}

/// The journey itself as map content: the ridden stretches, the two ends, and every
/// boarding and alighting stop.
struct JourneyMapContent: MapContent {
    let journey: Journey
    let traces: [JourneyTrace]

    var body: some MapContent {
        ForEach(traces) { trace in
            switch trace.kind {
            case .ride:
                MapPolyline(coordinates: trace.coordinates)
                    .stroke(.indigo, lineWidth: 4)
            case .walk:
                // Dashed, and the same indigo: it is the same journey, not another thing.
                // The dashes are the honest part — this is a straight line between two
                // points, not a pavement, and a solid stroke would promise a route across
                // whatever happens to lie between them.
                MapPolyline(coordinates: trace.coordinates)
                    .stroke(.indigo.opacity(0.75),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [1, 9]))
            }
        }
        // The chain always opens and closes with a walk leg — into the network from the
        // real origin, and out of it to the real destination — so these two are always
        // present, `walkOnly` included (there `legs.first == legs.last`).
        if case .walk(let from, _, _, _) = journey.legs.first {
            Marker("Origen", systemImage: "figure.walk.departure", coordinate: from.coordinate.clLocation)
                .tint(.blue)
        }
        if case .walk(_, let to, _, _) = journey.legs.last {
            Marker("Destino", systemImage: "flag.checkered", coordinate: to.coordinate.clLocation)
                .tint(.blue)
        }
        ForEach(Array(journey.legs.enumerated()), id: \.offset) { _, leg in
            if case .ride(_, _, _, _, let board, let alight, _, _, _) = leg {
                Marker(board.name, systemImage: "arrow.up.circle.fill",
                      coordinate: Coordinate(board).clLocation)
                    .tint(.green)
                Marker(alight.name, systemImage: "arrow.down.circle.fill",
                      coordinate: Coordinate(alight).clLocation)
                    .tint(.red)
            }
        }
    }
}

extension Coordinate {
    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
