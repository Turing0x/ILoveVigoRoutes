import SwiftUI
import CoreLocation
import VigoCore

/// «Paradas cercanas»: the stops around the device, nearest first, to say "I am at this one".
///
/// Back from the tab Fase 7 retired, as a sheet behind its own map button rather than a section
/// of the search sheet — Fase 12 took it out of there as noise. Picking a stop does not open a
/// screen of its own: it hands the stop to the map, whose place card is already the stop screen.
struct NearbyStopsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let onPick: (Stop) -> Void

    @State private var stops: [NearbyStop]?
    @State private var radius: Double = 500

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Paradas cercanas")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Menu {
                            Picker("Radio", selection: $radius) {
                                Text("300 m").tag(300.0)
                                Text("500 m").tag(500.0)
                                Text("800 m").tag(800.0)
                                Text("1,5 km").tag(1500.0)
                            }
                        } label: {
                            Label("Radio", systemImage: "slider.horizontal.3")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Cerrar") { dismiss() }
                    }
                }
        }
        // Keyed on a coordinate rounded to ~11 m, the same rounding the search sheet used, so
        // GPS jitter at a standstill does not re-run the query.
        .task(id: QueryKey(coordinate: environment.location.coordinate, radius: radius)) {
            await load()
        }
        .task(id: environment.feedStatus.importedAt) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if environment.location.isDenied {
            ContentUnavailableView {
                Label("Ubicación desactivada", systemImage: "location.slash")
            } description: {
                Text("Actívala en Ajustes para ver las paradas cercanas. También puedes buscar una parada por su número en el buscador.")
            }
        } else if environment.location.coordinate == nil {
            ContentUnavailableView {
                Label("Buscando tu posición…", systemImage: "location")
            }
        } else if let stops, stops.isEmpty {
            ContentUnavailableView {
                Label("Sin paradas cerca", systemImage: "mappin.slash")
            } description: {
                Text(environment.hasData
                     ? "No hay paradas a menos de \(radiusText). Prueba con un radio mayor."
                     : "Todavía no se han importado los horarios.")
            }
        } else if let stops {
            List(stops) { nearby in
                Button {
                    onPick(nearby.stop)
                    dismiss()
                } label: {
                    row(nearby)
                }
                .foregroundStyle(.primary)
                .favouriteActions(for: nearby.stop)
            }
            .listStyle(.plain)
        } else {
            ProgressView()
        }
    }

    private func row(_ nearby: NearbyStop) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(nearby.stop.name).font(.subheadline).lineLimit(2)
                if let code = nearby.stop.vitrasaCode {
                    Text("Parada \(code.value)").font(.caption2).foregroundStyle(.secondary)
                }
                if nearby.routeShortNames.isEmpty {
                    Text("Sin líneas en el horario vigente")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(nearby.routeShortNames, id: \.self) { LineBadge(name: $0) }
                        }
                    }
                    .scrollClipDisabled()
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(distanceText(nearby.distanceMetres))
                    .font(.subheadline.weight(.medium).monospacedDigit())
                // Straight-line, and labelled as such, like every other distance in the app.
                Text("en línea recta").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var radiusText: String {
        radius < 1000 ? "\(Int(radius)) m" : String(format: "%.1f km", radius / 1000)
    }

    private func distanceText(_ metres: Double) -> String {
        metres < 1000 ? "\(Int(metres.rounded())) m"
                      : String(format: "%.1f km", metres / 1000)
    }

    private func load() async {
        guard let coordinate = environment.location.coordinate else { return }
        let repository = environment.repository
        let radius = self.radius
        // Off the main actor, like every other SQLite read in the app.
        stops = await Task.detached(priority: .userInitiated) {
            (try? repository.nearbyStops(latitude: coordinate.latitude,
                                         longitude: coordinate.longitude,
                                         radiusMetres: radius)) ?? []
        }.value
    }

    private struct QueryKey: Equatable {
        let latitude: Int?
        let longitude: Int?
        let radius: Double

        init(coordinate: CLLocationCoordinate2D?, radius: Double) {
            latitude = coordinate.map { Int(($0.latitude * 10_000).rounded()) }
            longitude = coordinate.map { Int(($0.longitude * 10_000).rounded()) }
            self.radius = radius
        }
    }
}
