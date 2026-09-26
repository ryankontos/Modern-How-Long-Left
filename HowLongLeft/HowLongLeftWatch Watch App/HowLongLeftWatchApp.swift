import CoreData
import EventKit
import HLLKit
import SwiftUI
import WatchKit
import WidgetKit

final class HLLWatchApplicationDelegate: NSObject, WKApplicationDelegate {
    static let refreshIdentifier = "hll.event-refresh"

    func applicationDidFinishLaunching() {
        WKApplication.shared().registerForRemoteNotifications()
        Self.scheduleEventRefresh()
    }

    /// watchOS grants roughly four refresh opportunities per hour to an app
    /// with an active complication. The requested date is a preference; the
    /// timeline remains correct if the system delays or omits this task.
    static func scheduleEventRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(15 * 60),
            userInfo: refreshIdentifier as NSString
        ) { _ in }
    }

    static func refreshExtensionData() async {
        defer { scheduleEventRefresh() }
        do {
            let runtime = try await HLLRuntime.shared(
                groupIdentifier: HLLConfiguration.appGroupIdentifier,
                cloudContainerIdentifier: HLLConfiguration.cloudContainerIdentifier)
            await runtime.engine.invalidate()
            if try await runtime.publishWidgetSnapshot() {
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch {
            // The next scheduled refresh or foreground launch retries.
        }
    }

    func application(_ application: WKApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void) {
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

@main
struct HowLongLeftWatchApp: App {
    @WKApplicationDelegateAdaptor(HLLWatchApplicationDelegate.self)
    private var applicationDelegate
    @State private var model = WatchEventModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView(model: model)
                .task { model.start() }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                    model.sourceChanged()
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
                    model.sourceChanged()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: Notification.Name.NSSystemClockDidChange)) { _ in
                    model.sourceChanged()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: Notification.Name.NSSystemTimeZoneDidChange)) { _ in
                    model.sourceChanged()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.sourceChanged()
                    } else if phase == .background {
                        HLLWatchApplicationDelegate.scheduleEventRefresh()
                    }
                }
        }
        .backgroundTask(.appRefresh(HLLWatchApplicationDelegate.refreshIdentifier)) { _ in
            await HLLWatchApplicationDelegate.refreshExtensionData()
        }
    }
}
