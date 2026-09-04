import SwiftUI
import VigoCore

@main
struct ILoveVigoRoutesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.environment)
                .task {
                    // On a cold start the feed is always checked — this is the correctness
                    // backstop, since `BackgroundRefresh`'s opportunistic run may never fire
                    // (iOS is free to skip it entirely). Covers only the GTFS feed; the
                    // unofficial realtime endpoints are still never polled in the
                    // background, by design.
                    await appDelegate.environment.refreshFeed()
                    BackgroundRefresh.schedule()
                }
        }
    }
}
