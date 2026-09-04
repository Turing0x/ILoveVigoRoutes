import SwiftUI
import VigoCore

struct SearchView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @State private var results: [Stop] = []
    @State private var routes: [Route] = []

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section("Líneas con servicio") {
                        ForEach(routes) { route in
                            HStack(spacing: 10) {
                                LineBadge(name: route.shortName,
                                          colorHex: route.colorHex,
                                          textColorHex: route.textColorHex)
                                Text(route.longName).font(.subheadline).lineLimit(2)
                            }
                        }
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(results) { stop in
                        NavigationLink {
                            StopDetailView(stop: stop, environment: environment)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(stop.name).font(.subheadline).lineLimit(2)
                                if let code = stop.vitrasaCode {
                                    Text("Parada \(code.value)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Buscar")
            // Searching runs straight against SQLite on each keystroke; measured at
            // 0.2 ms over the real 1149-stop table, so there is nothing to debounce.
            .searchable(text: $query, prompt: "Nombre de la parada o su número")
            .onChange(of: query) { runSearch() }
            .task {
                routes = (try? environment.repository.routesWithService()) ?? []
            }
        }
    }

    private func runSearch() {
        results = (try? environment.repository.searchStops(query)) ?? []
    }
}
