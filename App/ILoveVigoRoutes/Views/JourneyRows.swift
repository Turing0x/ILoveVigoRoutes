import SwiftUI
import VigoCore

/// One alternative in the planner's results list: departure, arrival, total time, and a
/// strip of chips — a line badge per ride, a walk icon per walk — so the shape of the
/// journey reads before anyone taps into it.
struct JourneyAlternativeRow: View {
    let journey: Journey
    /// The realtime arrival believed to be this journey's first bus, when there is one.
    ///
    /// Optional, and absent by default, because most of the time there is nothing honest to
    /// say: a query for another day never matches, and neither does a line the source is not
    /// reporting. When it is `nil` the row shows **nothing** rather than a timetable time
    /// wearing a live badge.
    var live: Arrival? = nil

    /// Whether the first bus of this alternative has already left.
    ///
    /// Said out loud rather than left to be worked out by comparing the hour on the row with
    /// the clock. Missing a bus is the ordinary reason a route list stops being true, and it
    /// is the one thing the list could not previously tell anyone.
    var hasDeparted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(journey.departure, style: .time)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                Text(journey.arrival, style: .time)
                Spacer(minLength: 8)
                Text(durationText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            HStack(spacing: 6) {
                ForEach(Array(journey.legs.enumerated()), id: \.offset) { _, leg in
                    legChip(leg)
                }
            }
            HStack(spacing: 6) {
                Text(transfersText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if hasDeparted {
                    Text("Ya ha salido")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if let live {
                    DataKindBadge(kind: live.confidence.hasTrackedVehicle ? .tracked : .estimated,
                                  compact: true)
                    Text("sale \(WaitTime(minutes: live.minutes).inlineText)")
                        .font(.caption2.monospacedDigit())
                }
            }
        }
        .padding(.vertical, 3)
        // `.combine` alone reads the stack as it happens to be laid out: two bare times, a
        // number, and a line badge that is a digit with no noun in front of it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    /// The spoken sentence, with the departed state in front of it.
    ///
    /// First and not appended: the fact that changes whether the rest is worth hearing at all
    /// has to arrive before the rest, not after a list of times.
    private var spokenLabel: String {
        let sentence = JourneySummary.spoken(journey, live: hasDeparted ? nil : live)
        return hasDeparted ? "Ya ha salido. " + sentence : sentence
    }

    private var durationText: String {
        WaitTime(minutes: max(0, Int(journey.duration / 60))).inlineText
    }

    private var transfersText: String {
        switch journey.transfers {
        case ..<1: "Directo"
        case 1: "1 transbordo"
        default: "\(journey.transfers) transbordos"
        }
    }

    @ViewBuilder
    private func legChip(_ leg: JourneyLeg) -> some View {
        switch leg {
        case .walk(_, _, let seconds, _):
            Label("\(max(1, seconds / 60)) min", systemImage: "figure.walk")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .ride(_, let routeShortName, _, _, _, _, _, _, _):
            LineBadge(name: routeShortName)
        }
    }
}

/// One leg, expanded. Drawn by `MapJourneyLegsView` inside the route sheet.
struct JourneyLegRow: View {
    @Environment(AppEnvironment.self) private var environment
    let leg: JourneyLeg

    var body: some View {
        switch leg {
        case .walk(let from, let to, let seconds, let metres):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "figure.walk")
                    .frame(width: 28)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Caminar hasta \(to.label)").font(.subheadline)
                    Text("\(Int(metres.rounded())) m en línea recta · estimado \(max(1, seconds / 60)) min")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Caminar de \(from.label) a \(to.label), \(Int(metres.rounded())) metros"))

        case .ride(_, let routeShortName, let headsign, _, let board, let alight,
                  let departure, let arrival, let intermediateStops):
            HStack(alignment: .top, spacing: 10) {
                LineBadge(name: routeShortName)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(board.name) → \(alight.name)").font(.subheadline).lineLimit(2)
                    if let headsign, !headsign.isEmpty {
                        Text(headsign).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(stopsText(departure: departure, arrival: arrival, intermediateStops: intermediateStops))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            // A ride row names two stops, board and alight, so a single swipe would be
            // ambiguous about which one it favourites. A context menu with two explicit
            // items is the gesture that can only mean one thing.
            .contextMenu {
                Button {
                    environment.favourites.toggle(board)
                } label: {
                    Label(
                        environment.favourites.contains(board.id)
                            ? "Quitar \(board.name) de favoritas" : "Añadir \(board.name) a favoritas",
                        systemImage: environment.favourites.contains(board.id) ? "star.slash" : "star.fill")
                }
                Button {
                    environment.favourites.toggle(alight)
                } label: {
                    Label(
                        environment.favourites.contains(alight.id)
                            ? "Quitar \(alight.name) de favoritas" : "Añadir \(alight.name) a favoritas",
                        systemImage: environment.favourites.contains(alight.id) ? "star.slash" : "star.fill")
                }
            }
        }
    }

    private func stopsText(departure: Date, arrival: Date, intermediateStops: [Stop]) -> String {
        let times = "\(departure.formatted(date: .omitted, time: .shortened)) – "
            + arrival.formatted(date: .omitted, time: .shortened)
        guard !intermediateStops.isEmpty else { return times }
        let count = intermediateStops.count
        return times + " · \(count) parada\(count == 1 ? "" : "s") intermedia\(count == 1 ? "" : "s")"
    }
}
