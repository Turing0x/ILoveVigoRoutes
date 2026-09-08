import SwiftUI
import VigoCore

/// "¿En qué autobús vas?" — the one place a ride is declared.
///
/// Two ways in, one sheet. From the map the traveller picks a line and the GPS fix decides
/// where on its route they are; from a stop's arrivals the line *and* the stop are already
/// known, so the sheet skips straight to resolving and usually closes without a tap.
///
/// The realtime source cannot say which vehicle anybody is on — it has no trip or vehicle id
/// (`FirstBoardingMatch`) — so this asks rather than detects, and when the timetable and the
/// geometry cannot tell two directions apart it asks again instead of guessing.
struct OnboardDeclareSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Known when the sheet is opened from a stop's arrivals: that line, at that stop.
    var presetLine: String?
    var presetStop: Stop?

    @State private var timetable: Timetable?
    @State private var nearbyLines: [String] = []
    @State private var candidates: [OnboardTripCandidate] = []
    @State private var message: String?
    @State private var isWorking = false
    /// A lease on the app's single location manager, at the finest precision — the same thing
    /// the map's follow mode takes, and for the same reason: matching a coordinate to a
    /// position along a route needs better than a hundred metres.
    @State private var locationHolder = LocationDemand.Holder()

    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }

                if !candidates.isEmpty {
                    Section {
                        ForEach(candidates, id: \.self) { candidate in
                            Button {
                                declare(candidate, confidence: .confirmedByUser)
                            } label: {
                                HStack(spacing: 10) {
                                    LineBadge(name: candidate.routeShortName)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.headsign.map { "hacia \($0)" } ?? "sentido sin nombre")
                                        Text(candidate.distanceMetres < 1
                                             ? "en la parada"
                                             : "a \(Int(candidate.distanceMetres)) m de la parada")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("¿En cuál de los dos sentidos vas?")
                    } footer: {
                        Text("El horario y la posición no los distinguen: los dos pasan por aquí a esta hora.")
                    }
                }

                if candidates.isEmpty {
                    Section {
                        if isWorking || timetable == nil {
                            HStack { ProgressView(); Text("Buscando líneas cerca…") }
                        } else if nearbyLines.isEmpty {
                            ContentUnavailableView(
                                "Ninguna línea cerca",
                                systemImage: "location.slash",
                                description: Text("No hay ningún recorrido a menos de 400 m de donde estás."))
                        } else {
                            ForEach(nearbyLines, id: \.self) { line in
                                Button { resolve(line: line) } label: {
                                    HStack(spacing: 10) {
                                        LineBadge(name: line)
                                        Text("Voy en el \(line)")
                                        Spacer()
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(presetStop == nil ? "Líneas que pasan por aquí" : "Línea")
                    } footer: {
                        Text("""
                            La posición solo avanza con la app abierta: el permiso es «mientras se \
                            usa». Al volver a abrirla se pone al día con la siguiente parada que pases.
                            """)
                    }
                }
            }
            .navigationTitle("¿En qué autobús vas?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .task {
            environment.location.acquire(locationHolder, precision: .fine)
            environment.location.requestPermissionIfNeeded()
            timetable = await environment.timetable()
            if let line = presetLine {
                resolve(line: line)
            } else {
                refreshNearbyLines()
            }
        }
        .onDisappear { environment.location.release(locationHolder) }
        .onChange(of: environment.location.coordinate.map(Coordinate.from)) { _, _ in
            if presetLine == nil, candidates.isEmpty { refreshNearbyLines() }
        }
    }

    /// Where the traveller is: the stop they were looking at when they came from a stop's
    /// arrivals — which is exact and needs no GPS — or the current fix.
    private var coordinate: Coordinate? {
        if let presetStop { return Coordinate(presetStop) }
        return environment.location.coordinate.map(Coordinate.from)
    }

    private func refreshNearbyLines() {
        guard let timetable, let coordinate else { return }
        nearbyLines = OnboardTripResolution.linesNearby(coordinate: coordinate,
                                                        timetable: timetable)
    }

    private func resolve(line: String) {
        guard let timetable else { return }
        guard let coordinate else {
            message = "Todavía no sé dónde estás. Comprueba el permiso de ubicación."
            return
        }
        isWorking = true
        defer { isWorking = false }

        let outcome = OnboardTripResolution.resolve(
            OnboardTripResolution.Input(declaredLine: line, coordinate: coordinate, now: Date()),
            timetable: timetable)
        switch outcome {
        case .resolved(let candidate):
            declare(candidate, confidence: .inferred)
        case .ambiguous(let found):
            candidates = found
            message = nil
        case .noPatternForLine(let line):
            message = "No encuentro ninguna línea \(line) en los horarios importados."
        case .tooFarFromLine(let metres):
            message = "El recorrido más cercano de esa línea está a \(Int(metres)) m. ¿Es esa la línea?"
        case .noTripRunningNow(let line):
            message = "No hay ningún servicio de la línea \(line) pasando por aquí ahora mismo."
        }
    }

    private func declare(_ candidate: OnboardTripCandidate, confidence: OnboardRide.Confidence) {
        guard let timetable else { return }
        // The boarding stop is only claimed when it is actually known — arriving from a stop's
        // arrivals. Declared from the map mid-route, where the traveller got on is not
        // something anybody told us.
        let boardPosition = presetStop == nil ? nil : candidate.position
        environment.onboardRide.declare(OnboardRide(
            candidate, in: timetable, now: Date(),
            boardPosition: boardPosition, confidence: confidence))
        dismiss()
    }
}
