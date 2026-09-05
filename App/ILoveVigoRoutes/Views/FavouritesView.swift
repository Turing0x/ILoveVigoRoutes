import SwiftUI
import VigoCore

/// Loads and refreshes realtime arrivals for whatever stop list it is handed. The stop
/// list itself lives in `environment.favourites` (the single source of truth added to fix
/// the star-desync bug); this model owns only the arrivals cache and the poll loop.
@MainActor
@Observable
final class FavouritesModel {
    private let environment: AppEnvironment
    private(set) var arrivals: [StopID: StopArrivals] = [:]
    private(set) var isLoading = false

    private var refreshTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Loads arrivals for every favourite so the first screen after launch already has the
    /// answer on it. The brief's acceptance criterion is one tap or none; this is the none.
    func loadArrivals(for stops: [Stop]) async {
        guard !stops.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        await withTaskGroup(of: (StopID, StopArrivals).self) { group in
            for stop in stops {
                group.addTask { [environment] in
                    (stop.id, await environment.arrivals.arrivals(for: stop))
                }
            }
            for await (id, result) in group { arrivals[id] = result }
        }
    }

    func startAutoRefresh(for stops: [Stop]) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.loadArrivals(for: stops)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await self.loadArrivals(for: stops)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func forceRefresh(for stops: [Stop]) async {
        for stop in stops { await environment.invalidateRealtime(stop.vitrasaCode) }
        await loadArrivals(for: stops)
    }
}

