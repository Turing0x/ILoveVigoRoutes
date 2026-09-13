import SwiftUI
import VigoCore

/// Los próximos pasos de una parada, resumidos, con su procedencia.
///
/// Extraído de `FavouriteStopCard`, que era el único sitio con esta distinción antes de que
/// `MapPlaceSheet` también necesitara mostrar llegadas. Un solo lugar para las tres fuentes
/// —realtime, caché, sin datos— porque la distinción es la tesis de la app y no puede
/// divergir entre pantallas.
struct StopArrivalsSummary: View {
    let result: StopArrivals?
    var limit: Int = 3

    var body: some View {
        if let result {
            switch result.source {
            case .realtime(let at):
                if result.arrivals.isEmpty {
                    fallbackRows(result.scheduled, note: "Sin pasos previstos ahora mismo.")
                } else {
                    ForEach(result.arrivals.prefix(limit)) { CompactArrivalRow(arrival: $0, fetchedAt: at) }
                }
            case .cache(let at, let failure):
                Text(failure)
                    .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                ForEach(result.arrivals.prefix(limit)) {
                    CompactArrivalRow(arrival: $0,
                                      overrideKind: .cached(age: Date().timeIntervalSince(at)),
                                      fetchedAt: at)
                }
            case .unavailable(let failure):
                Text(failure)
                    .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                fallbackRows(result.scheduled, note: nil)
            }
        } else {
            HStack { ProgressView().controlSize(.mini); Text("Consultando…").font(.caption) }
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func fallbackRows(_ scheduled: [ScheduledDeparture], note: String?) -> some View {
        if let note {
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }
        if scheduled.isEmpty {
            Text("Tampoco hay horario teórico disponible.")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            ForEach(scheduled.prefix(limit)) { CompactScheduledRow(departure: $0) }
        }
    }
}

struct CompactArrivalRow: View {
    let arrival: Arrival
    var overrideKind: DataKind?
    /// When the source produced `arrival`, so the minutes shown count down with the clock
    /// instead of repeating the source's number until the next refresh.
    var fetchedAt: Date?

    private var kind: DataKind {
        overrideKind ?? (arrival.confidence.hasTrackedVehicle ? .tracked : .estimated)
    }

    private var minutes: Int {
        fetchedAt.map { arrival.minutes(at: Date(), fetchedAt: $0) } ?? arrival.minutes
    }

    var body: some View {
        HStack(spacing: 8) {
            LineBadge(name: arrival.rawLine)
            Text(arrival.destination).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            DataKindBadge(kind: kind, compact: true)
            Text(WaitTime(minutes: minutes).compactText)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(kind.tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Línea \(arrival.rawLine), \(WaitTime(minutes: minutes).spoken), \(kind.label)"))
    }
}

struct CompactScheduledRow: View {
    let departure: ScheduledDeparture

    var body: some View {
        HStack(spacing: 8) {
            LineBadge(name: departure.routeShortName)
            Text(departure.destination).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            DataKindBadge(kind: .timetable, compact: true)
            Text(departure.departure.clockDescription)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.blue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("""
            Línea \(departure.routeShortName), horario teórico \(departure.departure.clockDescription)
            """))
    }
}
