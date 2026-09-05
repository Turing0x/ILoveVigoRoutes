import SwiftUI
import VigoCore

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selection = AppTab.map

    enum AppTab: Hashable { case favourites, nearby, search, map }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Mapa", systemImage: "map.fill", value: AppTab.map) {
                MapScreen()
            }
            // The map is the app now, so it is what opens. Fase 1's criterion — a favourite
            // stop's arrivals in one tap or none from a cold start — still holds: Favoritas
            // is one tap away, and the map answers the question that brings someone here in
            // the first place.
            Tab("Favoritas", systemImage: "star.fill", value: AppTab.favourites) {
                FavouritesView()
            }
            Tab("Buscar", systemImage: "magnifyingglass", value: AppTab.search) {
                SearchView()
            }
            Tab("Cercanas", systemImage: "location.fill", value: AppTab.nearby) {
                NearbyView()
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
