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
    /// Live first-boarding annotations, keyed by journey. Empty is the normal case.
    let live: (Journey) -> Arrival?
    let onPick: (PlacePickerRole, MapPlace) -> Void
    let onSwap: () -> Void
    let onDeparture: (MapNavigationState.Departure) -> Void
    let onSelect: (Int) -> Void
    let onOpen: () -> Void
    let onCloseDetail: () -> Void
    let onFollow: () -> Void
    let onStopFollowing: () -> Void
    let onClose: () -> Void

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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar", action: onClose)
                }
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
                                   onStopFollowing: onStopFollowing)
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
        } else if !state.route.journeys.isEmpty {
            Section {
                ForEach(Array(state.route.journeys.enumerated()), id: \.offset) { index, journey in
                    Button {
                        // Tapping the highlighted one again opens it. Tapping another
                        // highlights it first — so the map redraws before anyone commits to a
                        // route they have not seen yet.
                        if index == state.selectedAlternative { onOpen() } else { onSelect(index) }
                    } label: {
                        HStack(spacing: 10) {
                            JourneyAlternativeRow(journey: journey, live: live(journey))
                            if index == state.selectedAlternative {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(index == state.selectedAlternative
                                       ? Color.indigo.opacity(0.12) : nil)
                }
            } header: {
                Text(state.route.isWalkOnly ? "A pie" : "Alternativas (\(state.route.journeys.count))")
            } footer: {
                if state.route.isWalkOnly {
                    Text(PlanOutcomeMessage.walkOnlyExplanation)
                }
            }
        }
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
