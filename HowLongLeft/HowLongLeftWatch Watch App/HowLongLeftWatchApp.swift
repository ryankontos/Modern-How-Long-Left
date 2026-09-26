import EventKit
import HLLKit
import Observation
import SwiftUI
import WidgetKit

@main
struct HowLongLeftWatchApp: App {
    @State private var model = WatchEventModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView(model: model)
                .task { model.start() }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                    model.sourceChanged()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.sourceChanged() }
                }
        }
    }
}

/// A watch runtime reads only calendars provided by watchOS EventKit.
@MainActor @Observable
final class WatchEventModel {
    var events: [HLLEvent] = []
    var needsCalendarAccess = false
    var isLoading = true
    var errorMessage: String?
    private var runtime: HLLRuntime?
    private var revisionTask: Task<Void, Never>?

    func start() {
        guard runtime == nil else { return }
        Task { [weak self] in
            do {
                let runtime = try await HLLRuntime.shared(
                    groupIdentifier: "group.com.ryan.HowLongLeft",
                    cloudContainerIdentifier: "iCloud.com.ryan.HowLongLeft")
                guard let self else { return }
                self.runtime = runtime
                revisionTask = Task { [weak self] in
                    for await _ in await runtime.engine.changes() { await self?.refresh() }
                }
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.isLoading = false
            }
        }
    }

    func requestCalendarAccess() {
        guard let runtime else { return }
        Task {
            do {
                needsCalendarAccess = !(try await runtime.eventKit.requestAccess())
                await runtime.engine.invalidate()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func sourceChanged() {
        guard let runtime else { return }
        Task { await runtime.engine.invalidate() }
    }

    func refresh() async {
        guard let runtime else { return }
        do {
            let now = Date()
            let interval = DateInterval(start: now.addingTimeInterval(-86_400),
                                        end: now.addingTimeInterval(14 * 86_400))
            let query = HLLEventQuery(interval: interval, rule: .upcoming(now), context: "watch.main")
            events = try await runtime.engine.query(query, now: now).events
            needsCalendarAccess = await runtime.eventKit.authorizationStatus() != .fullAccess
            isLoading = false
            if try await runtime.publishWidgetSnapshot() {
                WidgetCenter.shared.reloadTimelines(ofKind: "HowLongLeftComplications")
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}
