import SwiftUI
import VigoCore

/// The persistent capsule for the journey the user is currently riding.
///
/// Lives in `RootView`, above the tab bar, not inside `MapScreen` — the requirement is that
/// it stays visible while switching tabs, and `MapScreen`'s own `safeAreaInset` is scoped to
/// that one tab.
///
/// A line, not a card: on purpose the lightest possible presence, since it competes with
/// nothing else the user asked to see on screen.
struct ActiveJourneyBar: View {
    let journey: ActiveJourneySnapshot
    let staleness: ActiveJourneyStaleness
    let onExtend: () -> Void
    let onEnd: () -> Void

    @State private var showingDetail = false
    @State private var confirmingCancel = false

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isStale ? "questionmark.circle.fill" : "bus.fill")
                    .foregroundStyle(isStale ? .orange : .accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isStale ? "¿Sigues en este trayecto?" : "Trayecto en curso")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(headline).font(.subheadline).lineLimit(1)
                }
                Spacer(minLength: 0)
                if isStale {
                    Button("Sigo en él", action: onExtend)
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Terminar", systemImage: "checkmark.circle", action: onEnd)
            Button("Cancelar", systemImage: "xmark.circle", role: .destructive) {
                confirmingCancel = true
            }
        }
        .confirmationDialog("¿Cancelar este trayecto?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Cancelar trayecto", role: .destructive, action: onEnd)
            Button("Seguir con el trayecto", role: .cancel) {}
        }
        .sheet(isPresented: $showingDetail) {
            ActiveJourneyDetailSheet(journey: journey, onEnd: {
                showingDetail = false
                onEnd()
            })
        }
    }

    private var isStale: Bool {
        if case .stale = staleness { return true }
        return false
    }

    private var headline: String {
        let alightName = journey.rides.last?.alight.name ?? journey.destination.name
        let time = journey.scheduledArrival.formatted(date: .omitted, time: .shortened)
        guard let line = journey.rides.last?.routeShortName else {
            return "\(journey.destination.name) · \(time)"
        }
        return "\(line) → \(alightName) · \(time)"
    }
}

/// The active journey, leg by leg. Its own small sheet rather than a push into the map's
/// route detail: an active journey is an instantaneous snapshot, not a live `Journey` the
/// planner produced this session, so it does not fit `MapNavigationState.journeyDetail`.
private struct ActiveJourneyDetailSheet: View {
    let journey: ActiveJourneySnapshot
    let onEnd: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingCancel = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Origen", value: journey.originName)
                    LabeledContent("Destino", value: journey.destination.name)
                    LabeledContent("Llegada prevista",
                                   value: journey.scheduledArrival.formatted(date: .omitted, time: .shortened))
                }

                Section("Tramos") {
                    ForEach(Array(journey.rides.enumerated()), id: \.offset) { _, ride in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                LineBadge(name: ride.routeShortName)
                                if let headsign = ride.headsign {
                                    Text(headsign).font(.subheadline)
                                }
                            }
                            Text("\(ride.board.name) → \(ride.alight.name)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    Button("Terminar trayecto", systemImage: "checkmark.circle", action: onEnd)
                    Button("Cancelar trayecto", systemImage: "xmark.circle", role: .destructive) {
                        confirmingCancel = true
                    }
                }
            }
            .navigationTitle("Trayecto activo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .confirmationDialog("¿Cancelar este trayecto?", isPresented: $confirmingCancel, titleVisibility: .visible) {
                Button("Cancelar trayecto", role: .destructive, action: onEnd)
                Button("Seguir con el trayecto", role: .cancel) {}
            }
        }
    }
}
