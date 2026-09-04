import SwiftUI
import CoreLocation
import VigoCore

struct NearbyView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var location = LocationProvider()
    @State private var stops: [NearbyStop] = []
    @State private var radius: Double = 800
    @State private var lastQueried: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            Group {
                if location.isDenied {
                    ContentUnavailableView {
                        Label("Ubicación desactivada", systemImage: "location.slash")
                    } description: {
                        Text("Actívala en Ajustes para ver las paradas cercanas. También puedes buscar una parada por nombre o número.")
                    }
                } else if !location.isAuthorized {
                    ContentUnavailableView {
                        Label("Paradas cercanas", systemImage: "location")
                    } description: {
                        Text("Necesito tu ubicación para ordenar las paradas por distancia. No sale del dispositivo.")
                    } actions: {
                        Button("Permitir ubicación") { location.requestPermissionIfNeeded() }
                            .buttonStyle(.borderedProminent)
                    }
                } else if stops.isEmpty {
                    ContentUnavailableView {
                        Label("Buscando paradas…", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text(environment.hasData
                             ? "No hay paradas a menos de \(Int(radius)) m."
                             : "Todavía no se han importado los datos.")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Cercanas")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
            }
        }
        .task {
            location.requestPermissionIfNeeded()
            location.start()
        }
        .onDisappear { location.stop() }
        .onChange(of: location.coordinate?.latitude) { refresh() }
        .onChange(of: radius) { refresh() }
        .onChange(of: environment.feedStatus.importedAt) { refresh() }
    }

    private var list: some View {
        List(stops) { nearby in
            NavigationLink {
                StopDetailView(stop: nearby.stop, environment: environment)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(nearby.stop.name).font(.subheadline).lineLimit(2)
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
                        // Straight-line, and labelled as such: promising walking distance
                        // without a routing engine would be a guess.
                        Text("en línea recta").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
        .refreshable { refresh() }
    }

    private func distanceText(_ metres: Double) -> String {
        metres < 1000 ? "\(Int(metres.rounded())) m"
                      : String(format: "%.1f km", metres / 1000)
    }

    private func refresh() {
        guard let coordinate = location.coordinate else { return }
        lastQueried = coordinate
        stops = (try? environment.repository.nearbyStops(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMetres: radius)) ?? []
    }
}
