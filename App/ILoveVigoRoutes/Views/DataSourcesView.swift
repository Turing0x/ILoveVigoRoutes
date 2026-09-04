import SwiftUI
import VigoCore

/// Attribution and provenance, as the ODC-BY licence requires and as the brief demands.
struct DataSourcesView: View {
    @Environment(AppEnvironment.self) private var environment
    var feedStatus: FeedStatus?

    private var status: FeedStatus { feedStatus ?? environment.feedStatus }

    var body: some View {
        List {
            Section("Datos importados") {
                if let importedAt = status.importedAt {
                    row("Importado", importedAt.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("Todavía no se ha importado ningún GTFS.")
                        .foregroundStyle(.secondary)
                }
                if let checked = status.lastCheckedAt {
                    row("Última comprobación", checked.formatted(date: .abbreviated, time: .shortened))
                }
                if let window = status.window {
                    row("Cobertura", "\(window.lowerBound.humanReadable) – \(window.upperBound.humanReadable)")
                    if let remaining = status.daysRemaining(from: environment.today,
                                                            calendar: environment.repository.calendar) {
                        row("Días restantes", remaining >= 0 ? "\(remaining)" : "caducado")
                    }
                }
                if let etag = status.etag { row("ETag", etag) }
                if let modified = status.lastModified { row("Last-Modified", modified) }
            }

            if !status.advisories.isEmpty {
                Section {
                    ForEach(status.advisories, id: \.self) { advisory in
                        Text(advisory).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Avisos del feed")
                } footer: {
                    Text("Observaciones hechas al validar el GTFS. No impiden usarlo.")
                }
            }

            Section {
                Button {
                    Task { await environment.refreshFeed(force: true) }
                } label: {
                    if environment.isRefreshing {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(progressText)
                        }
                    } else {
                        Text("Volver a descargar el GTFS")
                    }
                }
                .disabled(environment.isRefreshing)

                if let failure = environment.importFailure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Se comprueba automáticamente una vez al día y siempre que los datos dejen de cubrir la fecha de hoy.")
            }

            Section {
                link("Concello de Vigo — GTFS de Vitrasa",
                     "Open Data Commons Attribution (ODC-BY)",
                     "https://datos-ckan.vigo.org/dataset/gtfs-vitrasa")
                link("Concello de Vigo — API de tiempo real",
                     "Endpoint no oficial usado por las apps municipales",
                     "https://datos.vigo.org")
            } header: {
                Text("Fuentes")
            } footer: {
                Text("Los horarios y las llegadas proceden del Concello de Vigo. Esta app no está afiliada ni al Concello ni a Vitrasa.")
            }

            Section {
                link("David-Lor/VigoBusAPI", "Apache-2.0", "https://github.com/David-Lor/VigoBusAPI")
                link("arielcostas/infobus-bot", "Documentación de endpoints",
                     "https://github.com/arielcostas/infobus-bot")
            } header: {
                Text("Documentación comunitaria")
            } footer: {
                Text("Los endpoints de tiempo real no están documentados oficialmente. Estos proyectos los dedujeron por ingeniería inversa y sirvieron de referencia para saber a qué llamar y qué esperar de vuelta.")
            }

            Section {
                Text("Uso estrictamente personal. Sin cuentas, sin publicidad, sin telemetría. Lo único que sale del dispositivo son las peticiones a las fuentes de datos y, si buscas una dirección, el texto que escribes, que resuelve Apple Mapas. Tu ubicación nunca se envía.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Fuentes de datos")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var progressText: String {
        guard let progress = environment.importProgress else { return "Actualizando…" }
        let stage = switch progress.stage {
        case .downloading: "Descargando"
        case .unpacking: "Descomprimiendo"
        case .parsing: "Leyendo"
        case .validating: "Validando"
        case .writing: "Guardando"
        case .done: "Listo"
        }
        if let fraction = progress.fraction {
            return "\(stage) \(Int(fraction * 100)) %"
        }
        return stage
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .font(.callout)
        }
    }

    private func link(_ title: String, _ subtitle: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
