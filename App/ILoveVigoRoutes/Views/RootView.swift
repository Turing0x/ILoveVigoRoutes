import SwiftUI
import VigoCore

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = AppTab.map

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
        .safeAreaInset(edge: .bottom) {
            if let journey = environment.activeJourney.journey {
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
            if phase == .active { environment.activeJourney.reload() }
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
