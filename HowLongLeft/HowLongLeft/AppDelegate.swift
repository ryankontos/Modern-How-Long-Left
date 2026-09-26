import HLLKit
import UIKit
import WidgetKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        HLLBackgroundRefresh.register()
        HLLBackgroundRefresh.schedule()
        // Silent CloudKit subscription pushes require APNs registration, but
        // they do not show an alert or request notification permission.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: session.role)
    }

    /// CloudKit can deliver a remote-change push while no scene is active.
    /// Refresh local EventKit snapshots here so widgets do not wait for the
    /// user to reopen the app after a synced settings change.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            do {
                let runtime = try await HLLRuntime.shared(
                    groupIdentifier: HLLConfiguration.appGroupIdentifier,
                    cloudContainerIdentifier: HLLConfiguration.cloudContainerIdentifier)
                await runtime.engine.invalidate()
                let changed = try await runtime.publishWidgetSnapshot()
                if changed {
                    WidgetCenter.shared.reloadAllTimelines()
                }
                completionHandler(changed ? .newData : .noData)
            } catch {
                completionHandler(.failed)
            }
        }
    }
}
