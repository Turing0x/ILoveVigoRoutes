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
        FirstBoardingMatch.firstRide(of: journey)
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
    /// The heuristic itself now lives in `FirstBoardingMatch` (VigoCore), where it is tested
    /// and where the route list reads it too — two copies of a rule like this drift, exactly
    /// as the two copies of `PlanOutcome`'s wording had already drifted before Fase 5.
    private func loadLiveFirstBoarding() async {
        guard let firstRide else { return }
        let now = Date()
        let result = await environment.arrivals.arrivals(for: firstRide.board, now: now)
        liveFirstBoarding = FirstBoardingMatch.match(
            arrivals: result.arrivals, routeShortName: firstRide.routeShortName,
            scheduledDeparture: firstRide.departure, now: now)
    }
}
