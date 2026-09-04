import Foundation
import Observation
import VigoCore

/// Wires the object graph once and hands it to the views.
///
/// Deliberately plain: one owner, constructed at launch, passed down the environment.
@MainActor
@Observable
final class AppEnvironment {
    let database: AppDatabase
    let repository: TransitRepository
    let arrivals: ArrivalsService
    let feedService: GTFSFeedService
    let planner: JourneyPlanner
    private let timetableStore: TimetableStore
    private let throttledRealtime: ThrottledRealtimeProvider

    /// Progress of the current import, or `nil` when nothing is running.
    private(set) var importProgress: ImportProgress?
    private(set) var importFailure: String?
    private(set) var feedStatus: FeedStatus
    private(set) var lastImportSummary: ImportSummary?
    private(set) var isRefreshing = false

    init() {
        let url = URL.applicationSupportDirectory.appending(path: "ILoveVigoRoutes/transit.sqlite")
        // A database that cannot be opened is unrecoverable, and falling back to an
        // in-memory store would silently lose the user's favourites. Better to crash
        // with the real reason on a personal-use app than to hide it.
        // swiftlint:disable:next force_try
        let db = try! AppDatabase.onDisk(at: url)
        self.database = db
        let repository = TransitRepository(database: db)
        self.repository = repository
        let throttled = ThrottledRealtimeProvider(
            upstream: ConcelloRealtimeClient(), minimumInterval: 20)
        self.throttledRealtime = throttled
        self.arrivals = ArrivalsService(realtime: throttled, repository: repository,
                                        cache: ArrivalsCache(database: db))
        self.feedService = GTFSFeedService(downloader: VitrasaFeedDownloader(),
                                           database: db, repository: repository)
        let timetableStore = TimetableStore(repository: repository)
        self.timetableStore = timetableStore
        self.planner = JourneyPlanner(repository: repository, store: timetableStore)
        self.feedStatus = (try? repository.feedStatus()) ?? .empty

        prewarmTimetable()
    }

    /// Builds today's `Timetable` off the main actor right after launch, so the first real
    /// query — the user's first "Planificar" tap — hits a warm `TimetableStore` instead of
    /// paying the build cost RealFeedTimingTests measures at ~40 ms against the real feed:
    /// small, but no reason to spend it while someone is waiting on a tap.
    private func prewarmTimetable() {
        let store = timetableStore
        let anchor = today
        Task.detached(priority: .utility) {
            _ = try? await store.timetable(anchor: anchor)
        }
    }

    var hasData: Bool { feedStatus.hasData }

    var today: ServiceDate { ServiceDate(Date(), calendar: repository.calendar) }

    /// True when the imported timetable can no longer speak for today. The published feed
    /// only ever covers seven days, so this is a routine state, not an exotic one.
    var timetableOutOfDate: Bool {
        feedStatus.hasData && !feedStatus.covers(today)
    }

    func refreshFeed(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        importFailure = nil
        defer { isRefreshing = false; importProgress = nil }

        do {
            // Parsing and writing 280k rows must not run on the main actor.
            let service = feedService
            let outcome = try await Task.detached(priority: .userInitiated) {
                try await service.refreshIfNeeded(force: force) { progress in
                    Task { @MainActor [weak self] in self?.importProgress = progress }
                }
            }.value

            if case .imported(let summary) = outcome { lastImportSummary = summary }
            feedStatus = (try? repository.feedStatus()) ?? feedStatus
        } catch {
            importFailure = (error as? CustomStringConvertible)?.description
                ?? error.localizedDescription
        }
    }

    /// Forces the next arrivals request for a stop to hit the network.
    func invalidateRealtime(_ code: VitrasaStopCode?) async {
        guard let code else { return }
        await throttledRealtime.invalidate(code)
    }
}
