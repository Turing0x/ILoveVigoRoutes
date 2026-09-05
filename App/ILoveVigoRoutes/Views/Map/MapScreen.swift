import SwiftUI
import MapKit
import VigoCore

/// The map tab.
///
/// Replaces `StopsMapView` with the same behaviour plus the one thing the owner asked for
/// first: **the stops are a layer, and the layer is off by default**. A map that opens
/// speckled with 1149 pins is noise; what it should open as is a clean map of Vigo.
///
/// Anything on the map can be selected and becomes a place: one of our stops, one of Apple's
/// points of interest, or any point at all with a long press. All three land in the same
/// card, which is what makes "cualquier lugar disponible" one code path rather than three
/// special cases. Apple's own selection card is switched off (`mapFeatureSelectionAccessory(nil)`)
/// now that there is one of ours to put in its place.
struct MapScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: MapScreenModel?
    @State private var location = LocationProvider()
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: LocationProvider.vigoCentre,
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)))
    @State private var selection: MapSelection<StopID>?
    /// Where the finger is, updated by a simultaneous drag that never consumes the gesture.
    /// `LongPressGesture` cannot report a location on its own; this is the recipe the Fase 5
    /// spike confirmed on device, panning and zooming intact.
    @State private var lastTouch: CGPoint = .zero

    /// `CLLocationCoordinate2D` is not `Equatable`, so `onChange` cannot watch it directly.
    /// `Coordinate` is, and it is the type the rest of the flow speaks anyway.
    private var currentCoordinate: Coordinate? {
        location.coordinate.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

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
                model?.updateCurrentLocation(
                    Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
            }
        }
        .onChange(of: currentCoordinate) { _, new in
            if let new { model?.updateCurrentLocation(new) }
        }
        .onDisappear { location.stop() }
        .onChange(of: environment.feedStatus.importedAt) { model?.loadStops() }
    }

    @ViewBuilder
    private func map(_ model: MapScreenModel) -> some View {
        MapReader { proxy in
            Map(position: $camera, selection: $selection) {
                UserAnnotation()
                ForEach(model.layer.stops) { stop in
                    Marker(stop.name, systemImage: "bus.fill",
                           coordinate: CLLocationCoordinate2D(latitude: stop.latitude,
                                                              longitude: stop.longitude))
                        .tint(.indigo)
                        .tag(MapSelection(stop.id))
                }
                // The selected place gets its own pin unless it already is one of the stop
                // markers above, which would otherwise draw two pins on one spot.
                if let place = model.state.selectedPlace, place.stop == nil {
                    Marker(place.label, systemImage: place.symbolName,
                           coordinate: place.coordinate.clLocation)
                        .tint(.red)
                }
            }
            // Apple draws its own card for a selected point of interest. Ours replaces it.
            .mapFeatureSelectionAccessory(nil)
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
            // Two simultaneous gestures, neither of which consumes the map's own: the drag
            // only records where the finger is, and the long press is what decides. Verified
            // on device in the spike — panning and zooming are untouched.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onChanged { lastTouch = $0.location })
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    guard let coordinate = proxy.convert(lastTouch, from: .local) else { return }
                    // Clearing the map's own selection first: a pressed point is a different
                    // kind of selection, and leaving a stop marker highlighted under a
                    // dropped pin's card is a lie about what the card is showing.
                    selection = nil
                    Task {
                        await model.dropPin(at: Coordinate(latitude: coordinate.latitude,
                                                           longitude: coordinate.longitude))
                    }
                })
            // A selection that resolves to neither one of our stops nor a map feature is what
            // *deselecting* looks like — MapKit writes an empty `MapSelection` rather than
            // `nil`, as the Fase 5 spike showed on device.
            .onChange(of: selection) { _, new in
                if let stopID = new?.value {
                    model.selectStop(id: stopID)
                } else if let feature = new?.feature {
                    model.selectPointOfInterest(
                        title: feature.title,
                        rawCategory: feature.pointOfInterestCategory?.rawValue,
                        coordinate: Coordinate(latitude: feature.coordinate.latitude,
                                               longitude: feature.coordinate.longitude))
                } else {
                    model.clearSelection()
                }
            }
            .onChange(of: model.state.selectedPlace) { _, place in
                if let place { focus(on: place) }
            }
            .overlay(alignment: .top) { hint(model) }
            .overlay(alignment: .topTrailing) { layersButton(model) }
            .sheet(item: Binding(
                get: { model.state.selectedPlace },
                set: { if $0 == nil { dismissSelection(model) } }
            )) { place in
                MapPlaceSheet(place: place,
                              distanceText: model.distanceText(to: place)) {
                    dismissSelection(model)
                }
                .presentationDetents([.height(sheetPeek), .fraction(sheetFraction), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(sheetFraction)))
                .presentationDragIndicator(.visible)
            }
        }
    }

    /// Height of the smallest detent, and the share of the screen the medium one covers.
    /// The second is what the camera has to compensate for.
    private let sheetPeek: CGFloat = 180
    private let sheetFraction: CGFloat = 0.45

    private func dismissSelection(_ model: MapScreenModel) {
        selection = nil
        model.clearSelection()
    }

    /// Centres on a place, lifted clear of the sheet.
    ///
    /// MapKit does not reframe for a sheet, so centring on the coordinate puts the pin behind
    /// the card. Moving the camera's centre *south* — to a lower latitude — slides the fixed
    /// pin towards the top of the screen, by the share of it the sheet covers.
    private func focus(on place: MapPlace) {
        let span = MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
        let lift = span.latitudeDelta * sheetFraction / 2
        camera = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: place.coordinate.latitude - lift,
                                           longitude: place.coordinate.longitude),
            span: span))
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
