import SwiftUI
import VigoCore

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = AppTab.map
    /// This view's own lease on the app's single location manager, held only while a bus is
    /// declared. A `UUID` per holder, so it cannot collapse into the map's lease.
    @State private var onboardLocationHolder = LocationDemand.Holder()

    enum AppTab: Hashable { case favourites, map }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Mapa", systemImage: "map.fill", value: AppTab.map) {
                MapScreen()
            }
            // The map is the app now, so it is what opens. Fase 1's criterion — a favourite
            // stop's arrivals in one tap or none from a cold start — still holds: Favoritas
            // is one tap away, and the map answers the question that brings someone here in
            // the first place. Buscar and Cercanas are gone as tabs (Fase 7): both were
            // subsets of what `MapSearchSheet` already covers, plus its own "Cerca de ti"
            // and "Líneas con servicio" sections.
            Tab("Favoritas", systemImage: "star.fill", value: AppTab.favourites) {
                FavouritesView()
            }
        }
        // Above the tab bar, not inside `MapScreen`: the requirement is that this stays
        // visible across tabs, and `MapScreen`'s own `safeAreaInset` is scoped to Mapa alone.
        // One capsule, never two: an onboard ride and an active journey are mutually
        // exclusive states, and the repository makes the transition between them atomic. The
        // onboard branch comes first only because it is the transient one — a ride becomes a
        // journey the moment a plan is accepted.
        .safeAreaInset(edge: .bottom) {
            if let ride = environment.onboardRide.ride {
                OnboardRideBar(
                    ride: ride, staleness: environment.onboardRide.staleness,
                    looksOffRide: environment.onboardRide.looksOffRide,
                    onEnd: { environment.onboardRide.end() })
            } else if let journey = environment.activeJourney.journey {
                ActiveJourneyBar(
                    journey: journey, staleness: environment.activeJourney.staleness,
                    onExtend: { environment.activeJourney.extend() },
                    onEnd: { environment.activeJourney.end() })
            }
        }
        .overlay(alignment: .bottom) {
            if environment.isRefreshing, !environment.hasData {
                FirstImportOverlay()
            }
        }
        // Another tab asked the map to plan something. Switching here rather than inside the
        // asking view keeps the tab selection in the one place that owns it.
        .onChange(of: environment.pendingSavedJourney) { _, journey in
            if journey != nil { selection = .map }
        }
        // A journey started before the phone went to sleep for two hours must not still
        // read `.active` once the app comes back — staleness is only ever recomputed, never
        // ticked on a timer nobody asked for.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                environment.activeJourney.reload()
                environment.onboardRide.reload()
            }
        }
        // The one place the onboard ride is followed. A lease is taken only while a ride is
        // declared, and every new fix is offered to the store, which writes only when a stop
        // was actually passed. Foreground only: the app has no background location mode, which
        // is why the capsule shows the age of what it knows.
        .onChange(of: environment.onboardRide.ride != nil, initial: true) { _, riding in
            if riding {
                environment.location.acquire(onboardLocationHolder, precision: .fine)
            } else {
                environment.location.release(onboardLocationHolder)
            }
        }
        .onChange(of: environment.location.coordinate.map(Coordinate.from)) { _, coordinate in
            guard let coordinate, environment.onboardRide.ride != nil else { return }
            Task { await environment.onboardRide.advance(to: coordinate) }
        }
    }
}

/// Shown only on the very first import, when there is nothing to browse yet.
///
/// Subsequent refreshes stay silent: the old data remains usable throughout, because the
/// importer swaps it in one transaction.
struct FirstImportOverlay: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: environment.importProgress?.fraction ?? 0) {
                Text(stageText).font(.footnote)
            }
            .progressViewStyle(.linear)
            Text("Descargando los horarios del Concello de Vigo. Solo la primera vez.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding()
    }

    private var stageText: String {
        switch environment.importProgress?.stage {
        case .downloading: "Descargando…"
        case .unpacking: "Descomprimiendo…"
        case .parsing: "Leyendo el GTFS…"
        case .validating: "Validando…"
        case .writing: "Guardando…"
        case .done, .none: "Preparando…"
        }
    }
}
