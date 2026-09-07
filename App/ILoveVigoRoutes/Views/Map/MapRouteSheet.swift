import SwiftUI
import VigoCore

/// Origin, destination and the alternatives between them — without leaving the map.
///
/// The header is the part that makes this a planner rather than a result list: both ends are
/// editable in place, they can be swapped, and the departure time is one tap away. Every one
/// of those edits re-plans, because a stale answer under freshly edited endpoints is the kind
/// of quiet lie this project rules out everywhere else.
struct MapRouteSheet: View {
    let state: MapNavigationState
    let failure: String?
    /// When the answer on screen was computed, or `nil` when there is none.
    let plannedAt: Date?
    /// Live first-boarding annotations, keyed by journey. Empty is the normal case.
    let live: (Journey) -> Arrival?
    /// What that countdown implies for the rest of the journey (D1). Takes the sheet's own
    /// `now`, so the countdown and the arrival it implies are computed against one instant.
    let liveAdjustment: (Journey, Date) -> LiveJourneyAdjustment.Adjustment?
    let onPick: (PlacePickerRole, MapPlace) -> Void
    let onSwap: () -> Void
    let onDeparture: (MapNavigationState.Departure) -> Void
    let onOrdering: (JourneyOrdering) -> Void
    let onAccessibility: (AccessibilityProfile) -> Void
    let onRefresh: () async -> Void
    let onSelect: (Int) -> Void
    let onOpen: () -> Void
    let onCloseDetail: () -> Void
    let onFollow: () -> Void
    let onStopFollowing: () -> Void
    let onStartActiveJourney: () -> Void
    let onClose: () -> Void

    /// Ticks while the sheet is open so "hace N min" and "Ya ha salido" stop being a
    /// photograph of the moment the list arrived. Nothing re-plans on this: it only re-reads
    /// the clock, and every time on screen is still the one the planner committed to.
    @State private var now = Date()

