import SwiftUI
import MapKit

/// Drop-a-pin-at-the-centre picker, the same idiom `MapScreen` uses for its own
/// camera — a fixed pin and a moving map, rather than a draggable annotation, so there is
/// nothing to hit-test.
struct MapPointPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: LocationProvider.vigoCentre,
        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
    @State private var centre = LocationProvider.vigoCentre
    let onPick: (CLLocationCoordinate2D) -> Void

    var body: some View {
        NavigationStack {
            Map(position: $camera)
                .onMapCameraChange(frequency: .continuous) { context in
                    centre = context.region.center
                }
                .overlay {
                    Image(systemName: "mappin")
                        .font(.title)
                        .foregroundStyle(.red)
                        // The pin's point, not its centre, marks the chosen coordinate.
                        .offset(y: -14)
                }
                .navigationTitle("Elegir en el mapa")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Elegir") { onPick(centre); dismiss() }
                    }
                }
        }
    }
}
