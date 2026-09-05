import SwiftUI
import VigoCore

/// Search, inside the map.
///
/// The same four sources `PlacePickerView` covers — stops, addresses, saved places and
/// favourites — plus saved journeys, and with the same rules, because those rules were
/// argued once already and have not changed: the stop search runs on every keystroke
/// (0,2 ms against SQLite over 1149 rows) while the address search waits 300 ms and is fixed
/// to a Vigo box that never carries the user's position.
///
/// What differs is the outcome. The planner's picker had to *return an endpoint* to a form.
/// Here a result is a place on the map, so picking one opens its card — the same card a tap
/// on the map opens — and the route is one more tap from there. That is the Apple Maps shape,
/// and it is what lets the same sheet serve both "find me somewhere" and "replace this end
/// of the route".
struct MapSearchSheet: View {
    /// What picking a result is *for*, which is the only thing that changes behaviour here.
    enum Purpose: Equatable {
        /// Opened from the map's own search bar. A saved journey is planned whole.
        case explore
        /// Opened to replace one end of a route. A saved journey contributes just that end,
        /// and offering to plan it whole would throw away the route being edited.
        case endpoint(PlacePickerRole)
    }

    @Environment(AppEnvironment.self) private var environment

    let purpose: Purpose
    let onPick: (MapPlace) -> Void
    let onPickJourney: (SavedJourney) -> Void
    /// Whoever presented this sheet decides what closing means.
    ///
    /// It cannot decide for itself: presented from the map it is one face of a sheet that
    /// stays up and switches to the place card, and calling `dismiss()` there would tear down
    /// the sheet the card is about to appear in — and, worse, race the selection it has just
    /// made. Presented from the route sheet it is a nested sheet that really does close.
    let onCancel: () -> Void

    @State private var query = ""
    @State private var results: [Stop] = []
    @State private var addresses: AddressSearchModel?

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    shortcuts
                } else {
                    searchResults
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Parada, dirección o lugar")
            .onChange(of: query) {
                results = query.isEmpty
                    ? []
                    : ((try? environment.repository.searchStops(query)) ?? [])
                addresses?.update(query: query)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", action: onCancel)
                }
            }
        }
        .task {
            if addresses == nil { addresses = AddressSearchModel(service: environment.addressSearch) }
        }
        .onDisappear { addresses?.cancel() }
    }

    private var title: String {
        switch purpose {
        case .explore: "Buscar"
        case .endpoint(.origin): "Origen"
        case .endpoint(.destination): "Destino"
        }
    }

    // MARK: - Con el campo vacío

    @ViewBuilder
    private var shortcuts: some View {
        if !environment.savedPlaces.journeys.isEmpty {
            Section("Trayectos guardados") {
                ForEach(environment.savedPlaces.journeys) { journey in
                    Button {
                        switch purpose {
                        case .explore:
                            onPickJourney(journey)
                        case .endpoint(let role):
                            let ends = journey.mapEnds
                            onPick(role == .origin ? ends.origin : ends.destination)
                        }
                    } label: {
                        Label(journey.displayLabel,
                              systemImage: "arrow.triangle.turn.up.right.diamond")
                    }
                }
            }
        }

        if !environment.savedPlaces.places.isEmpty {
            Section("Lugares guardados") {
                ForEach(environment.savedPlaces.places) { place in
                    Button {
                        pick(MapPlace(place: place.place, subtitle: place.anchor.resolvedStop?.name,
                                      origin: .savedPlace(place.id)))
                    } label: {
                        Label(place.name, systemImage: place.symbolName)
                    }
                }
            }
        }

        if !environment.favourites.stops.isEmpty {
            Section("Paradas favoritas") {
                ForEach(environment.favourites.stops) { stop in stopRow(stop) }
            }
        }

        if environment.savedPlaces.journeys.isEmpty,
           environment.savedPlaces.places.isEmpty,
           environment.favourites.stops.isEmpty {
            Text("Busca una parada por nombre o número, o una dirección de Vigo.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Resultados

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

        if results.isEmpty, addresses?.suggestions.isEmpty ?? true, addresses?.isSearching != true {
            ContentUnavailableView.search(text: query)
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
        .favouriteActions(for: stop)
    }

    private func addressRow(_ suggestion: AddressSuggestion,
                            addresses: AddressSearchModel) -> some View {
        Button {
            Task {
                guard let place = await addresses.resolve(suggestion) else { return }
                pick(MapPlace(place: place, subtitle: suggestion.subtitle.isEmpty
                              ? nil : suggestion.subtitle, origin: .address))
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

    private func pick(_ place: MapPlace) {
        onPick(place)
    }
}

/// The map's own search affordance, floating above the tab bar.
///
/// Not a sheet, deliberately. A permanently presented sheet — the Apple Maps shape — would
/// cover the tab bar for as long as the map tab is open, and the other four tabs have to stay
/// reachable while they exist. When "Planificar" goes away this can be promoted to that
/// permanent sheet, and the change is this one view.
struct MapBrowseBar: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("Buscar parada, dirección o lugar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .accessibilityLabel("Buscar en el mapa")
    }
}
