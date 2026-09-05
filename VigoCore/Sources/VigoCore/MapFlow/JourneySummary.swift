import Foundation

/// One journey, said out loud.
///
/// `JourneyAlternativeRow` already collapses itself into a single accessibility element, but
/// without a label of its own VoiceOver reads whatever the stack happens to contain — two
/// bare times, a duration, and a line badge whose text is a number with no noun in front of
/// it ("17"). What someone actually needs is the sentence a person would say.
///
/// Lives here, and takes its locale and time zone as parameters, so `swift test` can pin both
/// and check the wording instead of leaving it to be eyeballed on a device.
public enum JourneySummary {

    /// A sentence describing the journey, for VoiceOver.
    ///
    /// - Parameter live: the realtime annotation, when there is one. Absent by default,
    ///   because most of the time there is nothing honest to add — and when there is nothing,
    ///   the sentence says nothing about it rather than implying a timetable time is live.
    public static func spoken(_ journey: Journey, live: Arrival? = nil,
                              locale: Locale = Locale(identifier: "es_ES"),
                              timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"

        var parts: [String] = []
        if isWalkOnly(journey) {
            parts.append("A pie")
        } else {
            parts.append("Sale a las \(formatter.string(from: journey.departure))")
            parts.append("llega a las \(formatter.string(from: journey.arrival))")
        }
        parts.append(minutesText(Int((journey.duration / 60).rounded())))

        if !isWalkOnly(journey) {
            parts.append(transfersText(journey.transfers))
            let lines = rideLines(journey)
            if !lines.isEmpty {
                parts.append(lines.count == 1
                             ? "línea \(lines[0])"
                             : "líneas \(lines.joined(separator: ", "))")
            }
        }

        if let live {
            // The provenance is part of the sentence, not decoration: the badge that carries
            // it visually has no text of its own.
            let kind = live.confidence.hasTrackedVehicle ? "en vivo" : "estimado"
            parts.append("\(kind), sale en \(minutesText(live.minutes))")
        }

        return parts.joined(separator: ", ") + "."
    }

    static func isWalkOnly(_ journey: Journey) -> Bool {
        journey.legs.allSatisfy { if case .walk = $0 { true } else { false } }
    }

    static func rideLines(_ journey: Journey) -> [String] {
        journey.legs.compactMap { leg in
            if case .ride(_, let routeShortName, _, _, _, _, _, _, _) = leg { routeShortName }
            else { nil }
        }
    }

    static func transfersText(_ transfers: Int) -> String {
        switch transfers {
        case ..<1: "directo"
        case 1: "1 transbordo"
        default: "\(transfers) transbordos"
        }
    }

    static func minutesText(_ minutes: Int) -> String {
        let value = Swift.max(0, minutes)
        return value == 1 ? "1 minuto" : "\(value) minutos"
    }
}
