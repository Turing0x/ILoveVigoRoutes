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
        // Where the journey begins and ends on the ground. Usually the two open-air walk
        // legs — into the network from the real origin, out of it to the real destination,
        // and for `walkOnly` the single leg is both. But `JourneyReconstruction` drops a
        // walk of under `negligibleWalkSeconds`, because a stop that *is* the door is not a
        // stretch on foot, so either end can be a ride instead; then the boarding or
        // alighting stop is the endpoint, which is the same place to within a few metres.
        if let origin = journey.endpointCoordinates?.origin {
            Marker("Origen", systemImage: "figure.walk.departure", coordinate: origin.clLocation)
                .tint(.blue)
        }
        if let destination = journey.endpointCoordinates?.destination {
            Marker("Destino", systemImage: "flag.checkered", coordinate: destination.clLocation)
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

// MARK: - A journey already under way (Fase 16)

extension JourneyTraceBuilder {

    /// The traces for a journey under way. Same shape reading and trimming as a planned
    /// journey, so the line on the map does not change look the moment "He subido" is pressed.
    ///
    /// A trip that no longer resolves after a reimport falls back to the stop-to-stop path —
    /// drawn solid because it is still the bus, but only through the stops it is known to call at.
    static func traces(for plan: RideTracePlan, repository: TransitRepository) -> [JourneyTrace] {
        var found: [JourneyTrace] = []
        for (index, ride) in plan.rides.enumerated() {
            let shape: [CLLocationCoordinate2D]? = {
                guard let tripID = ride.tripID,
                      let trip = try? repository.trip(id: tripID),
                      let shapeID = trip.shapeID,
                      let points = try? repository.shape(id: shapeID), points.count > 1
                else { return nil }
                return trim(points.map { CLLocationCoordinate2D(latitude: $0.latitude,
                                                                longitude: $0.longitude) },
                            boardCoordinate: ride.board, alightCoordinate: ride.alight)
            }()
            found.append(JourneyTrace(id: index, kind: .ride,
                                      coordinates: shape ?? ride.stopPath.map(\.clLocation)))
        }
        if let walk = plan.egressWalk {
            found.append(JourneyTrace(id: plan.rides.count, kind: .walk,
                                      coordinates: [walk.from.clLocation, walk.to.clLocation]))
        }
        return found
    }

    static func region(for plan: RideTracePlan, traces: [JourneyTrace]) -> MKCoordinateRegion {
        let coordinates = plan.keyCoordinates + traces.flatMap(\.coordinates).map {
            Coordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard let bounds = CoordinateBounds(coordinates) else {
            return MKCoordinateRegion(center: LocationProvider.vigoCentre,
                                      span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04))
        }
        let spans = bounds.paddedSpans()
        return MKCoordinateRegion(
            center: bounds.centre.clLocation,
            span: MKCoordinateSpan(latitudeDelta: spans.latitude, longitudeDelta: spans.longitude))
    }
}

/// The journey under way as map content. Drawn exactly like the highlighted alternative was —
/// same indigo, same dashed walk, same green and red pins — because it is the same journey.
struct RideTraceMapContent: MapContent {
    let plan: RideTracePlan
    let traces: [JourneyTrace]

    var body: some MapContent {
        ForEach(traces) { trace in
            switch trace.kind {
            case .ride:
                MapPolyline(coordinates: trace.coordinates)
                    .stroke(.indigo, lineWidth: 4)
            case .walk:
                MapPolyline(coordinates: trace.coordinates)
                    .stroke(.indigo.opacity(0.75),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [1, 9]))
            }
        }
        ForEach(Array(plan.rides.enumerated()), id: \.offset) { _, ride in
            Marker(ride.boardName, systemImage: "arrow.up.circle.fill",
                   coordinate: ride.board.clLocation)
                .tint(.green)
            Marker(ride.alightName, systemImage: "arrow.down.circle.fill",
                   coordinate: ride.alight.clLocation)
                .tint(.red)
        }
        if let destination = plan.destination {
            Marker("Destino", systemImage: "flag.checkered", coordinate: destination.clLocation)
                .tint(.blue)
        }
    }
}
