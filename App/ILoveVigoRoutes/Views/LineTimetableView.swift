import SwiftUI
import VigoCore

/// Every scheduled departure of one line from one stop, for one day.
///
/// The answer to "the bus I was told about has gone — when is the next one, and the one after
/// that". The route list answers it for the next couple of departures; this answers it for the
/// whole day, which is what somebody standing at a stop with a missed bus actually wants.
///
/// Scope on purpose: **one line, one stop, one day**, and not the line's full timetable across
/// all its stops. That is a printed timetable, not an answer. The column that resolves the
/// doubt is the one for the post the passenger is standing at.
struct LineTimetableView: View {
    @Environment(AppEnvironment.self) private var environment

    let stop: Stop
    let routeID: RouteID
    let routeShortName: String

    @State private var day: ServiceDate?
    @State private var board: DepartureBoard?
    @State private var live: StopArrivals?
    @State private var loading = true

    var body: some View {
        // Opens where the day is, not at six in the morning. A timetable read from the top is
        // a timetable the reader has to scroll through to find themselves in.
        ScrollViewReader { proxy in
            timetable
                .onChange(of: board) { _, _ in scrollToNext(proxy) }
        }
    }

    private var timetable: some View {
        List {
            liveSection

            if loading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Leyendo los horarios…").font(.subheadline)
                    }
                }
            } else if let board, !board.isEmpty {
                ForEach(board.directions) { direction in
                    directionSection(direction)
                }
            } else {
                Section {
                    Text("La línea \(routeShortName) no pasa por esta parada ese día.")
                        .font(.subheadline)
                } footer: {
                    Text("Un día sin servicio no es un fallo: hay líneas que no circulan en fin de semana o en festivo.")
                }
            }

            if let day {
                Section {
                    Text(FeedCoverageNote.text(for: day, status: environment.feedStatus))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Línea \(routeShortName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    LineTraceView(routeID: routeID, routeShortName: routeShortName)
                } label: {
                    Label("Ver trazado", systemImage: "map")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { dayPicker }
        }
        .task {
            // Settled before the keyed task below runs its first pass, so choosing the default
            // day does not count as a change of day and read the same table twice.
            if day == nil { day = defaultDay() }
            await loadLive()
        }
        // Keyed on the day, so switching days re-reads and nothing else does.
        .task(id: day) { await loadBoard() }
    }

    /// Today when the feed covers it, and otherwise the first day it does cover — which is the
    /// ordinary case with a window that can start tomorrow.
    private func defaultDay() -> ServiceDate? {
        let calendar = environment.repository.calendar
        let days = environment.feedStatus.serviceDays(calendar: calendar)
        let today = ServiceDate(Date(), calendar: calendar)
        return days.contains(today) ? today : days.first
    }

    /// Puts the next departure on screen, in whichever direction still has one.
    private func scrollToNext(_ proxy: ScrollViewProxy) {
        guard let board else { return }
        for direction in board.directions {
            if let next = direction.nextIndex {
                proxy.scrollTo(rowID(direction, next), anchor: .center)
                return
            }
        }
    }

    // MARK: - Secciones

    /// The live arrivals of this line at this stop, when the source has any.
    ///
    /// Reuses `ArrivalsService` — the same call `StopDetailView` and the map's place card make,
    /// throttled to 20 s per stop underneath — so this screen costs no new kind of request.
    /// Filtered to this line: the rest of the stop's traffic is not what was asked about.
    @ViewBuilder
    private var liveSection: some View {
        if let live, !lineArrivals.isEmpty {
            Section {
                ForEach(lineArrivals) { CompactArrivalRow(arrival: $0) }
            } header: {
                Text("Ahora mismo")
            } footer: {
                Text("Lo de abajo es el horario programado. Estos son los que la fuente en vivo está reportando para la línea \(routeShortName).")
            }
        }
    }

    private var lineArrivals: [Arrival] {
        let line = TextNormalization.normalizedLineName(routeShortName)
        return (live?.arrivals ?? []).filter { $0.normalizedLine == line }
    }

    private func directionSection(_ direction: DepartureBoard.Direction) -> some View {
        Section {
            ForEach(Array(direction.departures.enumerated()), id: \.offset) { index, departure in
                departureRow(departure, isNext: index == direction.nextIndex)
                    .id(rowID(direction, index))
            }
        } header: {
            HStack {
                Text("Hacia \(direction.destination)")
                Spacer()
                Text("\(direction.departures.count)")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(direction.departures.count) salidas")
            }
        }
    }

    private func departureRow(_ departure: ScheduledDeparture, isNext: Bool) -> some View {
        HStack(spacing: 10) {
            Text(departure.absoluteDate, format: .dateTime.hour().minute())
                .font(.body.monospacedDigit())
            if isNext {
                Text("siguiente")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.indigo)
            }
            Spacer(minLength: 0)
        }
        .listRowBackground(isNext ? Color.indigo.opacity(0.12) : nil)
        .accessibilityElement(children: .combine)
    }

    private func rowID(_ direction: DepartureBoard.Direction, _ index: Int) -> String {
        "\(direction.destination)#\(index)"
    }

    /// Only the days the feed can actually answer for.
    ///
    /// Not "seven days from today", which is a different list and sometimes a wrong one: a feed
    /// downloaded on 2026-09-04 reported a window starting on the 5th, so even today can fall
    /// outside it. Offering a day that answers nothing, with no explanation, is worse than not
    /// offering it.
    private var dayPicker: some View {
        Menu {
            ForEach(environment.feedStatus.serviceDays(calendar: environment.repository.calendar),
                    id: \.yyyymmdd) { candidate in
                Button {
                    day = candidate
                } label: {
                    if candidate == day {
                        Label(candidate.humanReadable, systemImage: "checkmark")
                    } else {
                        Text(candidate.humanReadable)
                    }
                }
            }
        } label: {
            Label(day?.humanReadable ?? "Día", systemImage: "calendar")
                .font(.subheadline)
        }
        .disabled(environment.feedStatus.serviceDays(
            calendar: environment.repository.calendar).isEmpty)
    }

    // MARK: - Carga

    private func loadBoard() async {
        guard let target = day else {
            loading = false
            return
        }
        loading = true
        let repository = environment.repository
        let stopID = stop.id
        let routeID = self.routeID
        let now = Date()
        // Off the main actor: a whole day of a busy line is 60–80 rows out of SQLite, and it
        // has no suspension point of its own to yield on.
        board = await Task.detached(priority: .userInitiated) {
            let departures = (try? repository.scheduledDepartures(
                stopID: stopID, routeID: routeID, on: target)) ?? []
            return DepartureBoard.build(departures, now: now)
        }.value
        loading = false
    }

    private func loadLive() async {
        live = await environment.arrivals.arrivals(for: stop)
    }
}

/// What the feed can and cannot say about a given day, in one sentence.
///
/// Its own type because the seven-day window is the caveat this app repeats everywhere, and
/// two copies of that wording is exactly how `PlanOutcome`'s text drifted before Fase 5 pulled
/// it into `PlanOutcomeMessage`.
enum FeedCoverageNote {
    static func text(for day: ServiceDate, status: FeedStatus) -> String {
        let base = "Horario programado del \(day.humanReadable)."
        guard let window = status.window else {
            return base + " Todavía no hay horarios importados."
        }
        return base + " Los horarios del Concello cubren del \(window.lowerBound.humanReadable)"
            + " al \(window.upperBound.humanReadable), y se renuevan cada semana."
    }
}
