import SwiftUI
import MapKit
import VigoCore

/// Leg by leg, with the real trace on the map — the first place `shapePoint` is read at
/// all: it has been imported, indexed, and sitting unused since Fase 0.
struct JourneyDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let journey: Journey

    @State private var camera: MapCameraPosition = .automatic
    @State private var traces: [Trace] = []
    @State private var liveFirstBoarding: Arrival?

    private struct Trace: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
    }

    /// The first ride — real time, kept out of `RaptorEngine` by design, is annotated only
    /// here, and only for this one boarding: the rest of the journey is still the
    /// timetable, and saying otherwise would be a promise the realtime source cannot keep.
    private var firstRide: (routeShortName: String, board: Stop, departure: Date)? {
        for leg in journey.legs {
            if case .ride(_, let routeShortName, _, _, let board, _, let departure, _, _) = leg {
                return (routeShortName, board, departure)
            }
        }
        return nil
    }

    var body: some View {
        List {
            Section {
                Map(position: $camera) {
                    ForEach(traces) { trace in
                        MapPolyline(coordinates: trace.coordinates)
                            .stroke(.indigo, lineWidth: 4)
                    }
                    mapMarkers
                }
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
            }

            if let firstRide, let liveFirstBoarding {
                Section {
                    HStack(spacing: 10) {
                        DataKindBadge(kind: liveFirstBoarding.confidence.hasTrackedVehicle ? .tracked : .estimated)
                        Text("Línea \(firstRide.routeShortName): \(WaitTime(minutes: liveFirstBoarding.minutes).inlineText)")
                            .font(.subheadline)
                        Spacer(minLength: 0)
                    }
                } header: {
                    Text("Primer embarque, en vivo")
                } footer: {
                    Text("El resto del trayecto sigue siendo el horario: el tiempo real solo cubre la parada de origen.")
                }
            }

            Section("Tramos") {
                ForEach(Array(journey.legs.enumerated()), id: \.offset) { _, leg in
                    JourneyLegRow(leg: leg)
                }
            }
        }
        .navigationTitle("Detalle del trayecto")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            load()
            await loadLiveFirstBoarding()
        }
    }

    @MapContentBuilder
    private var mapMarkers: some MapContent {
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
                      coordinate: CLLocationCoordinate2D(latitude: board.latitude, longitude: board.longitude))
                    .tint(.green)
                Marker(alight.name, systemImage: "arrow.down.circle.fill",
                      coordinate: CLLocationCoordinate2D(latitude: alight.latitude, longitude: alight.longitude))
                    .tint(.red)
            }
        }
    }

    private func load() {
        var found: [Trace] = []
        for (index, leg) in journey.legs.enumerated() {
            guard case .ride(_, _, _, let tripID, let board, let alight, _, _, _) = leg,
                  let trip = try? environment.repository.trip(id: tripID),
                  let shapeID = trip.shapeID,
                  let points = try? environment.repository.shape(id: shapeID), points.count > 1
            else { continue }

            let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let trimmed = Self.trim(coordinates, boardCoordinate: Coordinate(board), alightCoordinate: Coordinate(alight))
            found.append(Trace(id: index, coordinates: trimmed))
        }
        traces = found

        if let first = found.first(where: { !$0.coordinates.isEmpty })?.coordinates.first {
            camera = .region(MKCoordinateRegion(
                center: first, span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)))
        }
    }

    /// Matches the first ride against the realtime feed for its boarding stop.
    ///
    /// The realtime API has no notion of "this specific scheduled trip" — only a line, a
    /// destination, and a countdown from now — so the match is heuristic: same line,
    /// implied absolute time closest to the one this leg already committed to, and only
    /// accepted within 15 minutes of it. Outside that window this is almost certainly a
    /// different vehicle on the same line, and showing it would be worse than showing
    /// nothing. A future-dated query (anything but "ahora") never matches, which is
    /// correct: the realtime feed only ever knows about buses already close to arriving.
    private func loadLiveFirstBoarding() async {
        guard let firstRide else { return }
        let normalizedLine = TextNormalization.normalizedLineName(firstRide.routeShortName)
        let now = Date()
        let result = await environment.arrivals.arrivals(for: firstRide.board, now: now)

        let closest = result.arrivals
            .filter { $0.normalizedLine == normalizedLine }
            .min { a, b in
                abs(now.addingTimeInterval(TimeInterval(a.minutes * 60)).timeIntervalSince(firstRide.departure))
                    < abs(now.addingTimeInterval(TimeInterval(b.minutes * 60)).timeIntervalSince(firstRide.departure))
            }
        guard let closest else { return }
        let impliedArrival = now.addingTimeInterval(TimeInterval(closest.minutes * 60))
        guard abs(impliedArrival.timeIntervalSince(firstRide.departure)) <= 15 * 60 else { return }
        liveFirstBoarding = closest
    }

    /// The shape covers the whole trip; a passenger only rode part of it. Cuts the
    /// polyline down to the stretch between the two shape points closest to the boarding
    /// and alighting stops — the "helper que recorte el trazado" the plan calls for.
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

private extension Coordinate {
    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
