import SwiftUI
import VigoCore

@MainActor
@Observable
final class PlannerModel {
    enum DepartureMode: Hashable { case now, scheduled }

    private let environment: AppEnvironment

    var origin: Place?
    var destination: Place?
    var departureMode: DepartureMode = .now
    var departureAt: Date = Date()

    private(set) var outcome: PlanOutcome?
    private(set) var isLoading = false
    private(set) var errorText: String?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var canPlan: Bool { origin != nil && destination != nil }

    func swapPlaces() {
        (origin, destination) = (destination, origin)
    }

    func plan() async {
        guard let origin, let destination else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        let departure = departureMode == .now ? Date() : departureAt
        do {
            let result = try await environment.planner.plan(PlanQuery(
                origin: origin, destination: destination, departure: departure))
            outcome = result.outcome
        } catch {
            outcome = nil
            errorText = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        }
    }
}

struct PlannerView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: PlannerModel?
    @State private var pickingOrigin = false
    @State private var pickingDestination = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Planificar")
        }
        .task {
            if model == nil { model = PlannerModel(environment: environment) }
        }
    }

    @ViewBuilder
    private func content(_ model: PlannerModel) -> some View {
        Form {
            Section {
                placeRow(title: "Origen", place: model.origin) { pickingOrigin = true }
                Button {
                    model.swapPlaces()
                } label: {
                    Label("Intercambiar origen y destino", systemImage: "arrow.up.arrow.down")
                }
                placeRow(title: "Destino", place: model.destination) { pickingDestination = true }
            }

            Section {
                Picker("Salida", selection: Binding(
                    get: { model.departureMode }, set: { model.departureMode = $0 })) {
                    Text("Ahora").tag(PlannerModel.DepartureMode.now)
                    Text("A una hora").tag(PlannerModel.DepartureMode.scheduled)
                }
                .pickerStyle(.segmented)
                if model.departureMode == .scheduled {
                    DatePicker("Hora de salida", selection: Binding(
                        get: { model.departureAt }, set: { model.departureAt = $0 }))
                }
            }

            Section {
                Button {
                    Task { await model.plan() }
                } label: {
                    HStack {
                        Spacer()
                        if model.isLoading {
                            ProgressView()
                        } else {
                            Text("Buscar ruta").font(.headline)
                        }
                        Spacer()
                    }
                }
                .disabled(!model.canPlan || model.isLoading)
            }

            if let errorText = model.errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if let outcome = model.outcome {
                outcomeSection(outcome)
            }
        }
        .sheet(isPresented: $pickingOrigin) {
            PlacePickerView(title: "Origen") { model.origin = $0 }
        }
        .sheet(isPresented: $pickingDestination) {
            PlacePickerView(title: "Destino") { model.destination = $0 }
        }
    }

    private func placeRow(title: String, place: Place?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(place?.label ?? "Elegir")
                    .foregroundStyle(place == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func outcomeSection(_ outcome: PlanOutcome) -> some View {
        switch outcome {
        case .journeys(let journeys):
            Section("Alternativas") {
                ForEach(journeys) { journey in
                    NavigationLink {
                        JourneyDetailView(journey: journey)
                    } label: {
                        JourneyAlternativeRow(journey: journey)
                    }
                }
            }

        case .walkOnly(let journey):
            Section {
                NavigationLink {
                    JourneyDetailView(journey: journey)
                } label: {
                    JourneyAlternativeRow(journey: journey)
                }
            } header: {
                Text("A pie")
            } footer: {
                Text("Caminar es más rápido que cualquier autobús disponible ahora mismo.")
            }

        case .noStopsNearOrigin(let radius):
            Section {
                Text("No hay ninguna parada a menos de \(Int(radius)) m del origen.")
            }

        case .noStopsNearDestination(let radius):
            Section {
                Text("No hay ninguna parada a menos de \(Int(radius)) m del destino.")
            }

        case .outsideFeedWindow(let window):
            Section {
                Text("""
                    No tengo datos para ese día. Los horarios importados cubren del \
                    \(window.lowerBound.humanReadable) al \(window.upperBound.humanReadable).
                    """)
            }

        case .noServiceOnDay(let day):
            Section {
                Text("No hay servicio programado el \(day.humanReadable).")
            }

        case .noJourneyFound(let horizon):
            Section {
                Text("No he encontrado ninguna ruta en las próximas \(Int(horizon / 3_600)) horas.")
            }

        case .noData:
            Section {
                Text("Todavía no se han importado los datos del Concello.")
            }
        }
    }
}
