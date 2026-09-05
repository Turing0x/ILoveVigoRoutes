import SwiftUI
import VigoCore

/// The four kinds of number this app can put on screen.
///
/// They are deliberately modelled as one enum with distinct colours, icons and words,
/// because the whole point is that a user glancing at the screen can tell them apart
/// without reading. A minute count with no provenance attached is not allowed to exist.
enum DataKind {
    /// A vehicle is being tracked and the source gave its distance.
    case tracked
    /// The source answered, but reported no vehicle position.
    case estimated
    /// The last good answer, replayed because the source is unreachable.
    case cached(age: TimeInterval)
    /// The published timetable.
    case timetable

    var label: String {
        switch self {
        case .tracked: "En vivo"
        case .estimated: "Estimado"
        case .cached(let age): "Caché · \(Self.ageText(age))"
        case .timetable: "Horario"
        }
    }

    var symbol: String {
        switch self {
        case .tracked: "dot.radiowaves.left.and.right"
        case .estimated: "clock.badge.questionmark"
        case .cached: "clock.arrow.circlepath"
        case .timetable: "calendar"
        }
    }

    var tint: Color {
        switch self {
        case .tracked: .green
        case .estimated: .orange
        case .cached: .gray
        case .timetable: .blue
        }
    }

    /// One line explaining exactly what the number means. Shown in the detail view so the
    /// distinction is spelled out, not merely colour-coded.
    var explanation: String {
        switch self {
        case .tracked:
            "El sistema tiene localizado el autobús."
        case .estimated:
            "La fuente no informa de la posición de ningún autobús. Probablemente sea el horario previsto."
        case .cached(let age):
            "Última respuesta buena, de hace \(Self.ageText(age)). El tiempo real no responde ahora mismo."
        case .timetable:
            "Horario publicado en el GTFS. No refleja retrasos ni adelantos."
        }
    }

    static func ageText(_ age: TimeInterval) -> String {
        let minutes = Int(age / 60)
        guard minutes >= 1 else { return "menos de 1 min" }
        return WaitTime(minutes: minutes).inlineText
    }
}

/// A wait time in minutes, split into hours once it passes 60.
///
/// The realtime source has returned waits of up to ~176 minutes for buses not
/// yet in service (see `DATA-SOURCES.md` §3.7); showing that as a bare
/// three-digit minute count is unreadable at a glance.
struct WaitTime {
    let minutes: Int

    private var hours: Int { minutes / 60 }
    private var remainder: Int { minutes % 60 }
    private var isOverAnHour: Bool { minutes >= 60 }

    /// The big number for a stacked value/unit badge: "9", "2 h 21", "2 h", "ya".
    var badgeValue: String {
        guard minutes > 0 else { return "ya" }
        guard isOverAnHour else { return "\(minutes)" }
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder)"
    }

    /// The caption under `badgeValue`, or nil when the value already speaks for
    /// itself ("ya", or an exact hour like "2 h").
    var badgeUnit: String? {
        guard minutes > 0 else { return nil }
        guard isOverAnHour else { return "min" }
        return remainder == 0 ? nil : "min"
    }

    /// Single-line form with the prime mark already used in the favourites card:
    /// "9′", "2 h 21′", "2 h".
    var compactText: String {
        guard minutes > 0 else { return "ya" }
        guard isOverAnHour else { return "\(minutes)′" }
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder)′"
    }

    /// A single spelled-out string: "9 min", "2 h 21 min", "2 h".
    var inlineText: String {
        guard isOverAnHour else { return "\(minutes) min" }
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
    }

    /// Phrased for VoiceOver: "9 minutos", "2 horas y 21 minutos".
    var spoken: String {
        guard isOverAnHour else { return minutes == 1 ? "1 minuto" : "\(minutes) minutos" }
        let hoursText = hours == 1 ? "1 hora" : "\(hours) horas"
        guard remainder > 0 else { return hoursText }
        let remainderText = remainder == 1 ? "1 minuto" : "\(remainder) minutos"
        return "\(hoursText) y \(remainderText)"
    }
}

struct DataKindBadge: View {
    let kind: DataKind
    var compact = false

    var body: some View {
        Label {
            Text(kind.label)
        } icon: {
            Image(systemName: kind.symbol)
        }
        .font(.caption2.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 2 : 3)
        .background(kind.tint.opacity(0.15), in: Capsule())
        .foregroundStyle(kind.tint)
        .accessibilityLabel(Text(kind.label))
        .accessibilityHint(Text(kind.explanation))
    }
}

/// Line number, coloured with the route's own colour from the feed.
struct LineBadge: View {
    let name: String
    var colorHex: String?
    var textColorHex: String?

    var body: some View {
        Text(name)
            .font(.footnote.weight(.bold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(minWidth: 38)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(hex: colorHex) ?? .accentColor, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(Color(hex: textColorHex) ?? .white)
            .accessibilityLabel(Text("Línea \(name)"))
    }
}

/// Banner explaining that realtime is down. Shown instead of, never behind, the numbers.
struct RealtimeFailureBanner: View {
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sin tiempo real")
                    .font(.subheadline.weight(.semibold))
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Banner shown when the imported timetable can no longer answer for today.
///
/// The published feed covers seven days. Without this, "no hay salidas" would be
/// indistinguishable from "no tengo datos de hoy", which is a different and much more
/// misleading statement.
struct StaleFeedBanner: View {
    let status: FeedStatus
    let today: ServiceDate
    var onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Horarios caducados")
                    .font(.subheadline.weight(.semibold))
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Actualizar ahora", action: onRefresh)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private var explanation: String {
        guard let window = status.window else {
            return "No hay horarios importados."
        }
        return """
        Los datos descargados cubren del \(window.lowerBound.humanReadable) al \
        \(window.upperBound.humanReadable), y hoy es \(today.humanReadable). \
        No hay horario teórico para hoy: lo que se muestre viene del tiempo real.
        """
    }
}

extension Color {
    /// Parses the `RRGGBB` values the feed uses in `route_color`.
    init?(hex: String?) {
        guard var hex else { return nil }
        hex = hex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
