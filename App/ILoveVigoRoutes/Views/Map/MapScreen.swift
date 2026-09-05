import SwiftUI
import MapKit
import VigoCore

/// The map tab.
///
/// Replaces `StopsMapView` with the same behaviour plus the one thing the owner asked for
/// first: **the stops are a layer, and the layer is off by default**. A map that opens
/// speckled with 1149 pins is noise; what it should open as is a clean map of Vigo.
///
/// This is the shell the rest of Fase 5 grows into — the place card, the search bar and the
/// route sheet all attach here. What it deliberately does *not* do yet is intercept Apple's
/// own points of interest: `mapFeatureSelectionAccessory` stays at its default, so tapping a
/// POI still shows Apple's card. Turning that off before there is a card of our own to put
/// in its place would make the map strictly worse for a commit.
struct MapScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: MapScreenModel?
    @State private var location = LocationProvider()
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: LocationProvider.vigoCentre,
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)))
    @State private var selection: MapSelection<StopID>?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    map(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Mapa")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            if model == nil {
                model = MapScreenModel(repository: environment.repository)
            }
            model?.loadStops()
            location.requestPermissionIfNeeded()
            location.start()
            if let coordinate = location.coordinate {
                camera = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
            }
        }
        .onDisappear { location.stop() }
        .onChange(of: environment.feedStatus.importedAt) { model?.loadStops() }
    }

    @ViewBuilder
    private func map(_ model: MapScreenModel) -> some View {
        Map(position: $camera, selection: $selection) {
            UserAnnotation()
            ForEach(model.layer.stops) { stop in
                Marker(stop.name, systemImage: "bus.fill",
                       coordinate: CLLocationCoordinate2D(latitude: stop.latitude,
                                                          longitude: stop.longitude))
                    .tint(.indigo)
                    .tag(MapSelection(stop.id))
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            model.viewportChanged(to: MapStopsLayer.Viewport(
                centreLatitude: context.region.center.latitude,
                centreLongitude: context.region.center.longitude,
                latitudeSpan: context.region.span.latitudeDelta,
                longitudeSpan: context.region.span.longitudeDelta))
        }
        // A selection that resolves to neither one of our stops nor a map feature is what
        // *deselecting* looks like — MapKit writes an empty `MapSelection` rather than `nil`,
        // as the Fase 5 spike showed on device. Both roads lead to `clearSelection()`.
        .onChange(of: selection) { _, new in
            if let stopID = new?.value {
                model.selectStop(id: stopID)
            } else {
                model.clearSelection()
            }
        }
        .overlay(alignment: .top) { hint(model) }
        .overlay(alignment: .topTrailing) { layersButton(model) }
        .sheet(item: Binding(
            get: { model.selectedStop },
            set: { if $0 == nil { selection = nil; model.clearSelection() } }
        )) { stop in
            NavigationStack {
                StopDetailView(stop: stop, environment: environment)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Only ever shown for "too many to draw". An empty patch of map gets no hint, because
    /// zooming in would not reveal anything.
    @ViewBuilder
    private func hint(_ model: MapScreenModel) -> some View {
        if let count = model.tooManyCount {
            Text("\(count) paradas aquí. Acerca el mapa para verlas.")
                .font(.footnote)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
        }
    }

    private func layersButton(_ model: MapScreenModel) -> some View {
        Menu {
            Toggle(isOn: Binding(get: { model.stopsVisible },
                                 set: { model.stopsVisible = $0 })) {
                Label("Mostrar paradas", systemImage: "bus.fill")
            }
        } label: {
            Image(systemName: model.stopsVisible ? "square.3.layers.3d" : "square.3.layers.3d.slash")
                .font(.title3)
                .padding(9)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("Capas del mapa")
        .padding(.trailing, 10)
        // Clear of MapKit's own controls, which sit on this same edge lower down.
        .padding(.top, 54)
    }
}
