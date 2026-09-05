import SwiftUI
import CoreLocation
import VigoCore

/// Search, inside the map.
///
/// The one buscador of the app: stops, addresses, saved places, saved journeys and
/// favourites, plus the current position and a point dropped on the map — all through
/// `Purpose`, which is the only thing that changes behaviour here. The stop search runs on
/// every keystroke (0,2 ms against SQLite over 1149 rows) while the address search waits
/// 300 ms and is fixed to a Vigo box that never carries the user's position.
///
/// A picked result is a place on the map, so `.explore` opens its card — the same card a tap
/// on the map opens — and the route is one more tap from there. That is the Apple Maps shape.
/// `.endpoint` and `.standalone` hand the place straight back instead, for a route's end or
/// a saved place's anchor.
struct MapSearchSheet: View {
    /// What picking a result is *for*, which is the only thing that changes behaviour here.
    enum Purpose: Equatable {
        /// Opened from the map's own search bar. A saved journey is planned whole.
        case explore
        /// Opened to replace one end of a route. A saved journey contributes just that end,
        /// and offering to plan it whole would throw away the route being edited.
        case endpoint(PlacePickerRole)
        /// Opened from one of the saved-place/saved-journey editors, to pick a single point.
        /// Carries its own title because there is no route or map card waiting for the
        /// answer — the caller decides what this pick is *for*.
        case standalone(title: String)
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
    /// Only needed for the "Mi ubicación" row and the distance shown nowhere else in this
    /// sheet — a second `CLLocationManager` alongside the map's own while this is presented
    /// over it, same as `PlacePickerView` used to run alongside `MapScreen`.
    @State private var location = LocationProvider()
    @State private var showingMapPicker = false
    @State private var savingPlaceFrom: Place?
    @State private var nearby: [NearbyStop] = []
    @State private var lines: [Route] = []

