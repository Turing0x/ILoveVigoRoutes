import SwiftUI
import VigoCore

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selection = AppTab.favourites

    enum AppTab: Hashable { case favourites, nearby, planner, search, map }

    var body: some View {
        TabView(selection: $selection) {
            // Favourites first, deliberately: the acceptance criterion is that seeing a
            // favourite stop's arrivals from a cold start takes one tap or none.
            Tab("Favoritas", systemImage: "star.fill", value: AppTab.favourites) {
                FavouritesView()
            }
            Tab("Cercanas", systemImage: "location.fill", value: AppTab.nearby) {
                NearbyView()
            }
            Tab("Planificar", systemImage: "arrow.triangle.turn.up.right.diamond",
                value: AppTab.planner) {
                NavigationStack { PlannerPlaceholderView() }
            }
            Tab("Buscar", systemImage: "magnifyingglass", value: AppTab.search) {
                SearchView()
            }
            Tab("Mapa", systemImage: "map.fill", value: AppTab.map) {
                StopsMapView()
            }
        }
        .overlay(alignment: .bottom) {
            if environment.isRefreshing, !environment.hasData {
                FirstImportOverlay()
            }
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

/// Stands in for the real `PlannerView` until it exists — this step is only the tab's
/// wiring, not its screen.
struct PlannerPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Planificar", systemImage: "arrow.triangle.turn.up.right.diamond")
        } description: {
            Text("La pantalla de planificación de rutas llega en el próximo paso.")
        }
        .navigationTitle("Planificar")
    }
}
