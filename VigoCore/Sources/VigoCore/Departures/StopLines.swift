import Foundation

extension Arrival {
    /// Minutes to wait as of `now`, for a prediction the source made at `fetchedAt`.
    ///
    /// The source says "7 minutes" at the instant it answers. Between the 20 s throttle and the
    /// 30 s refresh a screen can show that answer for close to a minute, and an undiscounted
    /// "7" then runs a minute behind InfoBus at the post. Whole minutes elapsed only, never
    /// below zero, and a clock behind `fetchedAt` changes nothing rather than adding time.
    public func minutes(at now: Date, fetchedAt: Date) -> Int {
        let elapsed = max(0, Int((now.timeIntervalSince(fetchedAt) / 60).rounded(.down)))
        return max(0, minutes - elapsed)
    }
}

/// Every line at a stop, each with the bus that comes next.
///
/// The answer to "I am at this stop — what passes here, and when is the next one of each?".
/// One row per line rather than one per arrival: the realtime source gives up to a couple of
/// passes per line and the timetable a dozen, and neither list says at a glance which lines
/// the post serves at all.
public enum StopLines {

    /// The next bus of a line, and where that claim comes from.
    ///
    /// Two cases and not a single time with a flag, so a view cannot draw a timetable
    /// departure with the live styling by forgetting to check.
    public enum NextBus: Sendable, Hashable {
        case live(Arrival, minutes: Int)
        case scheduled(ScheduledDeparture, minutes: Int)

        public var minutes: Int {
            switch self {
            case .live(_, let minutes), .scheduled(_, let minutes): minutes
            }
        }

        public var destination: String {
            switch self {
            case .live(let arrival, _): arrival.destination
            case .scheduled(let departure, _): departure.destination
            }
        }
    }

    public struct Line: Sendable, Hashable, Identifiable {
        /// `nil` for a line the realtime source reports and the timetable does not know —
        /// kept anyway, because a real arrival is never dropped for failing to match.
        public let route: Route?
        /// The label to draw: the route's short name, or the source's raw line.
        public let name: String
        /// Live passes of this line, soonest first, with their minutes already discounted.
        public let live: [LiveArrival]
        /// First timetabled departure at or after `now`.
        public let nextScheduled: ScheduledDeparture?
        public let next: NextBus?

        public var id: String { route?.id.rawValue ?? "live:\(name)" }
    }

    public struct LiveArrival: Sendable, Hashable, Identifiable {
        public let arrival: Arrival
        public let minutes: Int
        public var id: String { arrival.id }
    }

    /// - Parameters:
    ///   - fetchedAt: when the realtime answer was produced; `nil` when `arrivals` is empty
    ///     or not realtime, in which case nothing is discounted.
    ///   - scheduled: the stop's upcoming timetable, any line, any order.
    public static func build(routes: [Route],
                             arrivals: [Arrival],
                             fetchedAt: Date?,
                             scheduled: [ScheduledDeparture],
                             now: Date) -> [Line] {
        let live: [LiveArrival] = arrivals.map { arrival in
            LiveArrival(arrival: arrival,
                        minutes: fetchedAt.map { arrival.minutes(at: now, fetchedAt: $0) }
                            ?? arrival.minutes)
        }
        .sorted { $0.minutes < $1.minutes }

        let upcoming = scheduled
            .filter { $0.absoluteDate >= now }
            .sorted { $0.absoluteDate < $1.absoluteDate }

        func minutesUntil(_ date: Date) -> Int {
            max(0, Int((date.timeIntervalSince(now) / 60).rounded(.down)))
        }

        func line(route: Route?, name: String, code: String) -> Line {
            let passes = live.filter { $0.arrival.normalizedLine == code }
            let nextScheduled = upcoming.first {
                TextNormalization.normalizedLineName($0.routeShortName) == code
            }
            let next: NextBus? = if let first = passes.first {
                .live(first.arrival, minutes: first.minutes)
            } else if let nextScheduled {
                .scheduled(nextScheduled, minutes: minutesUntil(nextScheduled.absoluteDate))
            } else {
                nil
            }
            return Line(route: route, name: name, live: passes,
                        nextScheduled: nextScheduled, next: next)
        }

        var lines = routes.map {
            line(route: $0, name: $0.shortName,
                 code: TextNormalization.normalizedLineName($0.shortName))
        }

        let known = Set(routes.map { TextNormalization.normalizedLineName($0.shortName) })
        var orphans: [String: String] = [:]
        for pass in live where !known.contains(pass.arrival.normalizedLine) {
            orphans[pass.arrival.normalizedLine] = orphans[pass.arrival.normalizedLine]
                ?? pass.arrival.rawLine
        }
        lines += orphans.map { code, raw in line(route: nil, name: raw, code: code) }

        return lines.sorted { a, b in
            switch (a.next, b.next) {
            case let (x?, y?) where x.minutes != y.minutes: x.minutes < y.minutes
            case (.some, nil): true
            case (nil, .some): false
            default: TransitRepository.lineNameOrdering(a.name, b.name)
            }
        }
    }
}
