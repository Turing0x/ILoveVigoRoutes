import UIKit
import VigoCore

/// Owns `AppEnvironment` and registers the background refresh task.
///
/// `AppEnvironment` lives here rather than as a `@State` on `ILoveVigoRoutesApp` because
/// `BGTaskScheduler.register(forTaskWithIdentifier:using:handler:)` must be called before
/// `application(_:didFinishLaunchingWithOptions:)` returns — the one point in the app's
/// lifecycle that is documented to run that early. `ILoveVigoRoutesApp` reads `environment`
/// from here via `@UIApplicationDelegateAdaptor` instead of constructing its own.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let environment = AppEnvironment()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRefresh.register(environment: environment)
        return true
    }
}
