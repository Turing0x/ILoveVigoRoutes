import SwiftUI
import CoreLocation
import VigoCore

/// Search, inside the map.
///
/// The one buscador of the app: stops, addresses, saved places, saved journeys and
/// favourites, plus the current position and a point dropped on the map — all through
/// `Purpose`, which is the only thing that changes behaviour here. The stop search runs on
/// every keystroke (0,3 ms against SQLite over 1149 rows, off the main actor) while the
/// address search waits 300 ms and is fixed to a Vigo box that never carries the user's
/// position.
///
/// A picked result is a place on the map, so `.explore` opens its card — the same card a tap
/// on the map opens — and the route is one more tap from there. That is the Apple Maps shape.
/// `.endpoint` and `.standalone` hand the place straight back instead, for a route's end or
/// a saved place's anchor.
///
/// Which sections show, in what order, and what to say when one is empty is decided by
/// `SearchLayoutBuilder` in `VigoCore` — a pure function this view only reads, so that
/// decision runs under `swift test` instead of only being checkable in the simulator.
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
    /// Resolves a coordinate to a street name. Injectable so a test could stub it; the app
    /// always uses the real geocoder — the same one `MapScreenModel` uses for a long press,
    /// so "Elegir en el mapa" (H-33) stops being the one drop-a-pin path that never names
    /// the point it drops.
    var resolver: any MapPlaceResolving = MapKitPlaceResolver()

    @State private var query = ""
    @State private var results: [Stop] = []
    @State private var addresses: AddressSearchModel?
    /// Only needed for the "Mi ubicación" row and the distance shown nowhere else in this
    /// sheet — a second `CLLocationManager` alongside the map's own while this is presented
    /// over it, same as `PlacePickerView` used to run alongside `MapScreen`.
    @State private var location = LocationProvider()
    @State private var showingMapPicker = false
    @State private var resolvingDroppedPin = false
    @State private var savingPlaceFrom: Place?
    @State private var nearby: [NearbyStop] = []
    @State private var lines: [Route] = []
    /// "Líneas con servicio" starts collapsed to 8 rows (H-24): the section listed all 45,
    /// none of them tappable, and dwarfed every other section in an otherwise empty sheet.
    @State private var showingAllLines = false

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
        // Off the main actor, like `lines`/`nearby` above: at 1154 real stops this query is
        // sub-millisecond, but it was still running synchronously in `.onChange` before,
        // blocking the next `body` redraw on every keystroke for no reason the other two
        // queries on this same screen don't already avoid. `.task(id:)` also cancels a
        // superseded keystroke's query on its own, which `.onChange` never did.
        .task(id: query) {
            addresses?.update(query: query)
            guard !query.isEmpty else { results = []; return }
            let repository = environment.repository
            let q = query
            results = await Task.detached(priority: .userInitiated) {
                (try? repository.searchStops(q)) ?? []
            }.value
        }
        .onDisappear {
            addresses?.cancel()
            location.stop()
        }
        .sheet(isPresented: $showingMapPicker) {
            MapPointPickerView { coordinate in
                let point = Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
                resolvingDroppedPin = true
                Task {
                    let resolved = await resolver.resolve(coordinate: point)
                    resolvingDroppedPin = false
                    pick(.droppedPin(point, name: resolved.name, subtitle: resolved.subtitle))
                }
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
        .overlay {
            if resolvingDroppedPin {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
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
        let layout = SearchLayoutBuilder.shortcuts(
            showsSavedJourneys: showsSavedJourneys,
            hasData: environment.hasData,
            savedJourneys: environment.savedPlaces.journeys.count,
            savedPlaces: environment.savedPlaces.places.count,
            favourites: environment.favourites.stops.count,
            nearby: nearby.count,
            lines: lines.count)

        if layout.sections.contains(.savedJourneys) {
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

        if layout.sections.contains(.savedPlaces) {
            Section("Lugares guardados") {
                ForEach(environment.savedPlaces.places) { place in
                    Button {
                        pick(.savedPlace(place))
                    } label: {
                        Label(place.name, systemImage: place.symbolName)
                    }
                }
            }
        }

        if layout.sections.contains(.favourites) {
            Section("Paradas favoritas") {
                ForEach(environment.favourites.stops) { stop in stopRow(stop) }
            }
        }

        if layout.sections.contains(.nearby) {
            Section("Cerca de ti") {
                ForEach(nearby) { nearbyRow($0) }
            }
        } else if environment.hasData, location.isDenied {
            // H-29: an empty section that says nothing looks identical to "nobody is
            // nearby" — the two have very different fixes.
            Section("Cerca de ti") {
                Text("El permiso de ubicación está desactivado, así que no se pueden mostrar las paradas cercanas. Actívalo en Ajustes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        if layout.sections.contains(.lines) {
            linesSection
        }

        switch layout.emptyState {
        case .noFeed: noFeedMessage
        case .gettingStarted: gettingStartedMessage
        case .none, .queryTooShortForAddresses, .noResults: EmptyView()
        }
    }

    @ViewBuilder
    private var linesSection: some View {
        Section("Líneas con servicio") {
            ForEach(showingAllLines ? lines : Array(lines.prefix(8))) { lineRow($0) }
            if !showingAllLines, lines.count > 8 {
                Button("Ver todas (\(lines.count))") { showingAllLines = true }
            }
        }
    }

    private var gettingStartedMessage: some View {
        Text("Busca una parada por nombre o número, o una dirección de Vigo.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var noFeedMessage: some View {
        ContentUnavailableView {
            Label("Sin datos del feed", systemImage: "tray")
        } description: {
            Text("Todavía no se ha importado ningún horario de Vitrasa. Actualiza desde Ajustes.")
        }
    }

    // MARK: - Resultados

    @ViewBuilder
    private var searchResults: some View {
        // Computed once per pass and reused below — this used to be a computed property
        // read twice, folding all 45 real lines' names a second time for nothing (H-26).
        let matchingLines = LineMatching.matches(query: query, in: lines)
        let addressesQueryTooShort = query.trimmingCharacters(in: .whitespacesAndNewlines).count
            < AddressSearchModel.minimumQueryLength
        let layout = SearchLayoutBuilder.results(
            hasData: environment.hasData,
            stops: results.count,
            matchingLines: matchingLines.count,
            addressesQueryTooShort: addressesQueryTooShort,
            addressesSearching: addresses?.isSearching ?? false,
            addresses: addresses?.suggestions.count ?? 0,
            addressesFailed: addresses?.failed ?? false)

        if layout.sections.contains(.stops) {
            Section("Paradas") {
                ForEach(results) { stop in stopRow(stop) }
            }
        }

        if layout.sections.contains(.matchingLines) {
            Section("Líneas") {
                ForEach(matchingLines) { lineRow($0) }
            }
        }

        if layout.sections.contains(.addresses) {
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

        switch layout.emptyState {
        case .noFeed:
            noFeedMessage
        case .noResults:
            ContentUnavailableView.search(text: query)
        case .queryTooShortForAddresses:
            // H-22: distinct from `.noResults` on purpose — the address geocoder never ran,
            // so claiming a completed search found nothing would be false.
            ContentUnavailableView {
                Label("Sin resultados por ahora", systemImage: "magnifyingglass")
            } description: {
                Text("No hay paradas ni líneas para «\(query)». Sigue escribiendo para buscar también en direcciones.")
            }
        case .none, .gettingStarted:
            EmptyView()
        }
    }

    private func stopRow(_ stop: Stop) -> some View {
        Button {
            pick(.stop(stop))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(stop.name).font(.subheadline).lineLimit(2)
                    if let code = stop.vitrasaCode {
                        Text("Parada \(code.value)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                // H-27: without this, `.buttonStyle(.plain)` sizes the tap target to the
                // text's own width, not the row's — the right two-thirds of a short stop
                // name went dead to touch.
                Spacer(minLength: 0)
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
/// cover the tab bar for as long as the map tab is open, and Favoritas has to stay reachable
/// while it exists (Fase 7 got the tab count down to two, not zero). If Favoritas is ever
/// folded into the map itself this can be promoted to that permanent sheet, and the change
/// is this one view.
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
