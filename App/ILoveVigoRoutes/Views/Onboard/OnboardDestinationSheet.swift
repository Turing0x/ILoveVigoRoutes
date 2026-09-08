import SwiftUI
import VigoCore

/// "Ya que voy en este autobús, ¿me sirve para ir a X?"
///
/// Pick a destination, and the answer comes back in the two shapes that matter: this bus
/// reaches it — get off at such a stop, at such a time — or it does not, and here is where to
/// get off and what to take next. Accepting one turns the loose ride into an active journey.
struct OnboardDestinationSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let ride: OnboardRide

    @State private var destination: MapPlace?
    @State private var showingSearch = false
    @State private var journeys: [Journey] = []
    @State private var failure: String?
    @State private var isPlanning = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingSearch = true
                    } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text(destination?.place.label ?? "¿Adónde quieres ir?")
                                .foregroundStyle(destination == nil ? .secondary : .primary)
                            Spacer()
                        }
                    }
                } header: {
                    Text("Destino")
                } footer: {
                    Text("Se busca desde donde va el autobús ahora, no desde una parada: solo cuentan las paradas que le quedan por delante.")
                }

                if isPlanning {
                    Section { HStack { ProgressView(); Text("Mirando si te sirve…") } }
                }

                if let failure {
                    Section { Text(failure).foregroundStyle(.secondary) }
                }

                if !journeys.isEmpty {
                    Section {
                        ForEach(Array(journeys.enumerated()), id: \.offset) { _, journey in
                            OnboardJourneyRow(ride: ride, journey: journey) {
                                accept(journey)
                            }
                        }
                    } header: {
                        Text(journeys.first?.transfers == 0
                             ? "Sí, este autobús te sirve"
                             : "Con un cambio")
                    } footer: {
                        Text("Los horarios de este autobús llevan ya el retraso medido; los del enlace son los del horario.")
                    }
                }
            }
            .navigationTitle("Desde el \(ride.routeShortName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
            }
            .sheet(isPresented: $showingSearch) {
                MapSearchSheet(
                    purpose: .standalone(title: "Destino"),
                    onPick: { place in
                        destination = place
                        showingSearch = false
                        Task { await plan() }
                    },
                    onPickJourney: { journey in
                        // A saved journey contributes only its destination here: its origin is a
                        // place on the street, and the origin of this question is a moving bus.
                        destination = MapPlace(place: journey.destination.place,
                                               origin: .address)
                        showingSearch = false
                        Task { await plan() }
                    },
                    onCancel: { showingSearch = false },
                    resolver: environment.placeResolver)
            }
        }
    }

    private func plan() async {
        guard let destination else { return }
        isPlanning = true
        failure = nil
        journeys = []
        defer { isPlanning = false }

        do {
            let result = try await environment.planner.planOnboard(OnboardQuery(
                ride: ride, destination: destination.place, now: Date()))
            switch result.outcome {
            case .journeys(let found):
                journeys = found
            case .walkOnly(let walk):
                journeys = [walk]
            default:
                failure = PlanOutcomeMessage.failure(result.outcome)
            }
        } catch {
            failure = "No he podido calcularlo: \(error.localizedDescription)"
        }
    }

    private func accept(_ journey: Journey) {
        _ = environment.onboardRide.accept(
            journey, destinationLabel: destination?.place.label ?? "Destino")
        environment.activeJourney.reload()
        dismiss()
    }
}

/// One answer, written the way somebody standing in a moving bus reads it: where to get off
/// first, what it costs, and only then the rest.
struct OnboardJourneyRow: View {
    let ride: OnboardRide
    let journey: Journey
    let onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let alighting = OnboardJourneyFacts.alighting(journey) {
                HStack(spacing: 8) {
                    LineBadge(name: ride.routeShortName)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bájate en \(alighting.stop.name)")
                            .font(.subheadline.weight(.semibold))
                        Text(alighting.at.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let next = OnboardJourneyFacts.nextBoarding(journey) {
                HStack(spacing: 8) {
                    LineBadge(name: next.routeShortName)
                    Text("Sale de \(next.board.name) a las "
                         + next.departure.formatted(date: .omitted, time: .shortened))
                        .font(.footnote)
                }
                if let slack = OnboardJourneyFacts.connectionSlack(journey) {
                    Text(slackText(slack))
                        .font(.caption)
                        .foregroundStyle(slack < 120 ? .orange : .secondary)
                }
            } else if case .walk(_, _, let seconds, let metres)? = journey.legs.last {
                Text("Y \(Int((Double(seconds) / 60).rounded())) min andando (\(Int(metres)) m)")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            HStack {
                Text("Llegas a las " + journey.arrival.formatted(date: .omitted, time: .shortened))
                    .font(.footnote)
                Spacer()
                Button("Seguir este plan", action: onAccept)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func slackText(_ slack: TimeInterval) -> String {
        let minutes = Int((slack / 60).rounded(.down))
        if minutes < 0 { return "El enlace ya habría salido." }
        if minutes < 2 { return "Enlace muy justo: \(minutes) min entre uno y otro." }
        return "\(minutes) min para el cambio."
    }
}
