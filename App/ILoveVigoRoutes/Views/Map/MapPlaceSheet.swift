import SwiftUI
import VigoCore

/// The card for a selected place: what it is, how far it is, and what can be done with it.
///
/// Deliberately the same card for a bus stop, an Apple point of interest and a pressed point
/// — that sameness is the whole feature. What differs is only what a place *can* offer: live
/// arrivals and a favourite star exist for a stop and for nothing else, because they are the
/// only thing the feed knows about.
///
/// "Cómo llegar" is the primary action and sits above everything else, because it is the
/// reason this screen exists.
struct MapPlaceSheet: View {
    @Environment(AppEnvironment.self) private var environment
    let place: MapPlace
    let distanceText: String?
    /// Why routing is unavailable right now, or `nil` when it is available.
    ///
    /// A disabled button with no reason next to it is a dead end; the two states this can
    /// hold — the feed still importing, and no position with no origin pinned — are both
    /// temporary and both worth naming.
    let routeBlockedReason: String?
    let onRoute: () -> Void
    let onClose: () -> Void

    @State private var savingPlace: Place?
    @State private var feed: StopArrivalsFeed?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }

                Section {
                    Button(action: onRoute) {
                        Label("Cómo llegar", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.headline)
                    }
                    .disabled(routeBlockedReason != nil)
                } footer: {
                    if let routeBlockedReason {
                        Text(routeBlockedReason)
                    }
                }

                if let stop = place.stop {
                    Section {
                        StopArrivalsSummary(result: feed?.result)
                    } header: {
                        Text("Próximos pasos")
                    }
                    .task(id: stop.id) {
                        if feed == nil { feed = StopArrivalsFeed(arrivals: environment.arrivals) }
                        await feed?.run(stop: stop)
                    }

                    Section {
                        NavigationLink {
                            StopDetailView(stop: stop, environment: environment)
                        } label: {
                            Label("Ver horario y detalles", systemImage: "clock.arrow.circlepath")
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