    /// Which end is being replaced, or `nil` when neither is.
    ///
    /// Was `PlacePickerView` for exactly one step, as a placeholder that worked rather than a
    /// button that did nothing; it is now the map's own search sheet, so both ways into a
    /// place — the search bar and this row — land on the same list.
    @State private var editing: PlacePickerRole?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    endpointRow("Origen", place: state.origin,
                                systemImage: state.originFollowsLocation ? "location.fill" : nil,
                                action: { editing = .origin })
                    endpointRow("Destino", place: state.destination,
                                systemImage: nil, action: { editing = .destination })
                    Button(action: onSwap) {
                        Label("Intercambiar", systemImage: "arrow.up.arrow.down")
                            .font(.subheadline)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        departurePicker
                        accessibilityToggle
                        if state.origin == nil {
                            // The origin is normally filled in by the device. When it is not,
                            // saying so beats an empty row the user has to guess about.
                            Text("Sin ubicación no puedo poner el origen por ti. Tócalo para elegirlo.")
                        }
                    }
                }

                results

                // Last, not first: the point of this sheet is the answer above it, and a
                // journey is worth saving once you have seen that it is the right one.
                if let origin = state.origin, let destination = state.destination {
                    Section {
                        Button {
                            saving = true
                        } label: {
                            Label("Guardar este trayecto",
                                  systemImage: "arrow.triangle.turn.up.right.diamond")
                        }
                    } footer: {
                        Text("Se guarda el par origen–destino, no el autobús concreto: al abrirlo se vuelve a calcular con los horarios del momento.")
                    }
                    .sheet(isPresented: $saving) {
                        SavedJourneyEditorView(mode: .createFrom(
                            origin: origin.savedEndpointInput, originName: origin.label,
                            destination: destination.savedEndpointInput,
                            destinationName: destination.label))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Cómo llegar")
            .navigationBarTitleDisplayMode(.inline)
            // Both gestures, not one. Pulling down is invisible and this sheet opens at a
            // detent where there is not always slack for it; the button is the one a user
            // who has just missed a bus can find.
            .refreshable { await onRefresh() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Actualizar", systemImage: "arrow.clockwise") {
                        Task { await onRefresh() }
                    }
                    .disabled(state.route.isPlanning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar", action: onClose)
                }
            }
            // A minute is the resolution of everything shown here, so a minute is the tick.
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) {
                now = $0
            }
            // Driven from `mode` rather than from a local `NavigationLink` so that going
            // back lands where `MapNavigationState.dismiss` says it should — which, while
            // following, means stopping the follow before closing anything.
            .navigationDestination(item: Binding(
                get: { state.mode == .journeyDetail ? state.currentJourney : nil },
                set: { if $0 == nil { onCloseDetail() } }
            )) { journey in
                MapJourneyLegsView(journey: journey,
                                   live: live(journey),
                                   isFollowing: state.isFollowing,
                                   onFollow: onFollow,
                                   onStopFollowing: onStopFollowing,
                                   onStartActiveJourney: onStartActiveJourney)
            }
            .sheet(item: $editing) { role in
                MapSearchSheet(purpose: .endpoint(role),
                               onPick: { onPick(role, $0); editing = nil },
                               // Unreachable for `.endpoint`: that purpose contributes one end
                               // of a saved journey through `onPick` instead of planning it.
                               onPickJourney: { _ in },
                               onCancel: { editing = nil })
            }
        }
    }

    // MARK: - Cabecera

    private func endpointRow(_ title: String, place: MapPlace?, systemImage: String?,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let systemImage, place != nil {
                    Image(systemName: systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(place?.label ?? "Elegir")
                    .font(.subheadline)
                    .foregroundStyle(place == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
    }

    /// A menu rather than a segmented picker: in a sheet the horizontal space is the scarce
    /// resource, and this control is touched far less often than the two endpoints above it.
    private var departurePicker: some View {
        HStack {
            Menu {
                Button("Salir ahora") { onDeparture(.now) }
                Button("Salir dentro de 15 min") {
                    onDeparture(.at(Date().addingTimeInterval(15 * 60)))
                }
                Button("Salir dentro de 30 min") {
                    onDeparture(.at(Date().addingTimeInterval(30 * 60)))
                }
                Button("Salir dentro de 1 h") {
                    onDeparture(.at(Date().addingTimeInterval(3_600)))
                }
            } label: {
                Label(departureText, systemImage: "clock")
                    .font(.footnote)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private var departureText: String {
        switch state.departure {
        case .now: "Ahora"
        case .at(let date): "A las \(date.formatted(date: .omitted, time: .shortened))"
        }
    }

    // MARK: - Resultados

    @ViewBuilder
    private var results: some View {
        if let failure {
            Section {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        } else if state.route.isPlanning {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Buscando rutas…").font(.subheadline)
                }
            }
        } else if let message = state.route.failure.flatMap({ PlanOutcomeMessage.failure($0) }) {
            Section { Text(message).font(.subheadline) }
        } else if !state.visibleJourneys.isEmpty {
            Section {
                ForEach(Array(state.visibleJourneys.enumerated()), id: \.offset) { index, journey in
                    let gone = FirstBoardingMatch.hasDeparted(journey, now: now)
                    Button {
                        // Tapping the highlighted one again opens it. Tapping another
                        // highlights it first — so the map redraws before anyone commits to a
                        // route they have not seen yet.
                        if index == state.selectedAlternative { onOpen() } else { onSelect(index) }
                    } label: {
                        HStack(spacing: 10) {
                            JourneyAlternativeRow(journey: journey, live: live(journey),
                                                  hasDeparted: gone,
                                                  adjustment: liveAdjustment(journey, now))
                            if index == state.selectedAlternative {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    // Dimmed, not hidden. A bus that has gone is still the answer to what the
                    // user asked, and removing rows underneath a finger is worse than fading
                    // them: the honest move is to say so and leave the choice.
                    .opacity(gone ? 0.5 : 1)
                    .listRowBackground(index == state.selectedAlternative
                                       ? Color.indigo.opacity(0.12) : nil)
                }
            } header: {
                HStack {
                    Text(state.route.isWalkOnly
                         ? "A pie" : "Alternativas (\(state.visibleJourneys.count))")
                    Spacer()
                    if !state.route.isWalkOnly { orderingMenu }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    // A2. Above the other footnotes and in the warning colour, because it
                    // is not a footnote: it says these times are an estimate rather than
                    // the operator's data. `estimateNotice` is `nil` whenever the schedule
                    // is observed, so this costs nothing on the common path.
                    if let estimate = state.estimateNotice {
                        Label(estimate, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                    if state.route.isWalkOnly {
                        Text(PlanOutcomeMessage.walkOnlyExplanation)
                    }
                    if let age = ageText {
                        Text(age)
                    }
                }
            }
        }
    }

    /// The mobility profile (C3).
    ///
    /// A toggle and not a menu: there are two states, and a menu would hide which one is
    /// active behind a tap. It sits with the departure controls rather than beside the
    /// ordering menu on purpose — ordering is about how the answers are shown, this is about
    /// what is searched for, and putting them side by side would suggest they are the same
    /// kind of choice.
    ///
    /// The footnote is the honest part. It promises what the data supports — a walking route
    /// that avoids steps — and not what it does not: the feed declares every stop and every
    /// vehicle accessible, so this app has no basis to claim anything about kerbs or ramps.
    private var accessibilityToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { state.accessibility == .wheelchair },
                set: { onAccessibility($0 ? .wheelchair : .standard) })
            ) {
                Label("Ruta sin escaleras", systemImage: "figure.roll")
            }
            .accessibilityHint("Evita escaleras y cuestas fuertes al calcular los tramos a pie")

            if state.accessibility == .wheelchair {
                Text("Los tramos a pie rodean escaleras, tramos marcados como no accesibles y cuestas fuertes. No podemos confirmar la accesibilidad de cada parada ni de cada autobús: el Concello los declara todos accesibles y no publica el detalle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A menu and not a segmented picker, for the reason already written for the departure
    /// control: in a sheet the horizontal space is the scarce resource, and three labels of
    /// this length would not fit across a small iPhone.
    private var orderingMenu: some View {
        Menu {
            ForEach(JourneyOrdering.allCases, id: \.self) { candidate in
                Button {
                    onOrdering(candidate)
                } label: {
                    if candidate == state.ordering {
                        Label(candidate.label, systemImage: "checkmark")
                    } else {
                        Label(candidate.label, systemImage: candidate.symbolName)
                    }
                }
            }
        } label: {
            Label(state.ordering.label, systemImage: "arrow.up.arrow.down")
                .font(.caption)
                .textCase(nil)
        }
        .accessibilityLabel("Ordenar por: \(state.ordering.label)")
    }

    /// How old the answer is, or `nil` when saying so would be noise.
    ///
    /// Only with `.now` as the departure. A journey asked for at a fixed hour does not go
    /// stale — nothing about a 15:40 bus changes because it is now 15:20 — and putting a
    /// timestamp on it would invite a refresh that cannot return anything different.
    private var ageText: String? {
        guard case .now = state.departure, let plannedAt else { return nil }
        let minutes = Int(now.timeIntervalSince(plannedAt) / 60)
        guard minutes >= 1 else { return "Calculado ahora mismo." }
        return "Calculado hace \(minutes) min. Desliza hacia abajo para volver a preguntar."
    }
}

/// One journey, leg by leg, inside the route sheet.
///
/// Replaces `JourneyDetailView`, which put a small non-interactive map inside a list and
/// pushed a second full-screen map to make it useful. With the real map already behind this
/// sheet — and already highlighting exactly this alternative — that whole detour existed to
/// get back to where the user started.
struct MapJourneyLegsView: View {
    let journey: Journey
    let live: Arrival?
    let isFollowing: Bool
    let onFollow: () -> Void
    let onStopFollowing: () -> Void
    let onStartActiveJourney: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// A walk-only journey has no bus to have boarded — nothing to persist.
    private var hasRide: Bool {
        journey.legs.contains { if case .ride = $0 { true } else { false } }
    }

    var body: some View {
        List {
            if let live {
                Section {
                    HStack(spacing: 10) {
                        DataKindBadge(kind: live.confidence.hasTrackedVehicle ? .tracked : .estimated)
                        Text(WaitTime(minutes: live.minutes).inlineText)
                            .font(.subheadline)
                        Spacer(minLength: 0)
                    }
                } header: {
                    Text("Primer embarque, en vivo")
                } footer: {
                    Text("El resto del trayecto sigue siendo el horario: el tiempo real solo cubre la parada de origen.")
                }
            }

            Section {
                Button(isFollowing ? "Dejar de seguir" : "Seguir en el mapa",
                       systemImage: isFollowing ? "location.slash.fill" : "location.fill") {
                    isFollowing ? onStopFollowing() : onFollow()
                }
            } footer: {
                Text("Mantiene la pantalla encendida y la cámara mirando hacia donde caminas. Sin avisos de bajada: el horario por sí solo no puede prometerlos.")
            }

            if hasRide {
                Section {
                    Button("He subido a este bus", systemImage: "bus.fill") {
                        onStartActiveJourney()
                        dismiss()
                    }
                } footer: {
                    Text("Queda a la vista en todas las pestañas hasta que llegues o lo termines a mano. No se replanifica: es este autobús, no una nueva búsqueda.")
                }
            }

            Section("Tramos") {
                ForEach(Array(journey.legs.enumerated()), id: \.offset) { _, leg in
                    JourneyLegRow(leg: leg)
                }
            }
        }
        .navigationTitle("Trayecto")
        .navigationBarTitleDisplayMode(.inline)
    }
}
