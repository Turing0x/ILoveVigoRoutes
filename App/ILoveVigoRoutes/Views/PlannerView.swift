import SwiftUI
import VigoCore

@MainActor
@Observable
final class PlannerModel {
    enum DepartureMode: Hashable { case now, scheduled }

    private let planner: JourneyPlanner

    private(set) var origin: Place?
    private(set) var destination: Place?

    /// True while the origin is still whatever the device last reported.
    ///
    /// The default origin is "where I am", and it keeps up with the device until the user
    /// says otherwise — picking a place by hand, or swapping the two ends, is exactly that.
    /// Without this flag a later fix would quietly overwrite an origin chosen on purpose,
    /// which is the kind of silent wrong answer this app rules out everywhere else.
    private(set) var originFollowsLocation = true

    var departureMode: DepartureMode = .now
    var departureAt: Date = Date()

    private(set) var outcome: PlanOutcome?
    private(set) var isLoading = false
    private(set) var errorText: String?

    init(planner: JourneyPlanner) {
        self.planner = planner
    }

    var canPlan: Bool { origin != nil && destination != nil }

    func setOrigin(_ picked: PickedPlace) {
        origin = picked.place
        originFollowsLocation = picked.isCurrentLocation
    }

    func setDestination(_ picked: PickedPlace) {
        destination = picked.place
    }

    /// A fresh fix from the device. Ignored once the origin belongs to the user.
    func updateCurrentLocation(_ coordinate: Coordinate) {
        guard originFollowsLocation else { return }
        origin = PickedPlace.currentLocation(coordinate).place
    }

    /// Back to the automatic origin after the user had picked one by hand.
    func useCurrentLocation(_ coordinate: Coordinate) {
        setOrigin(.currentLocation(coordinate))
    }

    func swapPlaces() {
        (origin, destination) = (destination, origin)
        originFollowsLocation = false
    }

    func plan() async {
        guard let origin, let destination else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        let departure = departureMode == .now ? Date() : departureAt
        do {
            let result = try await planner.plan(PlanQuery(
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
    @State private var location = LocationProvider()
    @State private var pickingOrigin = false
    @State private var pickingDestination = false

    /// `CLLocationCoordinate2D` is not `Equatable`, so `onChange` cannot watch it directly.
    /// `Coordinate` is, and it is the type the planner speaks anyway.
    private var currentCoordinate: Coordinate? {
        location.coordinate.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
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
            .navigationTitle("Planificar")
        }
        .task {
            if model == nil { model = PlannerModel(planner: environment.planner) }
            location.requestPermissionIfNeeded()
            location.start()
            if let currentCoordinate { model?.updateCurrentLocation(currentCoordinate) }
        }
        .onChange(of: currentCoordinate) { _, new in
            if let new { model?.updateCurrentLocation(new) }
        }
        .onDisappear { location.stop() }
    }

    @ViewBuilder
    private func content(_ model: PlannerModel) -> some View {
        Form {
            Section {
                placeRow(title: "Origen", place: model.origin,
                         systemImage: model.originFollowsLocation ? "location.fill" : nil) {
                    pickingOrigin = true
                }
                if !model.originFollowsLocation, let currentCoordinate {
                    Button {
                        model.useCurrentLocation(currentCoordinate)
                    } label: {
                        Label("Usar mi ubicación", systemImage: "location")
                            .font(.footnote)
                    }
                }
                Button {
                    model.swapPlaces()
                } label: {
                    Label("Intercambiar origen y destino", systemImage: "arrow.up.arrow.down")
                }
                placeRow(title: "Destino", place: model.destination) { pickingDestination = true }
            } footer: {
                if model.originFollowsLocation, currentCoordinate == nil {
                    Text(location.isDenied
                         ? "Sin permiso de ubicación tendrás que elegir el origen a mano."
                         : "Activa la ubicación para partir de donde estás.")
                }
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
            PlacePickerView(title: "Origen", role: .origin) { model.setOrigin($0) }
        }
        .sheet(isPresented: $pickingDestination) {
            PlacePickerView(title: "Destino", role: .destination) { model.setDestination($0) }
        }
    }

    private func placeRow(title: String, place: Place?, systemImage: String? = nil,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                if let systemImage, place != nil {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
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
            Section("Alternativas (\(journeys.count))") {
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
