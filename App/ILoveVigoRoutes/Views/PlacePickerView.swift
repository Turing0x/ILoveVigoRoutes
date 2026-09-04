import SwiftUI
import VigoCore

/// Picks an origin or a destination: current location, a favourite, a search result, or a
/// point tapped on the map — the four kinds of `Place` the handoff asks for.
struct PlacePickerView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var location = LocationProvider()
    @State private var query = ""
    @State private var results: [Stop] = []
    @State private var favourites: [Stop] = []
    @State private var showingMapPicker = false

    let title: String
    let onPick: (Place) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        pickCurrentLocation()
                    } label: {
                        Label("Mi ubicación", systemImage: "location.fill")
                    }
                    .disabled(location.coordinate == nil)

                    Button {
                        showingMapPicker = true
                    } label: {
                        Label("Elegir en el mapa", systemImage: "mappin.and.ellipse")
                    }
                }

                if query.isEmpty, !favourites.isEmpty {
                    Section("Favoritas") {
                        ForEach(favourites) { stop in stopRow(stop) }
                    }
                }

                if query.isEmpty {
                    if favourites.isEmpty {
                        Text("Busca una parada por nombre o número, o elige una de las opciones de arriba.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    Section("Resultados") {
                        ForEach(results) { stop in stopRow(stop) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // Searching runs straight against SQLite on each keystroke; measured at
            // 0.2 ms over the real 1149-stop table (SearchView), so there is nothing to
            // debounce here either.
            .searchable(text: $query, prompt: "Nombre de la parada o su número")
            .onChange(of: query) { runSearch() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .task {
            location.requestPermissionIfNeeded()
            location.start()
            favourites = (try? environment.repository.favouriteStops()) ?? []
        }
        .onDisappear { location.stop() }
        .sheet(isPresented: $showingMapPicker) {
            MapPointPickerView { coordinate in
                pick(.coordinate(Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude),
                                 label: "Punto en el mapa"))
            }
        }
    }

    private func stopRow(_ stop: Stop) -> some View {
        Button {
            pick(.stop(stop))
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(stop.name).font(.subheadline).lineLimit(2)
                if let code = stop.vitrasaCode {
                    Text("Parada \(code.value)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func pickCurrentLocation() {
        guard let coordinate = location.coordinate else { return }
        pick(.coordinate(Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude),
                         label: "Mi ubicación"))
    }

    private func pick(_ place: Place) {
        onPick(place)
        dismiss()
    }

    private func runSearch() {
        results = query.isEmpty ? [] : ((try? environment.repository.searchStops(query)) ?? [])
    }
}
