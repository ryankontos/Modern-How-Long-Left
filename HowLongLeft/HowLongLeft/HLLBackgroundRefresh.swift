import BackgroundTasks
import HLLKit
import WidgetKit

/// Registers one small iOS background refresh task for extension data.
///
/// Widget timelines already contain known start/end transitions. This task is
/// an extra opportunity to discover edits made in Calendar while the app is
/// closed. iOS owns the schedule and may defer it to protect battery life.
enum HLLBackgroundRefresh {
    static let identifier = "com.ryankontos.How-Long-Left.event-refresh"

    /// Registration must finish before application launch returns.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    /// Submitting again is harmless: the system keeps at most one pending task
    /// for this identifier. A failure simply leaves WidgetKit timelines as the
    /// freshness path until the next foreground launch.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task {
            do {
                let runtime = try await HLLRuntime.shared(
                    groupIdentifier: HLLConfiguration.appGroupIdentifier,
                    cloudContainerIdentifier: HLLConfiguration.cloudContainerIdentifier)
                await runtime.engine.invalidate()
                if try await runtime.publishWidgetSnapshot() {
                    WidgetCenter.shared.reloadAllTimelines()
                }
                task.setTaskCompleted(success: !Task.isCancelled)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
}
