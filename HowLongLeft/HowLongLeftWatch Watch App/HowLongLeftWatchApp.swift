import CoreData
import EventKit
import HLLKit
import Observation
import SwiftUI
import UserNotifications
import WatchKit
import WidgetKit

final class HLLWatchApplicationDelegate: NSObject, WKApplicationDelegate {
    func application(_ application: WKApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void) {
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
    var notificationPreferences = HLLNotificationPreferences(context: "watch.notifications")
    var purchaseSnapshot = HLLPurchaseSnapshot.locked(configuration: .shipping)
    var purchaseProducts: [HLLStoreProduct] = []
    var purchaseErrorMessage: String?
    var needsCalendarAccess = false
    var isLoading = true
    var errorMessage: String?
    private var runtime: HLLRuntime?
    private var revisionTask: Task<Void, Never>?
    private var purchaseTask: Task<Void, Never>?
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
        let quickEvents = Task.detached(priority: .userInitiated) {
            let payload = HLLWidgetSnapshotStore(
                groupIdentifier: HLLConfiguration.appGroupIdentifier).read()
            let now = Date()
            return payload?.query(HLLEventQuery(
                interval: DateInterval(start: now.addingTimeInterval(-86_400),
                                       end: now.addingTimeInterval(14 * 86_400)),
                rule: .and([.source(.user), .upcoming(now)]), context: "watch.main"))
        }
        Task { [weak self] in
            guard let events = await quickEvents.value else { return }
            guard let self, self.isLoading else { return }
            self.events = events
            self.isLoading = false
        }
        Task { [weak self] in
            do {
                let runtime = try await HLLRuntime.shared(
                    groupIdentifier: HLLConfiguration.appGroupIdentifier,
                    cloudContainerIdentifier: HLLConfiguration.cloudContainerIdentifier)
                guard let self else { return }
                await self.attach(runtime)
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.isLoading = false
            }
        }
    }

    func requestCalendarAccess() {
        Task {
            do {
                let runtime = try await HLLRuntime.shared(
                    groupIdentifier: HLLConfiguration.appGroupIdentifier,
                    cloudContainerIdentifier: HLLConfiguration.cloudContainerIdentifier)
                await attach(runtime)
                needsCalendarAccess = !(try await runtime.eventKit.requestAccess())
                await runtime.engine.invalidate()
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func attach(_ runtime: HLLRuntime) async {
        self.runtime = runtime
        needsCalendarAccess = await runtime.eventKit.authorizationStatus() != .fullAccess
        await runtime.purchases.start()
        if revisionTask == nil {
            revisionTask = Task { [weak self] in
                for await _ in await runtime.engine.changes() { await self?.refresh() }
            }
        }
        if purchaseTask == nil {
            purchaseTask = Task { [weak self] in
                for await snapshot in await runtime.purchases.changes() {
                    guard let self else { return }
                    self.purchaseSnapshot = snapshot
                    WidgetCenter.shared.reloadAllTimelines()
                    await self.reconcileNotifications(using: runtime)
                }
            }
        }
    }

    func isFeatureUnlocked(_ feature: HLLPaidFeature) -> Bool {
        purchaseSnapshot.isUnlocked(feature)
    }

    func loadPurchaseProducts() {
        guard let runtime else { return }
        Task {
            do { purchaseProducts = try await runtime.purchases.products() }
            catch { purchaseErrorMessage = error.localizedDescription }
        }
    }

    func purchase(productID: String) {
        guard let runtime else { return }
        Task {
            do { purchaseSnapshot = try await runtime.purchases.purchase(productID: productID) }
            catch HLLPurchaseError.userCancelled { }
            catch { purchaseErrorMessage = error.localizedDescription }
        }
    }

    func restorePurchases() {
        guard let runtime else { return }
        Task {
            do { purchaseSnapshot = try await runtime.purchases.restorePurchases() }
            catch { purchaseErrorMessage = error.localizedDescription }
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
            notificationPreferences = try await runtime.repository.notificationPreferences()
            needsCalendarAccess = await runtime.eventKit.authorizationStatus() != .fullAccess
            isLoading = false
            if try await runtime.publishWidgetSnapshot() {
                WidgetCenter.shared.reloadTimelines(ofKind: "HowLongLeftComplications")
            }
            await reconcileNotifications(using: runtime)
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

    /// Personal events are stored in the same CloudKit-backed repository as
    /// iPhone-created events, so a watch-created event can appear on every
    /// device without requiring the iPhone to be reachable.
    func addUserEvent(title: String, start: Date, duration: TimeInterval,
                      isAllDay: Bool = false, recurrence: HLLRecurrenceRule?) {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.engine.save(HLLUserEvent(title: title, start: start,
                                                            duration: duration,
                                                            isAllDay: isAllDay,
                                                            recurrence: recurrence))
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setNotificationPreferences(_ preferences: HLLNotificationPreferences) {
        guard let runtime else { return }
        guard !preferences.enabled || isFeatureUnlocked(.notifications) else {
            purchaseErrorMessage = "Notifications are available with How Long Left Premium."
            return
        }
        Task {
            do {
                if preferences.enabled {
                    guard try await runtime.notifications.requestAuthorization() else {
                        notificationPreferences.enabled = false
                        errorMessage = "Notifications are disabled in Settings."
                        return
                    }
                }
                var saved = preferences
                saved.updatedAt = .now
                try await runtime.repository.save(saved)
                notificationPreferences = saved
                await reconcileNotifications(using: runtime)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func reconcileNotifications(using runtime: HLLRuntime) async {
        let options = HLLNotificationScheduler.ScheduleOptions(
            notifyAtStart: notificationPreferences.notifyAtStart,
            notifyAtEnd: notificationPreferences.notifyAtEnd,
            includeAllDay: notificationPreferences.includeAllDay)
        do {
            let visibleEvents = notificationPreferences.enabled ? self.events : []
            try await runtime.notifications.reconcile(events: visibleEvents, options: options)
        } catch { errorMessage = error.localizedDescription }
    }
}
