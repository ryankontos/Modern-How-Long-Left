import CoreData
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
                .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
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
    var calendars: [(id: String, preference: HLLCalendarPreference)] = []
    var hiddenAnnotations: [HLLEventAnnotation] = []
    var needsCalendarAccess = false
    var isLoading = true
    var errorMessage: String?
    private var runtime: HLLRuntime?
    private var revisionTask: Task<Void, Never>?
    private var hasStarted = false

    func currentEvents(at date: Date = .now) -> [HLLEvent] {
        events.filter { $0.isRunning(at: date) }
    }

    func upcomingEvents(at date: Date = .now) -> [HLLEvent] {
        events.filter { $0.start > date }
    }

    func event(withID id: UUID) -> HLLEvent? {
        events.first { $0.id == id }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        // Avoid making a fresh watch install wait for the CloudKit mirror just
        // to show its empty state and calendar access action.
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            needsCalendarAccess = true
            isLoading = false
        }
        Task { [weak self] in
            do {
                let runtime = try await HLLRuntime.shared(
                    groupIdentifier: HLLConfiguration.appGroupIdentifier,
                    cloudContainerIdentifier: HLLConfiguration.cloudContainerIdentifier)
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
                await refresh()
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
            let available = await runtime.eventKit.calendars()
            let bound = try await runtime.repository.bind(available)
            calendars = available.compactMap { info in
                bound[info.localID].map { (id: info.localID, preference: $0) }
            }
            hiddenAnnotations = try await runtime.repository.annotations()
                .filter { $0.kind == .hidden }
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

    func annotate(_ event: HLLEvent, kind: HLLEventAnnotation.Kind,
                  scope: HLLEventAnnotation.Scope) {
        guard let runtime else { return }
        Task {
            do {
                let settings = try await runtime.repository.settings()
                let annotation = HLLEventAnnotation(kind: kind, scope: scope,
                    eventID: event.id, seriesID: event.seriesID,
                    portableKey: event.portableKey, eventTitle: event.title,
                    expiresAt: scope == .occurrence ? event.end.addingTimeInterval(90 * 86_400) : nil,
                    syncAcrossDevices: settings.syncEventAnnotations && event.portableKey != nil)
                try await runtime.engine.save(annotation)
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func removeAnnotation(_ annotation: HLLEventAnnotation) {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.engine.removeAnnotation(id: annotation.id)
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func deleteUserEvent(_ event: HLLEvent) {
        guard event.source == .user, let runtime else { return }
        let definitionID = event.seriesID.flatMap(UUID.init(uuidString:)) ?? event.id
        Task {
            do {
                try await runtime.engine.deleteUserEvent(id: definitionID)
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setCalendarVisibility(_ calendar: HLLCalendarPreference,
                               context: HLLContextID, visible: Bool) {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.engine.setCalendarVisibility(profileID: calendar.id,
                                                                context: context, isVisible: visible)
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
