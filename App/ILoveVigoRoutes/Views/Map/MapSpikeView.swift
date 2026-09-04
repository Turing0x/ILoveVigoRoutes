#if DEBUG
import SwiftUI
import MapKit
import UIKit
import VigoCore

/// Paso 0 de la Fase 5 — sonda desechable. **Este fichero se borra al terminar el paso 0.**
///
/// No es producto y no debe convertirse en producto: existe solo para contestar en un
/// dispositivo real las cuatro preguntas de MapKit que la interfaz del SDK no puede
/// responder. Todo lo que aquí se aprenda se reescribe limpio en `MapScreen` (paso 3).
///
/// Las cuatro preguntas, con lo que ya se sabe leyendo
/// `_MapKit_SwiftUI.swiftinterface` del SDK instalado:
///
/// 1. **Selección mixta.** `MapSelection<StopID>` compila como tipo de selección (conforma
///    `MapSelectable`, iOS 18+). Falta saber si en vivo llega `.value` al tocar un `Marker`
///    etiquetado y `.feature` al tocar un POI de Apple, por la *misma* binding.
/// 2. **Tarjeta nativa.** `.mapFeatureSelectionAccessory(nil)` existe. Falta saber si de
///    verdad apaga la tarjeta que Apple pinta sola al seleccionar un POI: si no la apaga,
///    la nuestra saldría encima de la suya.
/// 3. **Coordenada de una pulsación larga.** `MapProxy.convert(_:from:)` existe. Falta
///    saber si el gesto convive con el paneo del mapa (receta A) o si hay que caer a la
///    retícula central (receta B, que se sabe segura porque `MapPointPickerView` ya la usa).
/// 4. **Hoja sobre el mapa.** Falta saber si con `presentationBackgroundInteraction` el
///    mapa se sigue moviendo en el detente pequeño, y confirmar que la hoja tapa la TabBar.
///
/// Cada pregunta tiene su respuesta en el panel de abajo. El botón "Copiar informe" deja
/// todo en el portapapeles para pegarlo tal cual.
struct MapSpikeView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Receta para dar coordenada a un punto tocado.
    enum PinMode: String, CaseIterable, Identifiable {
        /// Pulsación larga sobre el mapa, con la posición tomada de un `DragGesture`
        /// simultáneo. Mejor si funciona: es el gesto que la gente ya conoce.
        case longPress = "A · pulsación larga"
        /// Retícula fija en el centro y botón. Seguro, pero un paso más.
        case crosshair = "B · retícula central"
        var id: Self { self }
    }

    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: LocationProvider.vigoCentre,
        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
    @State private var region = MKCoordinateRegion(
        center: LocationProvider.vigoCentre,
        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))

    // P1 y P2
    @State private var selection: MapSelection<StopID>?
    @State private var nativeAccessory = false
    @State private var stopsVisible = true
    @State private var allStops: [Stop] = []

    // P3
    @State private var pinMode: PinMode = .longPress
    @State private var lastTouch: CGPoint = .zero
    @State private var droppedPin: CLLocationCoordinate2D?

    // P4
    @State private var showingSheet = false
    @State private var detent: PresentationDetent = .fraction(0.45)

    @State private var log: [String] = []

    var body: some View {
        MapReader { proxy in
            map(proxy)
        }
        .navigationTitle("Sonda MapKit")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { panel }
        // La sonda ocupa la pantalla entera: con la TabBar visible no se puede comprobar
        // si la hoja la tapa (P4), que es justo una de las preguntas.
        .toolbar(.hidden, for: .tabBar)
        .task {
            if allStops.isEmpty {
                allStops = (try? environment.repository.allStops()) ?? []
                note("Paradas cargadas: \(allStops.count)")
            }
        }
        .sheet(isPresented: $showingSheet) { sheet }
    }

    // MARK: - Mapa

    private func map(_ proxy: MapProxy) -> some View {
        Map(position: $camera, selection: $selection) {
            UserAnnotation()

            if stopsVisible {
                ForEach(visibleStops) { stop in
                    Marker(stop.name, systemImage: "bus.fill",
                           coordinate: CLLocationCoordinate2D(latitude: stop.latitude,
                                                              longitude: stop.longitude))
                        .tint(.indigo)
                        .tag(MapSelection(stop.id))
                }
            }

            if let droppedPin {
                Marker("Punto", systemImage: "mappin", coordinate: droppedPin)
                    .tint(.red)
            }
        }
        // P2: con `nil` se pide a MapKit que NO pinte su propia tarjeta al seleccionar un
        // POI. El conmutador del panel permite compararlo en vivo con `.automatic`.
        .mapFeatureSelectionAccessory(nativeAccessory ? .automatic : nil)
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            region = context.region
        }
        // P3 receta A. `simultaneousGesture` para no robarle el paneo al mapa: el drag solo
        // anota dónde está el dedo, y la pulsación larga es la que decide.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if pinMode == .longPress { lastTouch = value.location }
                }
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    guard pinMode == .longPress else { return }
                    guard let coordinate = proxy.convert(lastTouch, from: .local) else {
                        note("P3·A: convert() devolvió nil en \(Int(lastTouch.x)),\(Int(lastTouch.y))")
                        return
                    }
                    droppedPin = coordinate
                    note("P3·A: pulsación larga → \(format(coordinate))")
                }
        )
        .overlay { crosshair }
        .onChange(of: selection) { _, new in describeSelection(new) }
    }

    private var visibleStops: [Stop] {
        let latitudes = (region.center.latitude - region.span.latitudeDelta / 2)
            ... (region.center.latitude + region.span.latitudeDelta / 2)
        let longitudes = (region.center.longitude - region.span.longitudeDelta / 2)
            ... (region.center.longitude + region.span.longitudeDelta / 2)
        return Array(allStops.lazy.filter {
            latitudes.contains($0.latitude) && longitudes.contains($0.longitude)
        }.prefix(80))
    }

    @ViewBuilder
    private var crosshair: some View {
        if pinMode == .crosshair {
            Image(systemName: "plus.viewfinder")
                .font(.largeTitle)
                .foregroundStyle(.red)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Panel de respuestas

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Punto", selection: $pinMode) {
                ForEach(PinMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if pinMode == .crosshair {
                Button {
                    droppedPin = region.center
                    note("P3·B: retícula → \(format(region.center))")
                } label: {
                    Label("Fijar el punto del centro", systemImage: "mappin.and.ellipse")
                        .font(.footnote)
                }
            }

            HStack(spacing: 14) {
                Toggle("Paradas", isOn: $stopsVisible)
                Toggle("Tarjeta nativa", isOn: $nativeAccessory)
            }
            .font(.footnote)
            .toggleStyle(.switch)

            Button {
                showingSheet = true
                note("P4: hoja presentada")
            } label: {
                Label("Presentar la hoja (P4)", systemImage: "rectangle.bottomthird.inset.filled")
                    .font(.footnote)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 132)

            HStack {
                Button("Copiar informe") {
                    UIPasteboard.general.string = report
                }
                Spacer()
                Button("Limpiar") { log.removeAll() }
            }
            .font(.caption)
        }
        .padding(12)
        .background(.regularMaterial)
    }

    // MARK: - Hoja (P4)

    private var sheet: some View {
        NavigationStack {
            List {
                Section("Qué comprobar aquí") {
                    Text("1 · Con la hoja en el detente pequeño, ¿se puede mover el mapa con el dedo?")
                    Text("2 · ¿La hoja tapa la barra de pestañas? (se espera que sí)")
                    Text("3 · Subida del todo, ¿el mapa deja de responder? (se espera que sí)")
                }
                Section("Estado") {
                    LabeledContent("Detente", value: detentName)
                }
                Section {
                    Button("Anotar que el mapa SÍ se movía") {
                        note("P4: mapa manipulable en detente \(detentName)")
                    }
                    Button("Anotar que el mapa NO se movía") {
                        note("P4: mapa BLOQUEADO en detente \(detentName)")
                    }
                }
            }
            .navigationTitle("Hoja de prueba")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { showingSheet = false }
                }
            }
        }
        .presentationDetents([.height(120), .fraction(0.45), .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
    }

    private var detentName: String {
        switch detent {
        case .large: "grande"
        case .height(120): "pequeño (120)"
        default: "medio (0,45)"
        }
    }

    // MARK: - Lectura de la selección (P1)

    private func describeSelection(_ selection: MapSelection<StopID>?) {
        guard let selection else {
            note("P1: selección vacía")
            return
        }
        if let stopID = selection.value {
            let name = allStops.first { $0.id == stopID }?.name ?? "¿?"
            note("P1: .value → parada \(stopID.rawValue) · \(name)")
        }
        if let feature = selection.feature {
            let category = feature.pointOfInterestCategory?.rawValue ?? "sin categoría"
            note("P1: .feature → \(feature.title ?? "sin título") · \(category) · \(format(feature.coordinate))")
        }
        if selection.value == nil, selection.feature == nil {
            note("P1: selección no vacía pero sin .value ni .feature (!)")
        }
    }

    // MARK: - Utilidades

    private func note(_ text: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("\(stamp)  \(text)")
    }

    private func format(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private var report: String {
        """
        Sonda MapKit — Fase 5, paso 0
        iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)
        Receta de punto: \(pinMode.rawValue) · tarjeta nativa: \(nativeAccessory ? "ON" : "OFF")

        \(log.joined(separator: "\n"))
        """
    }
}
#endif
