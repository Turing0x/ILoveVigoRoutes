import SwiftUI
import VigoCore

@MainActor
@Observable
final class StopDetailModel {
    let stop: Stop
    private let environment: AppEnvironment

    private(set) var result: StopArrivals?
    private(set) var isLoading = false
    private(set) var lastAttempt: Date?
    /// Lines serving this stop according to the timetable, used to show what is missing
    /// from a realtime answer rather than silently dropping it.
    private(set) var timetableLines: [String] = []

    private var refreshTask: Task<Void, Never>?

    /// The brief asks for a 30 s refresh while the screen is visible, and nothing at all
    /// when it is not.
    private let refreshInterval: Duration = .seconds(30)

    init(stop: Stop, environment: AppEnvironment) {
        self.stop = stop
        self.environment = environment
        self.timetableLines = (try? environment.repository.routeShortNames(stopID: stop.id)) ?? []
    }

    func load(forceNetwork: Bool = false) async {
        isLoading = true
        defer { isLoading = false; lastAttempt = Date() }
        if forceNetwork { await environment.invalidateRealtime(stop.vitrasaCode) }
        result = await environment.arrivals.arrivals(for: stop)
    }

    /// Polls only while the view is on screen. Realtime arrivals are never polled in the
    /// background — only the GTFS feed is, via `BackgroundRefresh`; these unofficial
    /// endpoints stay cold-start/foreground-only by design.
    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: self.refreshInterval)
                guard !Task.isCancelled else { break }
                await self.load()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Timetable departures for lines the realtime answer did not mention.
    ///
    /// Realtime returns at most a handful of entries, so a line that runs in two hours
    /// simply is not in it. Showing those from the timetable — labelled — is more useful
    /// than pretending they do not exist.
    var timetableOnlyDepartures: [ScheduledDeparture] {
        guard let result else { return [] }
        let live = Set(result.arrivals.map(\.normalizedLine))
        return result.scheduled.filter {
            !live.contains(TextNormalization.normalizedLineName($0.routeShortName))
        }
    }
}

struct StopDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: StopDetailModel
    /// The line the traveller says they are on, while the declaration sheet is up.
    ///
    /// A wrapper rather than a bare `String?` because `sheet(item:)` needs `Identifiable`, and
    /// a line name is not one — two arrivals of the same line share it.
    @State private var declaringLine: DeclaredLine?

    struct DeclaredLine: Identifiable {
        let name: String
        var id: String { name }
    }

    init(stop: Stop, environment: AppEnvironment) {
        _model = State(initialValue: StopDetailModel(stop: stop, environment: environment))
    }

    var body: some View {
        List {
            header

            if environment.timetableOutOfDate {
                Section {
                    StaleFeedBanner(status: environment.feedStatus, today: environment.today) {
                        Task { await environment.refreshFeed(force: true) }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            }

            realtimeSection
            timetableSection
            provenanceFooter
        }
        .listStyle(.insetGrouped)
        .navigationTitle(model.stop.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FavouriteStarButton(stop: model.stop)
            }
        }
        .refreshable { await model.load(forceNetwork: true) }
        .task { model.startAutoRefresh() }
        .onDisappear { model.stopAutoRefresh() }
        .sheet(item: $declaringLine) { line in
            OnboardDeclareSheet(presetLine: line.name, presetStop: model.stop)
        }
    }

    // MARK: - Sections

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(model.stop.gtfsStopCode)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    if let code = model.stop.vitrasaCode {
                        Text("Parada \(code.value)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.stop.wheelchairBoarding == 1 {
                        Image(systemName: "figure.roll")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Accesible")
                    }
                }
                if !model.timetableLines.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.timetableLines, id: \.self) { LineBadge(name: $0) }
                        }
                    }
                    .scrollClipDisabled()
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var realtimeSection: some View {
        Section {
            if let result = model.result {
                switch result.source {
                case .realtime(let fetchedAt):
                    if result.arrivals.isEmpty {
                        ContentUnavailableView(
                            "Sin autobuses previstos",
                            systemImage: "moon.zzz",
                            description: Text("La fuente respondió, pero no hay ningún paso previsto ahora mismo."))
                    } else {
                        ForEach(result.arrivals) { arrival in
                            ArrivalRow(arrival: arrival, fetchedAt: fetchedAt)
                                .contextMenu { onboardButton(for: arrival) }
                        }
                    }

                case .cache(let fetchedAt, let failure):
                    RealtimeFailureBanner(reason: failure)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    ForEach(result.arrivals) { arrival in
                        ArrivalRow(arrival: arrival,
                                   overrideKind: .cached(age: Date().timeIntervalSince(fetchedAt)),
                                   fetchedAt: fetchedAt)
                            .contextMenu { onboardButton(for: arrival) }
                    }

                case .unavailable(let failure):
                    RealtimeFailureBanner(reason: failure)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            } else if model.isLoading {
                HStack { ProgressView(); Text("Consultando…").foregroundStyle(.secondary) }
            }
        } header: {
            HStack {
                Text("Próximos pasos")
                Spacer()
                if model.isLoading { ProgressView().controlSize(.mini) }
            }
        } footer: {
            if let result = model.result, case .realtime(let at) = result.source {
                Text("Actualizado \(at.formatted(date: .omitted, time: .standard)). Se refresca cada 30 s mientras esta pantalla esté abierta.")
            }
        }
    }

    /// "Estoy en este bus" from an arrival row.
    ///
    /// The shortcut worth having: the line and the stop are both certain here, so the resolver
    /// never has to project a GPS fix onto a route or ask which direction this is — it only has
    /// to pick which service of that line is passing now. The sheet is the same one the map
    /// uses, seeded with what this screen already knows.
    private func onboardButton(for arrival: Arrival) -> some View {
        Button("Estoy en este bus", systemImage: "bus.fill") {
            declaringLine = DeclaredLine(name: arrival.rawLine)
        }
    }

    @ViewBuilder
    private var timetableSection: some View {
        let departures = model.result.map { result in
            result.source.isRealtime ? model.timetableOnlyDepartures : result.scheduled
        } ?? []

        if !departures.isEmpty {
            Section {
                ForEach(departures.prefix(12)) { ScheduledRow(departure: $0) }
            } header: {
                HStack {
                    Text("Horario teórico")
                    DataKindBadge(kind: .timetable, compact: true)
                }
            } footer: {
                Text("Del GTFS publicado por el Concello. No refleja retrasos ni adelantos, ni si el autobús ha salido.")
            }
        } else if model.result != nil, environment.timetableOutOfDate {
            Section {
                Text("No hay horario teórico disponible para hoy porque los datos descargados no cubren esta fecha.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Horario teórico")
            }
        }
    }

    @ViewBuilder
    private var provenanceFooter: some View {
        if let result = model.result {
            Section {
                NavigationLink {
                    DataSourcesView(feedStatus: result.feedStatus)
                } label: {
                    Label("Fuentes de los datos", systemImage: "info.circle")
                        .font(.footnote)
                }
            }
        }
    }
}

