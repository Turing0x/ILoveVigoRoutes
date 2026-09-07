import SwiftUI
import MapKit
import VigoCore

/// The full recorrido of a line, end to end, with its stops marked.
///
/// Reuses `TransitRepository.routeTraces` — the same `shapePoint` rows `JourneyTraceBuilder`
/// already draws per journey, undrawn here to the whole route instead of the stretch a single
/// trip rode. No recalculation, no second source of geometry: if the seguimiento en pantalla
/// de bloqueo work ever reconstructs trazados from `lineas-vitrasa`, this reads from the same
/// `shapePoint` table either way and needs no change.
struct LineTraceView: View {
    @Environment(AppEnvironment.self) private var environment

    let routeID: RouteID
    let routeShortName: String

    @State private var traces: [RouteTrace] = []
    @State private var selectedDirection: Int?
    @State private var loading = true
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: LocationProvider.vigoCentre,
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)))

    var body: some View {
        Group {
            if loading {
                ProgressView("Leyendo el trazado…")
            } else if let selected {
                map(for: selected)
            } else {
                ContentUnavailableView(
                    "Sin trazado", systemImage: "map",
                    description: Text("La línea \(routeShortName) no tiene un trazado disponible en el GTFS."))
            }
        }
        .navigationTitle("Línea \(routeShortName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if traces.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { directionPicker }
            }
        }
        .task { await load() }
    }

    private var selected: RouteTrace? {
        traces.first { $0.directionID == selectedDirection } ?? traces.first
    }

    private func map(for trace: RouteTrace) -> some View {
        Map(position: $camera) {
            MapPolyline(coordinates: trace.points.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            })
            .stroke(.indigo, lineWidth: 4)

            ForEach(trace.stops) { stop in
                Marker(stop.name, systemImage: "circle.fill", coordinate: Coordinate(stop).clLocation)
                    .tint(.indigo)
            }
        }
        .mapStyle(.standard)
        // Framed once per direction, not on every appearance: the owner can still pan and
        // zoom freely afterwards, and re-framing under their finger would fight that.
        .onChange(of: trace.id, initial: true) { _, _ in frame(trace) }
    }

    /// The smallest region holding the whole trazado, stops included, with the same margin
    /// `JourneyTraceBuilder` already uses for a journey — the criterio de aceptación asks for
    /// exactly this: "encuadrado para verse entero de inicio".
    private func frame(_ trace: RouteTrace) {
        let coordinates = trace.points.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
            + trace.stops.map(Coordinate.init)
        guard let bounds = CoordinateBounds(coordinates) else { return }
        let spans = bounds.paddedSpans()
        camera = .region(MKCoordinateRegion(
            center: bounds.centre.clLocation,
            span: MKCoordinateSpan(latitudeDelta: spans.latitude, longitudeDelta: spans.longitude)))
    }

    private var directionPicker: some View {
        Menu {
            ForEach(traces) { trace in
                Button {
                    selectedDirection = trace.directionID
                } label: {
                    let label = trace.headsign ?? "Sentido \(trace.directionID)"
                    if trace.directionID == selected?.directionID {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            Label("Sentido", systemImage: "arrow.left.arrow.right")
        }
    }

    private func load() async {
        let repository = environment.repository
        let routeID = self.routeID
        // Off the main actor: the shape of a long line is thousands of `shapePoint` rows.
        traces = await Task.detached(priority: .userInitiated) {
            (try? repository.routeTraces(routeID: routeID)) ?? []
        }.value
        selectedDirection = traces.first?.directionID
        loading = false
    }
}
