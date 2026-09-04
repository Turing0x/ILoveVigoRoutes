import Foundation

/// Rate-limits and de-duplicates calls to an underlying realtime provider.
///
/// These are unofficial endpoints run by a municipality for its own apps. The app polls
/// only while a stop is on screen, never in the background, and this actor enforces that
/// intent: repeat requests for the same stop inside `minimumInterval` reuse the last
/// answer, and concurrent requests for the same stop share one network call.
public actor ThrottledRealtimeProvider: RealtimeArrivalsProviding {
    private let upstream: any RealtimeArrivalsProviding
    private let minimumInterval: TimeInterval
    private let clock: @Sendable () -> Date

    private var lastSnapshot: [VitrasaStopCode: ArrivalsSnapshot] = [:]
    private var inFlight: [VitrasaStopCode: Task<ArrivalsSnapshot, any Error>] = [:]

    public init(
        upstream: any RealtimeArrivalsProviding,
        minimumInterval: TimeInterval = 20,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.upstream = upstream
        self.minimumInterval = minimumInterval
        self.clock = clock
    }

    public func arrivals(for stopCode: VitrasaStopCode) async throws -> ArrivalsSnapshot {
        if let cached = lastSnapshot[stopCode],
           clock().timeIntervalSince(cached.fetchedAt) < minimumInterval {
            return cached
        }
        if let existing = inFlight[stopCode] {
            return try await existing.value
        }

        let task = Task<ArrivalsSnapshot, any Error> { [upstream] in
            try await upstream.arrivals(for: stopCode)
        }
        inFlight[stopCode] = task
        defer { inFlight[stopCode] = nil }

        let snapshot = try await task.value
        lastSnapshot[stopCode] = snapshot
        return snapshot
    }

    /// Drops the throttle for a stop so an explicit pull-to-refresh always hits the network.
    public func invalidate(_ stopCode: VitrasaStopCode) {
        lastSnapshot[stopCode] = nil
    }
}
