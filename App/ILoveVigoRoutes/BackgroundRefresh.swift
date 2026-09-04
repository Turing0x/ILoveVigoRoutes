import Foundation
import BackgroundTasks
import VigoCore

/// Schedules and runs the GTFS feed check in the background.
///
/// The published feed only ever covers seven days (`README.md` §"Decisión sobre la
/// estrategia de GTFS"), so a cold-start-only check is fragile — miss enough launches and
/// the timetable goes silently out of date. This is opportunistic, not a replacement: the
/// cold-start check in `ILoveVigoRoutesApp` stays as the correctness backstop, because iOS
/// is free to never run a background task at all.
///
/// `BGProcessingTask`, not `BGAppRefreshTask`: the work is a ~16 MB download, unzip, parse
/// and a single transaction writing ~280k rows (`GTFSImporter`, `AppDatabase`) — far past
/// what an app-refresh window's few seconds can finish, and a truncated run would fail
/// mid-transaction rather than simply not happening. `requiresNetworkConnectivity = true`;
/// `requiresExternalPower = false`, because requiring power would mean long stretches with
/// no refresh at all on a feed that expires in a week.
///
/// Covers only the GTFS feed — the unofficial realtime endpoints are still never polled in
/// the background, by design.
enum BackgroundRefresh {
    static let taskID = "dev.threedots.ILoveVigoRoutes.refreshFeed"

    /// Registers the task handler. Must run before `application(_:didFinishLaunchingWithOptions:)`
    /// returns, which is why this is called from `AppDelegate` rather than from a SwiftUI
    /// `.task` — a view's `.task` is not guaranteed to run in time, and BGTaskScheduler
    /// requires the handler to be registered before the app finishes launching. `AppDelegate`
    /// is the sole owner of `AppEnvironment` for exactly this reason: it exists and is fully
    /// constructed by the time `didFinishLaunchingWithOptions` fires, with no ordering
    /// dependency on when SwiftUI gets around to building `WindowGroup`'s content.
    static func register(environment: AppEnvironment) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // `BGProcessingTask` predates Swift concurrency and is not `Sendable`, but
            // BGTaskScheduler hands it to this closure exactly once and nothing else
            // touches it concurrently — safe to carry across the hop to `@MainActor`,
            // which `handle` needs in order to touch `AppEnvironment`.
            nonisolated(unsafe) let capturedTask = processingTask
            Task { @MainActor in
                await handle(capturedTask, environment: environment)
            }
        }
    }

    /// Submits (or re-submits) a request. BGTaskScheduler keeps at most one pending request
    /// per identifier, so calling this again simply replaces the earlier one.
    static func schedule(earliestAfter interval: TimeInterval = 6 * 3600) {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        // Scheduling can fail (simulator, task not registered, etc.); there is nothing
        // actionable to do about it besides not crashing — the cold-start check remains
        // the backstop either way.
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    private static func handle(_ task: BGProcessingTask, environment: AppEnvironment) async {
        let work = Task {
            // Not `force: true`: `GTFSFeedService.shouldCheck` already encodes the right
            // policy for an opportunistic run (24 h interval, overridden once the window
            // no longer covers today or expires within a day), and `AppEnvironment`'s own
            // `isRefreshing` guard keeps this from racing a user-initiated refresh.
            await environment.refreshFeed()
        }

        task.expirationHandler = {
            // Best-effort: `refreshFeed` runs its import on `Task.detached`, which does not
            // inherit this task's cancellation, so an import already in flight keeps
            // running rather than stopping instantly. That is safe regardless — the
            // importer writes in one transaction (`GTFSImporter`), so a process kill
            // mid-import rolls back to the previous, still-intact feed on the next launch,
            // exactly as an interrupted foreground refresh already does today.
            work.cancel()
        }

        _ = await work.value
        task.setTaskCompleted(success: !work.isCancelled)
        schedule()
    }
}
