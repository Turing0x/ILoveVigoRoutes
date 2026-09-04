import SwiftUI
import MapKit
import VigoCore

/// Leg by leg, with the real trace on the map — the first place `shapePoint` is read at
/// all: it has been imported, indexed, and sitting unused since Fase 0.
///
/// The map here is a preview, not a tool: it is deliberately not interactive, and tapping it
/// pushes `JourneyMapView`, where the same journey is drawn full screen with the user's own
/// position on it.
struct JourneyDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let journey: Journey

    @State private var camera: MapCameraPosition = .automatic
    @State private var traces: [JourneyTrace] = []
    @State private var liveFirstBoarding: Arrival?

    /// The first ride — real time, kept out of `RaptorEngine` by design, is annotated only
    /// here, and only for this one boarding: the rest of the journey is still the
    /// timetable, and saying otherwise would be a promise the realtime source cannot keep.
    private var firstRide: (routeShortName: String, board: Stop, departure: Date)? {
        for leg in journey.legs {
            if case .ride(_, let routeShortName, _, _, let board, _, let departure, _, _) = leg {
                return (routeShortName, board, departure)
            }
        }
        return nil
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    JourneyMapView(journey: journey, traces: traces)
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Map(position: $camera) {
                            JourneyMapContent(journey: journey, traces: traces)
                        }
                        // A live `Map` swallows every gesture, so the row would never fire.
                        // Turning hit testing off is what makes the whole preview a tap
                        // target for the push.
                        .allowsHitTesting(false)
                        .frame(height: 260)

                        Label("Ver mapa completo", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(10)
                    }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
            }

            if let firstRide, let liveFirstBoarding {
                Section {
                    HStack(spacing: 10) {
                        DataKindBadge(kind: liveFirstBoarding.confidence.hasTrackedVehicle ? .tracked : .estimated)
                        Text("Línea \(firstRide.routeShortName): \(WaitTime(minutes: liveFirstBoarding.minutes).inlineText)")
                            .font(.subheadline)
                        Spacer(minLength: 0)
                    }
                } header: {
                    Text("Primer embarque, en vivo")
                } footer: {
                    Text("El resto del trayecto sigue siendo el horario: el tiempo real solo cubre la parada de origen.")
                }
            }

            Section("Tramos") {
                ForEach(Array(journey.legs.enumerated()), id: \.offset) { _, leg in
                    JourneyLegRow(leg: leg)
                }
            }
        }
        .navigationTitle("Detalle del trayecto")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            await loadLiveFirstBoarding()
        }
    }

    private func load() async {
        // Reading the ridden shape is a SQLite hit per ride leg. `.task` already runs
        // async, but with no suspension point the work would still land on the main actor
        // during the push animation — `Task.detached` is what actually moves it off.
        let repository = environment.repository
        let built = await Task.detached(priority: .userInitiated) {
            JourneyTraceBuilder.traces(for: journey, repository: repository)
        }.value
        traces = built
        camera = .region(JourneyTraceBuilder.region(for: journey, traces: traces))
    }

    /// Matches the first ride against the realtime feed for its boarding stop.
    ///
    /// The realtime API has no notion of "this specific scheduled trip" — only a line, a
    /// destination, and a countdown from now — so the match is heuristic: same line,
    /// implied absolute time closest to the one this leg already committed to, and only
    /// accepted within 15 minutes of it. Outside that window this is almost certainly a
    /// different vehicle on the same line, and showing it would be worse than showing
    /// nothing. A future-dated query (anything but "ahora") never matches, which is
    /// correct: the realtime feed only ever knows about buses already close to arriving.
    private func loadLiveFirstBoarding() async {
        guard let firstRide else { return }
        let normalizedLine = TextNormalization.normalizedLineName(firstRide.routeShortName)
        let now = Date()
        let result = await environment.arrivals.arrivals(for: firstRide.board, now: now)

        let closest = result.arrivals
            .filter { $0.normalizedLine == normalizedLine }
            .min { a, b in
                abs(now.addingTimeInterval(TimeInterval(a.minutes * 60)).timeIntervalSince(firstRide.departure))
                    < abs(now.addingTimeInterval(TimeInterval(b.minutes * 60)).timeIntervalSince(firstRide.departure))
            }
        guard let closest else { return }
        let impliedArrival = now.addingTimeInterval(TimeInterval(closest.minutes * 60))
        guard abs(impliedArrival.timeIntervalSince(firstRide.departure)) <= 15 * 60 else { return }
        liveFirstBoarding = closest
    }
}
