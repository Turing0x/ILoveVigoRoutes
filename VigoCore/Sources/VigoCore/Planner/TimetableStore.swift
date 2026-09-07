import Foundation

/// Caches built `Timetable` snapshots, keyed by anchor day, mobility profile, and the feed's
/// own `importedAt` — a snapshot built before a refresh describes a timetable that no longer
/// exists, and the fingerprint in the key makes sure a stale one is never handed out.
///
/// The default capacity is six rather than three because the profile joined the key (C3):
/// three days' worth of snapshots for each of the two profiles, so switching between them
/// does not evict the day the user is looking at.
///
/// The second actor in the package, alongside `ThrottledRealtimeProvider`, but a plainer
/// one: `TimetableBuilder.build` has no suspension point inside it, so — unlike the
/// realtime provider's network call — there is no window during which the actor would go
/// reentrant and let two callers start building the same snapshot at once. Actor isolation
/// alone already gives "two concurrent requests wait for one build"; no `inFlight` bookkeeping
/// is needed on top of it.
///
/// The cost of that same fact (H-12): `build` is synchronous and its SQLite reads are
/// blocking, so a cache miss ties up one of the cooperative pool's threads for its whole
/// duration — measured at 108.6 ms against the real feed. Swift 6 generally asks actors not
/// to do this. Left as is for now: the pool has more threads than this ever needs at once,
/// and the alternative (moving the build to a dedicated thread and resuming a continuation)
/// is worth doing only if this number grows enough to matter.
public actor TimetableStore {
    private let repository: TransitRepository
    private let options: PlannerOptions
    private let capacity: Int
    /// An explicit override, or `nil` to use the measured table for whichever profile is
    /// asked for. Tests inject `.empty` here; the app passes nothing.
    private let footpaths: FootpathTable?
    private let holidays: HolidayCalendar

    private struct CacheKey: Hashable {
        let anchor: ServiceDate
        let feedFingerprint: Date?
        /// C3. Two profiles produce genuinely different timetables — 62 of the measured
        /// transfers exist on foot and not in a wheelchair — so a snapshot built for one is
        /// wrong for the other. Without this in the key the second profile to ask would be
        /// served the first one's footpaths, silently.
        let profile: AccessibilityProfile
    }

    private var snapshots: [CacheKey: Timetable] = [:]
    /// Most-recently-used last, so eviction drops the actual least-recently-used entry
    /// rather than an arbitrary one.
    private var recency: [CacheKey] = []

    public init(repository: TransitRepository, options: PlannerOptions = PlannerOptions(),
                capacity: Int = 6, footpaths: FootpathTable? = nil,
                holidays: HolidayCalendar = .bundled) {
        self.repository = repository
        self.options = options
        self.capacity = capacity
        self.footpaths = footpaths
        self.holidays = holidays
    }

    public func timetable(anchor: ServiceDate,
                          profile: AccessibilityProfile = .standard) throws -> Timetable {
        let fingerprint = try repository.feedStatus().importedAt
        let key = CacheKey(anchor: anchor, feedFingerprint: fingerprint, profile: profile)

        if let cached = snapshots[key] {
            touch(key)
            return cached
        }

        var profileOptions = options
        profileOptions.accessibility = profile
        let built = try TimetableBuilder(repository: repository, options: profileOptions,
                                         footpaths: footpaths ?? .bundled(for: profile),
                                         holidays: holidays).build(anchor: anchor)
        snapshots[key] = built
        touch(key)
        while recency.count > capacity {
            snapshots[recency.removeFirst()] = nil
        }
        return built
    }

    /// Drops every cached snapshot. The fingerprint in the key already stops a stale
    /// snapshot from being served after a refresh; this is only for freeing the memory of
    /// snapshots that are now guaranteed never to be asked for again.
    public func invalidateAll() {
        snapshots.removeAll()
        recency.removeAll()
    }

    private func touch(_ key: CacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
