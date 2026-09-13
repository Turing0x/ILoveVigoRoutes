import SwiftUI
import VigoCore

/// The card for a selected place: what it is, how far it is, and what can be done with it.
///
/// Deliberately the same card for a bus stop, an Apple point of interest and a pressed point
/// — that sameness is the whole feature. What differs is only what a place *can* offer: live
/// arrivals and a favourite star exist for a stop and for nothing else, because they are the
/// only thing the feed knows about.
///
/// "Cómo llegar" is the primary action and sits above everything else, because it is the
/// reason this screen exists. For a stop it has a sibling, «Ir a… desde esta parada», for
/// the traveller who is already standing at it.
struct MapPlaceSheet: View {
    @Environment(AppEnvironment.self) private var environment
    let place: MapPlace
    let distanceText: String?
    /// Why routing is unavailable right now, or `nil` when it is available.
    ///
    /// A disabled button with no reason next to it is a dead end; the two states this can
    /// hold — the feed still importing, and no position with no origin pinned — are both
    /// temporary and both worth naming.
    let routeBlockedReason: String?
    let onRoute: () -> Void
    /// «Ir a… desde esta parada». Only offered for a stop.
    let onRouteFrom: () -> Void
    let onClose: () -> Void

    @State private var savingPlace: Place?
    @State private var feed: StopArrivalsFeed?
    /// The routes the timetable says serve this stop — the rows of «Líneas en esta parada».
    @State private var routes: [Route]?
    @State private var declaringLine: StopDetailView.DeclaredLine?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }

                Section {
                    Button(action: onRoute) {
                        Label("Cómo llegar", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.headline)
                    }
                    .disabled(routeBlockedReason != nil)
                    if place.stop != nil {
                        Button(action: onRouteFrom) {
                            Label("Ir a… desde esta parada", systemImage: "figure.stand")
                        }
                        // Needs the feed, but not a position: the stop is the origin.
                        .disabled(!environment.hasData)
                    }
                } footer: {
                    if let routeBlockedReason {
                        Text(routeBlockedReason)
                    }
                }

                if let stop = place.stop {
                    linesSection(stop)
                        .task(id: stop.id) {
                            if feed == nil { feed = StopArrivalsFeed(arrivals: environment.arrivals) }
                            await feed?.run(stop: stop)
                        }
                        .task(id: stop.id) { await loadRoutes(stop) }

                    Section {
                        NavigationLink {
                            StopDetailView(stop: stop, environment: environment)
                        } label: {
                            Label("Ver horario y detalles", systemImage: "clock.arrow.circlepath")
                        }
                        Button {
                            environment.favourites.toggle(stop)
                        } label: {
                            Label(
                                environment.favourites.contains(stop.id)
                                    ? "Quitar de favoritas" : "Añadir a favoritas",
                                systemImage: environment.favourites.contains(stop.id)
                                    ? "star.slash" : "star.fill")
                        }
                    }
                }

                Section {
                    Button {
                        savingPlace = place.place
                    } label: {
                        Label("Guardar como lugar", systemImage: "mappin.circle")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(place.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar", action: onClose)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { savingPlace != nil },
            set: { if !$0 { savingPlace = nil } }
        )) {
            if let savingPlace {
                SavedPlaceEditorView(mode: .createFrom(savingPlace))
            }
        }
        .sheet(item: $declaringLine) { line in
            if let stop = place.stop {
                OnboardDeclareSheet(presetLine: line.name, presetStop: stop)
            }
        }
    }

    // MARK: - Líneas

    /// Every line at the stop with its next bus, live when the source has one and from the
    /// timetable otherwise — each row saying which. Tapping a line opens its day at this post.
    @ViewBuilder
    private func linesSection(_ stop: Stop) -> some View {
        let result = feed?.result
        Section {
            if let result, let routes {
                if let failure = result.source.failureText {
                    Text(failure)
                        .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
                let lines = StopLines.build(routes: routes, arrivals: result.arrivals,
                                            fetchedAt: result.source.fetchedAt,
                                            scheduled: result.scheduled, now: Date())
                if lines.isEmpty {
                    Text("El horario no tiene ninguna línea en esta parada.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(lines) { line in
                    if let route = line.route {
                        NavigationLink {
                            LineTimetableView(stop: stop, routeID: route.id,
                                              routeShortName: route.shortName)
                        } label: {
                            StopLineRow(line: line, source: result.source)
                        }
                        .contextMenu { onboardButton(line) }
                    } else {
                        StopLineRow(line: line, source: result.source)
                            .contextMenu { onboardButton(line) }
                    }
                }
            } else {
                HStack { ProgressView().controlSize(.mini); Text("Consultando…").font(.caption) }
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Líneas en esta parada")
        } footer: {
            if result != nil {
                Text("Toca una línea para ver todos sus pasos de hoy por aquí. Se actualiza cada 30 s.")
            }
        }
    }

    private func onboardButton(_ line: StopLines.Line) -> some View {
        Button("Estoy en este bus", systemImage: "bus.fill") {
            declaringLine = StopDetailView.DeclaredLine(name: line.live.first?.arrival.rawLine ?? line.name)
        }
    }

    private func loadRoutes(_ stop: Stop) async {
        let repository = environment.repository
        let stopID = stop.id
        routes = await Task.detached(priority: .userInitiated) {
            (try? repository.routes(stopID: stopID)) ?? []
        }.value
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: place.symbolName)
                .font(.title2)
                .foregroundStyle(.indigo)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(place.label).font(.headline).lineLimit(2)
                if let code = place.stop?.vitrasaCode {
                    Text("Parada \(code.value)").font(.caption).foregroundStyle(.secondary)
                }
                if let subtitle = place.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if let distanceText {
                    // "En línea recta" is not padding: this app has no street graph, and
                    // every other distance it shows carries the same caveat.
                    Text("A \(distanceText) en línea recta")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One line at a stop: badge, where the next one goes, and when — with where that time came from.
struct StopLineRow: View {
    let line: StopLines.Line
    let source: ArrivalsSource

    private var kind: DataKind? {
        switch line.next {
        case .live(let arrival, _):
            if case .cache(let at, _) = source { return .cached(age: Date().timeIntervalSince(at)) }
            return arrival.confidence.hasTrackedVehicle ? .tracked : .estimated
        case .scheduled: return .timetable
        case nil: return nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            LineBadge(name: line.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.next?.destination ?? "Sin más pasos hoy")
                    .font(.caption).lineLimit(1).foregroundStyle(.secondary)
                if line.live.count > 1 {
                    Text("Después: \(line.live.dropFirst().map { WaitTime(minutes: $0.minutes).compactText }.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if case .live = line.next, let scheduled = line.nextScheduled {
                    Text("Horario: \(scheduled.departure.clockDescription)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 2)
            if let next = line.next, let kind {
                DataKindBadge(kind: kind, compact: true)
                Text(WaitTime(minutes: next.minutes).compactText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(kind.tint)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        guard let next = line.next, let kind else { return "Línea \(line.name), sin más pasos hoy" }
        return "Línea \(line.name) a \(next.destination), \(WaitTime(minutes: next.minutes).spoken), \(kind.label)"
    }
}

extension ArrivalsSource {
    /// When the arrivals being shown were produced, for discounting their minutes.
    var fetchedAt: Date? {
        switch self {
        case .realtime(let at), .cache(let at, _): at
        case .unavailable: nil
        }
    }

    /// Why the live source is not live right now, or `nil` when it is.
    var failureText: String? {
        switch self {
        case .realtime: nil
        case .cache(_, let failure), .unavailable(let failure): failure
        }
    }
}
