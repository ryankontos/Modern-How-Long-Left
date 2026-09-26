import CoreData
import EventKit
import HLLKit
import Observation
import SwiftUI
import UserNotifications
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

/// A watch runtime reads only calendars provided by watchOS EventKit.
@MainActor @Observable
final class WatchEventModel {
    var events: [HLLEvent] = []
    /// Pre-partitioned arrays keep the watch list body free of collection work.
    /// They change only at an event boundary or after a source refresh.
    var currentEvents: [HLLEvent] = []
    var upcomingEvents: [HLLEvent] = []
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
    private var boundaryTask: Task<Void, Never>?
    private var sourceChangeTask: Task<Void, Never>?
    private var hasStarted = false

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
        let quickSnapshot = Task.detached(priority: .userInitiated) {
            let payload = HLLWidgetSnapshotStore(
                groupIdentifier: HLLConfiguration.appGroupIdentifier).read()
            let now = Date()
            return payload?.launchSnapshot(query: HLLEventQuery(
                interval: DateInterval(start: now.addingTimeInterval(-86_400),
                                       end: now.addingTimeInterval(14 * 86_400)),
                rule: .upcoming(now), context: "watch.main"))
        }
        Task { [weak self] in
            guard let snapshot = await quickSnapshot.value else { return }
            guard let self, self.isLoading else { return }
            self.apply(snapshot.events, at: .now)
            self.calendars = snapshot.calendars.map { ($0.id.uuidString, $0) }
            self.hiddenAnnotations = snapshot.hiddenAnnotations
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
                    let changed = !self.purchaseSnapshot.hasSameEntitlements(as: snapshot)
                    self.purchaseSnapshot = snapshot
                    if changed {
                        WidgetCenter.shared.reloadAllTimelines()
                        await self.reconcileNotifications(using: runtime)
                    }
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
        sourceChangeTask?.cancel()
        sourceChangeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await runtime.engine.invalidate()
        }
    }

    func refresh() async {
        guard let runtime else { return }
        do {
            let now = Date()
            let interval = DateInterval(start: now.addingTimeInterval(-86_400),
                                        end: now.addingTimeInterval(14 * 86_400))
            let query = HLLEventQuery(interval: interval, rule: .upcoming(now), context: "watch.main")
            let refreshedEvents = try await runtime.engine.query(query, now: now).events
            let available = await runtime.eventKit.calendars()
            let bound = try await runtime.repository.bind(available)
            calendars = available.compactMap { info in
                bound[info.localID].map { (id: info.localID, preference: $0) }
            }
            hiddenAnnotations = try await runtime.repository.annotations()
                .filter { $0.kind == .hidden }
            notificationPreferences = try await runtime.repository.notificationPreferences()
            needsCalendarAccess = await runtime.eventKit.authorizationStatus() != .fullAccess
            apply(refreshedEvents, at: now)
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

    /// Reclassifies an already-loaded array in memory. An event starting or
    /// ending should update the UI immediately without reopening EventKit,
    /// Core Data, CloudKit, or StoreKit.
    private func apply(_ newEvents: [HLLEvent], at date: Date) {
        events = newEvents
        currentEvents = newEvents.filter { $0.status(at: date) == .inProgress }
        upcomingEvents = newEvents.filter { $0.status(at: date) == .upcoming }
        scheduleNextBoundary(after: date)
    }

    private func scheduleNextBoundary(after date: Date) {
        boundaryTask?.cancel()
        guard let next = events.lazy.flatMap({ [$0.start, $0.end] })
            .filter({ $0 > date }).min() else { return }
        boundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, next.timeIntervalSinceNow + 0.05)))
            guard !Task.isCancelled, let self else { return }
            self.apply(self.events, at: .now)
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
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func removeAnnotation(_ annotation: HLLEventAnnotation) {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.engine.removeAnnotation(id: annotation.id)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func deleteUserEvent(_ event: HLLEvent) {
        guard event.source == .user, let runtime else { return }
        let definitionID = event.seriesID.flatMap(UUID.init(uuidString:)) ?? event.id
        Task {
            do {
                try await runtime.engine.deleteUserEvent(id: definitionID)
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
