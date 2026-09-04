import SwiftUI
import MapKit
import VigoCore

struct StopsMapView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var location = LocationProvider()
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: LocationProvider.vigoCentre,
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)))
    @State private var visibleStops: [Stop] = []
    @State private var allStops: [Stop] = []
    @State private var selected: Stop?

    /// Above this many candidates the map draws nothing but a hint to zoom in. Plotting
    /// 1149 annotations at city scale is unreadable and janky.
    private let annotationLimit = 220

    var body: some View {
        NavigationStack {
            Map(position: $camera, selection: Binding(
                get: { selected?.id.rawValue },
                set: { id in selected = allStops.first { $0.id.rawValue == id } })
            ) {
                UserAnnotation()
                ForEach(visibleStops) { stop in
                    Marker(stop.name, systemImage: "bus.fill",
                           coordinate: CLLocationCoordinate2D(latitude: stop.latitude,
                                                              longitude: stop.longitude))
                    .tint(.indigo)
                    .tag(stop.id.rawValue)
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                updateVisible(for: context.region)
            }
            .overlay(alignment: .top) {
                if visibleStops.isEmpty && !allStops.isEmpty {
                    Text("Acerca el mapa para ver las paradas")
                        .font(.footnote)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
            .navigationTitle("Mapa")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selected) { stop in
                NavigationStack {
                    StopDetailView(stop: stop, environment: environment)
                }
                .presentationDetents([.medium, .large])
            }
        }
        .task {
            location.requestPermissionIfNeeded()
            location.start()
            allStops = (try? environment.repository.allStops()) ?? []
            if let coordinate = location.coordinate {
                camera = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
            }
        }
        .onDisappear { location.stop() }
        .onChange(of: environment.feedStatus.importedAt) {
            allStops = (try? environment.repository.allStops()) ?? []
        }
    }

    private func updateVisible(for region: MKCoordinateRegion) {
        let latRange = (region.center.latitude - region.span.latitudeDelta / 2)
            ... (region.center.latitude + region.span.latitudeDelta / 2)
        let lonRange = (region.center.longitude - region.span.longitudeDelta / 2)
            ... (region.center.longitude + region.span.longitudeDelta / 2)
        let inView = allStops.filter {
            latRange.contains($0.latitude) && lonRange.contains($0.longitude)
        }
        visibleStops = inView.count > annotationLimit ? [] : inView
    }
}
