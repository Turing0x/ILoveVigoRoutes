import SwiftUI
import MapKit
import UIKit
import VigoCore

/// The journey, full screen, with the user on it.
///
/// The point of this screen is movement: the same trace `JourneyDetailView` previews, plus
/// the blue dot and a camera that follows it, so the map answers "where am I along this
/// route" while walking or riding. It deliberately stops there — no progress model, no
/// "get off here" alerts — because everything past the dot is a promise about the vehicle
/// the timetable alone cannot keep.
struct JourneyMapView: View {
    @Environment(AppEnvironment.self) private var environment
    let journey: Journey

    @State private var traces: [JourneyTrace]
    @State private var camera: MapCameraPosition
    @State private var location = LocationProvider()

    private let journeyRegion: MKCoordinateRegion

    init(journey: Journey, traces: [JourneyTrace]) {
        self.journey = journey
        let region = JourneyTraceBuilder.region(for: journey, traces: traces)
        self.journeyRegion = region
        _traces = State(initialValue: traces)
        _camera = State(initialValue: .userLocation(followsHeading: true, fallback: .region(region)))
    }

    var body: some View {
        Map(position: $camera) {
            JourneyMapContent(journey: journey, traces: traces)
            UserAnnotation()
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) { controls }
        .navigationTitle("Navegación")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            if traces.isEmpty {
                traces = JourneyTraceBuilder.traces(for: journey, repository: environment.repository)
            }
            location.requestPermissionIfNeeded()
            // Hundred-metre fixes are fine for "which stops are near me"; following someone
            // down a street is not the same question.
            location.start(accuracy: kCLLocationAccuracyBest)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            location.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// What is already known about the journey — no live progress, just the shape of it.
    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(journey.legs.enumerated()), id: \.offset) { _, leg in
                    switch leg {
                    case .ride(_, let routeShortName, _, _, _, _, _, _, _):
                        LineBadge(name: routeShortName)
                    case .walk:
                        Image(systemName: "figure.walk")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("llega \(journey.arrival.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())

            if location.isDenied {
                Text("Sin permiso de ubicación no puedo seguir tu movimiento.")
                    .font(.caption2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            // `followsUserLocation` goes false on its own as soon as the map is panned by
            // hand, which is exactly when this button becomes worth showing.
            if !camera.followsUserLocation {
                Button {
                    camera = .userLocation(followsHeading: true, fallback: .region(journeyRegion))
                } label: {
                    Label("Seguirme", systemImage: "location.fill")
                        .font(.footnote)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }

            Button {
                camera = .region(journeyRegion)
            } label: {
                Label("Ver todo el trayecto", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.primary)
        }
        .padding(.bottom, 18)
    }
}
