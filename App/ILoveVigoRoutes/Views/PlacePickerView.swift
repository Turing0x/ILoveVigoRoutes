import SwiftUI
import VigoCore

/// What the picker hands back: the place, and whether it came from the GPS.
///
/// `Place` cannot carry that distinction — "Mi ubicación", a resolved address and a tap on
/// the map are all `.coordinate`, told apart only by a label — and the planner needs it: an
/// origin that came from the GPS keeps following it, one the user chose does not.
struct PickedPlace {
    /// The label every GPS-derived place carries, shared so the planner's automatic origin
    /// and this picker's own button produce the exact same `Place` value.
    static let currentLocationLabel = "Mi ubicación"

    let place: Place
    let isCurrentLocation: Bool

    static func currentLocation(_ coordinate: Coordinate) -> PickedPlace {
        PickedPlace(place: .coordinate(coordinate, label: currentLocationLabel),
                    isCurrentLocation: true)
    }
}

/// Picks an origin or a destination: current location, a favourite, a search result, or a
/// point tapped on the map — the four kinds of `Place` the handoff asks for.
struct PlacePickerView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var location = LocationProvider()
    @State private var query = ""
    @State private var results: [Stop] = []
    @State private var favourites: [Stop] = []
    @State private var addresses: AddressSearchModel?
    @State private var showingMapPicker = false

    let title: String
    let onPick: (PickedPlace) -> Void

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
                } else {
                    searchResults
                }

                if !query.isEmpty,
                   results.isEmpty,
                   addresses?.suggestions.isEmpty ?? true,
                   addresses?.isSearching != true {
                    ContentUnavailableView.search(text: query)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // Dos búsquedas comparten este campo y no se parecen. La de paradas va directa a
            // SQLite en cada pulsación — 0,2 ms sobre la tabla real de 1149 paradas — así que
            // ahí no hay nada que debounce. La de direcciones es una ida y vuelta a Apple, así
            // que espera 300 ms tras la última tecla; ver `AddressSearchModel`.
            .searchable(text: $query, prompt: "Parada, dirección o lugar")
            .onChange(of: query) {
                runSearch()
                addresses?.update(query: query)
            }
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
            if addresses == nil { addresses = AddressSearchModel(service: environment.addressSearch) }
        }
        .onDisappear {
            location.stop()
            addresses?.cancel()
        }
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

    @ViewBuilder
    private var searchResults: some View {
        if !results.isEmpty {
            Section("Paradas") {
                ForEach(results) { stop in stopRow(stop) }
            }
        }

        Section {
            if addresses?.isSearching == true, addresses?.suggestions.isEmpty ?? true {
                HStack {
                    ProgressView()
                    Text("Buscando direcciones…")
                }
            }

            if let addresses {
                ForEach(addresses.suggestions) { suggestion in
                    addressRow(suggestion, addresses: addresses)
                }

                if addresses.failed {
                    Text(addresses.failure == .outsideCoverage
                         ? "Esa dirección queda fuera de la zona que cubre el feed."
                         : "No he podido buscar direcciones ahora mismo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Direcciones")
        } footer: {
            Text("Las direcciones las busca Apple Mapas. Tu ubicación no se envía: la búsqueda siempre se centra en Vigo.")
        }
    }

    private func addressRow(_ suggestion: AddressSuggestion, addresses: AddressSearchModel) -> some View {
        Button {
            Task {
                if let place = await addresses.resolve(suggestion) { pick(place) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.title).font(.subheadline).lineLimit(2)
                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if addresses.resolving == suggestion.id { ProgressView() }
            }
        }
        .buttonStyle(.plain)
        .disabled(addresses.resolving != nil)
    }

    private func pickCurrentLocation() {
        guard let coordinate = location.coordinate else { return }
        pick(PickedPlace.currentLocation(
            Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)).place,
             isCurrentLocation: true)
    }

    private func pick(_ place: Place, isCurrentLocation: Bool = false) {
        onPick(PickedPlace(place: place, isCurrentLocation: isCurrentLocation))
        dismiss()
    }

    private func runSearch() {
        results = query.isEmpty ? [] : ((try? environment.repository.searchStops(query)) ?? [])
    }
}
