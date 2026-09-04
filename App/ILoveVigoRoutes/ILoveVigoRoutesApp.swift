import SwiftUI
import VigoCore

@main
struct ILoveVigoRoutesApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task {
                    // On a cold start the feed is checked once. There is no background
                    // polling of any kind: these are unofficial public endpoints and the
                    // brief is explicit about not hammering them.
                    await environment.refreshFeed()
                }
        }
    }
}