    var body: some View {
        NavigationStack {
            List {
                header
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
            location.requestPermissionIfNeeded()
            location.start()
        }
        .task {
            let repository = environment.repository
            lines = await Task.detached(priority: .userInitiated) {
                (try? repository.routesWithService()) ?? []
            }.value
        }
        .task(id: roundedCoordinate) {
            guard let coordinate = location.coordinate else { return }
            let repository = environment.repository
            nearby = await Task.detached(priority: .userInitiated) {
                (try? repository.nearbyStops(latitude: coordinate.latitude,
                                             longitude: coordinate.longitude,
                                             radiusMetres: 800, limit: 8)) ?? []
            }.value
        }
        .onDisappear {
            addresses?.cancel()
            location.stop()
        }
        .sheet(isPresented: $showingMapPicker) {
            MapPointPickerView { coordinate in
                pick(.droppedPin(Coordinate(latitude: coordinate.latitude,
                                            longitude: coordinate.longitude)))
            }
        }
        .sheet(isPresented: Binding(
            get: { savingPlaceFrom != nil },
            set: { if !$0 { savingPlaceFrom = nil } }
        )) {
            if let savingPlaceFrom {
                SavedPlaceEditorView(mode: .createFrom(savingPlaceFrom))
            }
        }
    }

    private var title: String {
        switch purpose {
        case .explore: "Buscar"
        case .endpoint(.origin): "Origen"
        case .endpoint(.destination): "Destino"
        case .standalone(let title): title
        }
    }

    // MARK: - Cabecera

    /// "Mi ubicación" only makes sense when the pick is going somewhere specific — the
    /// route's origin/destination, or a saved place's anchor. `.explore` already tracks the
    /// device on the map itself, so offering it again here would be a second, redundant
    /// answer to "where am I".
    private var showsCurrentLocation: Bool {
        switch purpose {
        case .explore: false
        case .endpoint, .standalone: true
        }
    }

    private var header: some View {
        Section {
            if showsCurrentLocation {
                Button {
                    pickCurrentLocation()
                } label: {
                    Label("Mi ubicación", systemImage: "location.fill")
                }
                .disabled(location.coordinate == nil)
            }
            // Offered in every purpose, `.explore` included: it is the accessible route to
            // "drop a pin anywhere", the one thing the map's own long-press gesture cannot
            // reach with VoiceOver.
            Button {
                showingMapPicker = true
            } label: {
                Label("Elegir en el mapa", systemImage: "mappin.and.ellipse")
            }
        }
    }

    private func pickCurrentLocation() {
        guard let coordinate = location.coordinate else { return }
        pick(.currentLocation(Coordinate(latitude: coordinate.latitude,
                                         longitude: coordinate.longitude)))
    }

    /// `location.coordinate` moves with every GPS fix; rounding to four decimals (roughly
    /// 11 m) before using it as a `.task(id:)` is what keeps "Cerca de ti" from reissuing
    /// its query on jitter alone. The task itself still reads the live coordinate, so the
    /// query is never stale — only *how often* it reruns is throttled here.
    private var roundedCoordinate: Coordinate? {
        location.coordinate.map {
            Coordinate(latitude: ($0.latitude * 1e4).rounded() / 1e4,
                      longitude: ($0.longitude * 1e4).rounded() / 1e4)
        }
    }

    // MARK: - Con el campo vacío

    /// A saved journey is either planned whole (`.explore`) or contributes one end
    /// (`.endpoint`). `.standalone` is picking a single point for something else entirely —
    /// a saved place's anchor — where neither reading makes sense, so the section that
    /// offers saved journeys does not apply.
    private var showsSavedJourneys: Bool {
        if case .standalone = purpose { return false }
        return true
    }

    @ViewBuilder
    private var shortcuts: some View {
        if showsSavedJourneys, !environment.savedPlaces.journeys.isEmpty {
            Section("Trayectos guardados") {
                ForEach(environment.savedPlaces.journeys) { journey in
                    Button {
                        switch purpose {
                        case .explore:
                            onPickJourney(journey)
                        case .endpoint(let role):
                            let ends = journey.mapEnds
                            onPick(role == .origin ? ends.origin : ends.destination)
                        case .standalone:
                            break
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

        if !nearby.isEmpty {
            Section("Cerca de ti") {
                ForEach(nearby) { nearbyRow($0) }
            }
        }

        if !lines.isEmpty {
            Section("Líneas con servicio") {
                ForEach(lines) { lineRow($0) }
            }
        }

        if (!showsSavedJourneys || environment.savedPlaces.journeys.isEmpty),
           environment.savedPlaces.places.isEmpty,
           environment.favourites.stops.isEmpty {
            Text("Busca una parada por nombre o número, o una dirección de Vigo.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Resultados

    /// Lines matching the query by short or long name — "15" now finds línea 15, not just
    /// paradas whose stop code happens to contain it.
    private var matchingLines: [Route] {
        let folded = TextNormalization.searchFolded(query)
        guard !folded.isEmpty else { return [] }
        return lines.filter {
            TextNormalization.searchFolded($0.shortName).contains(folded)
                || TextNormalization.searchFolded($0.longName).contains(folded)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if !results.isEmpty {
            Section("Paradas") {
                ForEach(results) { stop in stopRow(stop) }
            }
        }

        if !matchingLines.isEmpty {
            Section("Líneas") {
                ForEach(matchingLines) { lineRow($0) }
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

        if results.isEmpty, matchingLines.isEmpty,
           addresses?.suggestions.isEmpty ?? true, addresses?.isSearching != true {
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
        // Trailing edge, deliberately: `favouriteActions` already owns the leading one, and
        // the two never conflict since they sit on opposite sides of the row.
        .swipeActions(edge: .trailing) {
            Button {
                savingPlaceFrom = .stop(stop)
            } label: {
                Label("Guardar", systemImage: "mappin.circle")
            }
            .tint(.indigo)
        }
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
        .swipeActions(edge: .trailing) {
            Button {
                Task {
                    if let place = await addresses.resolve(suggestion) { savingPlaceFrom = place }
                }
            } label: {
                Label("Guardar", systemImage: "mappin.circle")
            }
            .tint(.indigo)
        }
    }

    private func pick(_ place: MapPlace) {
        onPick(place)
    }

    /// A stop ordered by straight-line distance — fixed 800 m radius, up to 8 results. No
    /// radio picker: that made sense as a whole screen, not as one section of a sheet.
    private func nearbyRow(_ nearby: NearbyStop) -> some View {
        Button {
            pick(.stop(nearby.stop))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(nearby.stop.name).font(.subheadline).lineLimit(2)
                    if !nearby.routeShortNames.isEmpty {
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
                        .font(.caption.weight(.medium).monospacedDigit())
                    Text("en línea recta").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .favouriteActions(for: nearby.stop)
    }

    private func distanceText(_ metres: Double) -> String {
        metres < 1000 ? "\(Int(metres.rounded())) m"
                      : String(format: "%.1f km", metres / 1000)
    }

    /// Not interactive: there is no query to filter stops by línea, so tapping one would
    /// have nowhere honest to go.
    private func lineRow(_ route: Route) -> some View {
        HStack(spacing: 10) {
            LineBadge(name: route.shortName, colorHex: route.colorHex,
                     textColorHex: route.textColorHex)
            Text(route.longName).font(.subheadline).lineLimit(2)
        }
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
