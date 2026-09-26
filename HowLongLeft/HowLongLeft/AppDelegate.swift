import HLLKit
import UIKit
import WidgetKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: session.role)
    }

    /// CloudKit can deliver a remote-change push while no scene is active.
    /// Refresh the small extension projection here so widgets do not wait for
    /// the user to reopen the app after a synced change.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            do {
                let runtime = try await HLLRuntime.shared(
                    groupIdentifier: HLLConfiguration.appGroupIdentifier,
                    cloudContainerIdentifier: HLLConfiguration.cloudContainerIdentifier)
                await runtime.engine.invalidate()
                if try await runtime.publishWidgetSnapshot() {
                    WidgetCenter.shared.reloadAllTimelines()
                }
                completionHandler(.newData)
            } catch {
                completionHandler(.failed)
            }
        }
    }
}
