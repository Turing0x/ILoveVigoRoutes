import SwiftUI
import VigoCore

/// The card for a selected place: what it is, how far it is, and what can be done with it.
///
/// Deliberately the same card for a bus stop, an Apple point of interest and a pressed point
/// — that sameness is the whole feature. What differs is only what a place *can* offer: live
/// arrivals and a favourite star exist for a stop and for nothing else, because they are the
/// only thing the feed knows about.
///
/// "Cómo llegar" is **not here yet**: it arrives with the route sheet, and a button that
/// leads nowhere would be worse than its absence for the one commit in between.
struct MapPlaceSheet: View {
    @Environment(AppEnvironment.self) private var environment
    let place: MapPlace
    let distanceText: String?
    let onClose: () -> Void

    @State private var savingPlace: Place?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }

                if let stop = place.stop {
                    Section {
                        NavigationLink {
                            StopDetailView(stop: stop, environment: environment)
                        } label: {
                            Label("Ver llegadas", systemImage: "clock.arrow.circlepath")
                        }
                        Button {
                            environment.favourites.toggle(stop)
                        } label: {
                            Label(
                                environment.favourites.contains(stop.id)
                                    ? "Quitar de favoritas" : "Añadir a favoritas",
                                systemImage: environment.favourites.contains(stop.id)
                                    ? "star.slash" : "star.fill")
                        }
                    }
                }

                Section {
                    Button {
                        savingPlace = place.place
                    } label: {
                        Label("Guardar como lugar", systemImage: "mappin.circle")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(place.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar", action: onClose)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { savingPlace != nil },
            set: { if !$0 { savingPlace = nil } }
        )) {
            if let savingPlace {
                SavedPlaceEditorView(mode: .createFrom(savingPlace))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: place.symbolName)
                .font(.title2)
                .foregroundStyle(.indigo)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(place.label).font(.headline).lineLimit(2)
                if let subtitle = place.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if let distanceText {
                    // "En línea recta" is not padding: this app has no street graph, and
                    // every other distance it shows carries the same caveat.
                    Text("A \(distanceText) en línea recta")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
