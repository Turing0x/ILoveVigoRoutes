import Foundation

/// Where the arrivals on screen actually came from.
///
/// The UI is required to render these three states differently. Presenting a timetable or
/// a stale cache as if it were live is the specific dishonesty this app exists to avoid.
public enum ArrivalsSource: Sendable, Hashable {
    /// Fetched from the realtime source just now.
    case realtime(fetchedAt: Date)
    /// The realtime source failed; showing the last good response instead.
    case cache(fetchedAt: Date, failure: String)
    /// No realtime data at all; only the timetable is available.
    case unavailable(failure: String)

    public var isRealtime: Bool { if case .realtime = self { true } else { false } }
}

/// Everything needed to render a stop honestly.
public struct StopArrivals: Sendable {
    public let stop: Stop
    public let arrivals: [Arrival]
    public let source: ArrivalsSource
    /// Timetabled departures, always computed so there is something to fall back to.
    public let scheduled: [ScheduledDeparture]
    public let feedStatus: FeedStatus
    /// True when the timetable cannot speak for the current day because the feed's
    /// seven-day window has run out. "No departures" and "no data" are different answers.
    public let outsideFeedWindow: Bool
}

/// Combines the realtime source, a persistent cache and the timetable into one answer,
/// and is explicit about which of the three the caller is looking at.
public struct ArrivalsService: Sendable {
    let realtime: any RealtimeArrivalsProviding
    let repository: TransitRepository
    let cache: ArrivalsCache
    /// How old a cached response may be before it stops being worth showing.
    let maximumCacheAge: TimeInterval

    public init(realtime: any RealtimeArrivalsProviding,
                repository: TransitRepository,
                cache: ArrivalsCache,
                maximumCacheAge: TimeInterval = 15 * 60) {
        self.realtime = realtime
        self.repository = repository
        self.cache = cache
        self.maximumCacheAge = maximumCacheAge
    }

    public func arrivals(for stop: Stop, now: Date = Date()) async -> StopArrivals {
        let feedStatus = (try? repository.feedStatus()) ?? .empty
        let today = ServiceDate(now, calendar: repository.calendar)
        let scheduled = (try? repository.scheduledDepartures(stopID: stop.id, from: now)) ?? []
        let outsideWindow = feedStatus.hasData && !feedStatus.covers(today)

        func result(_ arrivals: [Arrival], _ source: ArrivalsSource) -> StopArrivals {
            StopArrivals(stop: stop, arrivals: arrivals, source: source,
                         scheduled: scheduled, feedStatus: feedStatus,
                         outsideFeedWindow: outsideWindow)
        }

        guard let code = stop.vitrasaCode else {
            return result([], .unavailable(
                failure: RealtimeError.noRealtimeIdentifier(stop.id).description))
        }

        do {
            let snapshot = try await realtime.arrivals(for: code)
            try? cache.store(snapshot)
            return result(snapshot.arrivals, .realtime(fetchedAt: snapshot.fetchedAt))
        } catch {
            let message = (error as? RealtimeError)?.description ?? error.localizedDescription
            if let cached = try? cache.load(code),
               now.timeIntervalSince(cached.fetchedAt) <= maximumCacheAge {
                return result(cached.arrivals,
                              .cache(fetchedAt: cached.fetchedAt, failure: message))
            }
            return result([], .unavailable(failure: message))
        }
    }
}
