import SwiftUI
import VigoCore

@MainActor
@Observable
final class FavouritesModel {
    private let environment: AppEnvironment
    private(set) var stops: [Stop] = []
    private(set) var arrivals: [StopID: StopArrivals] = [:]
    private(set) var isLoading = false

    private var refreshTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
        reloadStops()
    }

    func reloadStops() {
        stops = (try? environment.repository.favouriteStops()) ?? []
    }

    /// Loads arrivals for every favourite so the first screen after launch already has the
    /// answer on it. The brief's acceptance criterion is one tap or none; this is the none.
    func loadArrivals() async {
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

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.loadArrivals()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await self.loadArrivals()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func forceRefresh() async {
        for stop in stops { await environment.invalidateRealtime(stop.vitrasaCode) }
        await loadArrivals()
    }

    func remove(_ offsets: IndexSet) {
        for index in offsets {
            try? environment.repository.setFavourite(stops[index].id, false)
        }
        reloadStops()
    }

    func move(_ source: IndexSet, _ destination: Int) {
        var ordered = stops
        ordered.move(fromOffsets: source, toOffset: destination)
        try? environment.repository.reorderFavourites(ordered.map(\.id))
        stops = ordered
    }
}

struct FavouritesView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: FavouritesModel?

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
        }
        .task {
            if model == nil { model = FavouritesModel(environment: environment) }
            model?.reloadStops()
            model?.startAutoRefresh()
        }
        .onDisappear { model?.stopAutoRefresh() }
    }

    @ViewBuilder
    private func content(_ model: FavouritesModel) -> some View {
        if model.stops.isEmpty {
            ContentUnavailableView {
                Label("Sin favoritas", systemImage: "star")
            } description: {
                Text("Marca una parada con la estrella y sus próximos pasos aparecerán aquí nada más abrir la app.")
            }
        } else {
            List {
                if environment.timetableOutOfDate {
                    StaleFeedBanner(status: environment.feedStatus, today: environment.today) {
                        Task { await environment.refreshFeed(force: true) }
                    }
                }
                ForEach(model.stops) { stop in
                    Section {
                        FavouriteStopCard(stop: stop, result: model.arrivals[stop.id])
                    }
                }
                .onDelete { model.remove($0) }
                .onMove { model.move($0, $1) }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.forceRefresh() }
            .toolbar { EditButton() }
        }
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