struct ArrivalRow: View {
    let arrival: Arrival
    var overrideKind: DataKind?
    /// When the source produced `arrival`; see `CompactArrivalRow.fetchedAt`.
    var fetchedAt: Date?

    private var kind: DataKind {
        if let overrideKind { return overrideKind }
        return arrival.confidence.hasTrackedVehicle ? .tracked : .estimated
    }

    private var minutes: Int {
        fetchedAt.map { arrival.minutes(at: Date(), fetchedAt: $0) } ?? arrival.minutes
    }

    var body: some View {
        HStack(spacing: 12) {
            LineBadge(name: arrival.rawLine)
            VStack(alignment: .leading, spacing: 3) {
                Text(arrival.destination)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    DataKindBadge(kind: kind, compact: true)
                    if case .vehicleTracked(let metres) = arrival.confidence {
                        Text("a \(metres) m")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 4)
            MinutesLabel(minutes: minutes, tint: kind.tint)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("""
            Línea \(arrival.rawLine) a \(arrival.destination), \
            \(WaitTime(minutes: minutes).spoken), \(kind.label)
            """))
    }
}

struct MinutesLabel: View {
    let minutes: Int
    var tint: Color = .primary

    private var wait: WaitTime { WaitTime(minutes: minutes) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(wait.badgeValue)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let unit = wait.badgeUnit {
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 40)
    }
}

struct ScheduledRow: View {
    let departure: ScheduledDeparture

    private var minutesAway: Int {
        max(0, Int(departure.absoluteDate.timeIntervalSinceNow / 60))
    }

    var body: some View {
        HStack(spacing: 12) {
            LineBadge(name: departure.routeShortName)
            VStack(alignment: .leading, spacing: 3) {
                Text(departure.destination)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    DataKindBadge(kind: .timetable, compact: true)
                    Text(departure.departure.clockDescription)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if departure.departure.rollsPastMidnight {
                        Text("madrugada")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 4)
            MinutesLabel(minutes: minutesAway, tint: .blue)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("""
            Línea \(departure.routeShortName) a \(departure.destination), \
            horario teórico \(departure.departure.clockDescription)
            """))
    }
}