struct FavouritesView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: FavouritesModel?
    @State private var showingDataSources = false
    @State private var creatingPlace = false
    @State private var creatingJourney = false
    @State private var editingPlace: SavedPlace?
    @State private var editingJourney: SavedJourney?

    private var isEmpty: Bool {
        environment.savedPlaces.journeys.isEmpty && environment.savedPlaces.places.isEmpty
            && environment.favourites.stops.isEmpty && environment.favourites.unresolvedIDs.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Favoritas")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button { creatingPlace = true } label: {
                            Label("Nuevo lugar", systemImage: "mappin.circle")
                        }
                        Button { creatingJourney = true } label: {
                            Label("Nuevo trayecto", systemImage: "arrow.triangle.turn.up.right.diamond")
                        }
                    } label: {
                        Label("Añadir", systemImage: "plus")
                    }
                }
                // "Fuentes" used to be its own tab; with "Planificar" taking a slot,
                // attribution moves here instead of falling into iOS's "Más" overflow menu.
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingDataSources = true
                    } label: {
                        Label("Fuentes de datos", systemImage: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $showingDataSources) {
                NavigationStack { DataSourcesView() }
            }
            .sheet(isPresented: $creatingPlace) {
                SavedPlaceEditorView(mode: .create)
            }
            .sheet(isPresented: $creatingJourney) {
                SavedJourneyEditorView(mode: .create)
            }
            .sheet(item: $editingPlace) { place in
                SavedPlaceEditorView(mode: .edit(place))
            }
            .sheet(item: $editingJourney) { journey in
                SavedJourneyEditorView(mode: .edit(journey))
            }
        }
        .task {
            if model == nil { model = FavouritesModel(environment: environment) }
            model?.startAutoRefresh(for: environment.favourites.stops)
        }
        .onChange(of: environment.favourites.stops) { _, stops in
            model?.startAutoRefresh(for: stops)
        }
        .onDisappear { model?.stopAutoRefresh() }
    }

    @ViewBuilder
    private func content(_ model: FavouritesModel) -> some View {
        if isEmpty {
            ContentUnavailableView {
                Label("Sin favoritas", systemImage: "star")
            } description: {
                Text("Marca una parada con la estrella, o añade un lugar o un trayecto con el botón +, y aparecerán aquí nada más abrir la app.")
            }
        } else {
            List {
                if environment.timetableOutOfDate {
                    StaleFeedBanner(status: environment.feedStatus, today: environment.today) {
                        Task { await environment.refreshFeed(force: true) }
                    }
                }
                journeysSection
                placesSection
                favouritesSection(model)
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.forceRefresh(for: environment.favourites.stops) }
            .toolbar { EditButton() }
        }
    }

    // MARK: - Trayectos guardados

    @ViewBuilder
    private var journeysSection: some View {
        if !environment.savedPlaces.journeys.isEmpty {
            Section("Trayectos guardados") {
                ForEach(environment.savedPlaces.journeys) { journey in
                    journeyRow(journey)
                }
                .onDelete { environment.savedPlaces.removeJourneys(atOffsets: $0) }
                .onMove { environment.savedPlaces.moveJourneys(fromOffsets: $0, toOffset: $1) }
            }
        }
    }

    private func journeyRow(_ journey: SavedJourney) -> some View {
        Button {
            // Planning happens in exactly one place now. Tapping here is a request, not an
            // action: `RootView` switches to the map and `MapScreen` runs it.
            environment.requestOnMap(journey)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond")
                    .foregroundStyle(.indigo)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(journey.displayLabel).foregroundStyle(.primary).lineLimit(1)
                    // `isDetached` alone is not a red flag — an endpoint picked "Elegir otro
                    // lugar" is detached by design and always will be. What is worth saying
                    // out loud is an anchor whose stop_id the current feed no longer has:
                    // that is the one state here we can actually verify changed.
                    if journey.origin.anchor.isOrphaned || journey.destination.anchor.isOrphaned {
                        Text("La parada guardada de un extremo ya no está en el horario vigente; se usará el punto.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "map")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                editingJourney = journey
            } label: {
                Label("Editar", systemImage: "pencil")
            }
            Button {
                environment.savedPlaces.createJourney(
                    customLabel: journey.customLabel,
                    origin: endpointInput(from: journey.origin),
                    destination: endpointInput(from: journey.destination))
            } label: {
                Label("Duplicar", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                environment.savedPlaces.deleteJourney(id: journey.id)
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
        }
    }

    // MARK: - Lugares

    @ViewBuilder
    private var placesSection: some View {
        if !environment.savedPlaces.places.isEmpty {
            Section("Lugares") {
                ForEach(environment.savedPlaces.places) { place in
                    placeRow(place)
                }
                .onDelete { environment.savedPlaces.removePlaces(atOffsets: $0) }
                .onMove { environment.savedPlaces.movePlaces(fromOffsets: $0, toOffset: $1) }
            }
        }
    }

    private func placeRow(_ place: SavedPlace) -> some View {
        Button {
            editingPlace = place
        } label: {
            HStack(spacing: 10) {
                Image(systemName: place.symbolName).foregroundStyle(.indigo).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).foregroundStyle(.primary)
                    Text(subtitle(for: place.anchor)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                editingPlace = place
            } label: {
                Label("Editar", systemImage: "pencil")
            }
            Button {
                environment.savedPlaces.createPlace(
                    name: "\(place.name) (copia)", symbolName: place.symbolName,
                    anchor: anchorInput(from: place.anchor))
            } label: {
                Label("Duplicar", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                environment.savedPlaces.deletePlace(id: place.id)
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
        }
    }

    private func subtitle(for anchor: SavedPlaceAnchor) -> String {
        switch anchor {
        case .stop(let stop):
            if let code = stop.vitrasaCode { return "\(stop.name) · Parada \(code.value)" }
            return stop.name
        case .orphanedStop:
            return "La parada guardada ya no está en el horario vigente; se usará el punto."
        case .coordinate:
            return "Punto en el mapa"
        }
    }

    // MARK: - Paradas favoritas

    /// No "Duplicar" here, unlike the two sections above: favouriting is a boolean per
    /// stop, so there is nothing a duplicate would mean.
    @ViewBuilder
    private func favouritesSection(_ model: FavouritesModel) -> some View {
        if !environment.favourites.stops.isEmpty || !environment.favourites.unresolvedIDs.isEmpty {
            Section("Paradas favoritas") {
                ForEach(environment.favourites.stops) { stop in
                    FavouriteStopCard(stop: stop, result: model.arrivals[stop.id])
                }
                .onDelete { environment.favourites.remove(atOffsets: $0) }
                .onMove { environment.favourites.move(fromOffsets: $0, toOffset: $1) }

                ForEach(environment.favourites.unresolvedIDs, id: \.self) { id in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("Una parada favorita ya no está en el horario vigente.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Quitar") { environment.favourites.forget(id) }
                            .font(.caption2)
                    }
                }
            }
        }
    }

    // MARK: - Anchor/endpoint conversion for "Duplicar"

    private func anchorInput(from anchor: SavedPlaceAnchor) -> SavedPlaceAnchorInput {
        switch anchor {
        case .stop(let stop): .stop(stop)
        case .orphanedStop(let id, let fallback): .stopID(id, fallback: fallback)
        case .coordinate(let coordinate): .coordinate(coordinate)
        }
    }

    private func endpointInput(from endpoint: SavedEndpoint) -> SavedEndpointInput {
        SavedEndpointInput(placeID: endpoint.placeID, name: endpoint.name,
                           symbolName: endpoint.symbolName, anchor: anchorInput(from: endpoint.anchor))
    }
}

/// A favourite stop with its next departures inline — the zero-tap path.
struct FavouriteStopCard: View {
    @Environment(AppEnvironment.self) private var environment
    let stop: Stop
    let result: StopArrivals?

    var body: some View {
        NavigationLink {
            StopDetailView(stop: stop, environment: environment)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(stop.name).font(.headline).lineLimit(2)
                if let result {
                    switch result.source {
                    case .realtime:
                        if result.arrivals.isEmpty {
                            fallbackRows(result.scheduled, note: "Sin pasos previstos ahora mismo.")
                        } else {
                            ForEach(result.arrivals.prefix(3)) { CompactArrivalRow(arrival: $0) }
                        }
                    case .cache(let at, let failure):
                        Text(failure)
                            .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                        ForEach(result.arrivals.prefix(3)) {
                            CompactArrivalRow(arrival: $0,
                                              overrideKind: .cached(age: Date().timeIntervalSince(at)))
                        }
                    case .unavailable(let failure):
                        Text(failure)
                            .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                        fallbackRows(result.scheduled, note: nil)
                    }
                } else {
                    HStack { ProgressView().controlSize(.mini); Text("Consultando…").font(.caption) }
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func fallbackRows(_ scheduled: [ScheduledDeparture], note: String?) -> some View {
        if let note {
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }
        if scheduled.isEmpty {
            Text("Tampoco hay horario teórico disponible.")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            ForEach(scheduled.prefix(3)) { CompactScheduledRow(departure: $0) }
        }
    }
}

struct CompactArrivalRow: View {
    let arrival: Arrival
    var overrideKind: DataKind?

    private var kind: DataKind {
        overrideKind ?? (arrival.confidence.hasTrackedVehicle ? .tracked : .estimated)
    }

    var body: some View {
        HStack(spacing: 8) {
            LineBadge(name: arrival.rawLine)
            Text(arrival.destination).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            DataKindBadge(kind: kind, compact: true)
            Text(WaitTime(minutes: arrival.minutes).compactText)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(kind.tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Línea \(arrival.rawLine), \(WaitTime(minutes: arrival.minutes).spoken), \(kind.label)"))
    }
}

struct CompactScheduledRow: View {
    let departure: ScheduledDeparture

    var body: some View {
        HStack(spacing: 8) {
            LineBadge(name: departure.routeShortName)
            Text(departure.destination).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            DataKindBadge(kind: .timetable, compact: true)
            Text(departure.departure.clockDescription)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.blue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("""
            Línea \(departure.routeShortName), horario teórico \(departure.departure.clockDescription)
            """))
    }
}
