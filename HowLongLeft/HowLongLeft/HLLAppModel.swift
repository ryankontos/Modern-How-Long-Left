import EventKit
import Foundation
import HLLKit
import Observation
import UIKit
import WidgetKit

/// The main actor owns presentation state. HLLKit actors do source and disk work.
@MainActor @Observable
final class HLLAppModel {
    var events: [HLLEvent] = []
    var calendars: [(id: String, preference: HLLCalendarPreference)] = []
    var hiddenAnnotations: [HLLEventAnnotation] = []
    var annotationSyncEnabled = true
    var activityPolicies: [HLLLiveActivityPolicy] = []
    var widgetDefaults = HLLWidgetDefaults()
    var activeActivityEventKeys: Set<String> = []
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
        // Permission status is cheap to read and does not require opening the
        // CloudKit mirror. Show the empty shell immediately on a fresh install
        // while the user decides whether to grant calendar access.
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            needsCalendarAccess = true
            isLoading = false
        }
        // The last App Group projection is a local, atomic file. Read it
        // directly for the first frame instead of waiting for CloudKit or
        // opening EventKit. The runtime performs the authoritative refresh
        // immediately afterward and publishes a newer projection.
        let quickEvents = Task.detached(priority: .userInitiated) {
            let payload = HLLWidgetSnapshotStore(
                groupIdentifier: HLLConfiguration.appGroupIdentifier).read()
            let now = Date()
            return payload?.query(HLLEventQuery(
                interval: DateInterval(start: now.addingTimeInterval(-86_400),
                                       end: now.addingTimeInterval(30 * 86_400)),
                rule: .upcoming(now), context: "home.main"))
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
                    await self.reconcileLiveActivities(using: runtime)
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
            do {
                purchaseProducts = try await runtime.purchases.products()
            } catch {
                purchaseErrorMessage = error.localizedDescription
            }
        }
    }

    func purchase(productID: String) {
        guard let runtime else { return }
        Task {
            do {
                purchaseSnapshot = try await runtime.purchases.purchase(productID: productID)
            } catch HLLPurchaseError.userCancelled {
                // Cancellation is a normal end to the sheet, not an app error.
            } catch {
                purchaseErrorMessage = error.localizedDescription
            }
        }
    }

    func restorePurchases() {
        guard let runtime else { return }
        Task {
            do {
                purchaseSnapshot = try await runtime.purchases.restorePurchases()
            } catch {
                purchaseErrorMessage = error.localizedDescription
            }
        }
    }

    func sourceChanged() {
        guard let runtime else { return }
        Task { await runtime.engine.invalidate() }
    }

    func refresh(publishWidgets: Bool = true) async {
        guard let runtime else { return }
        do {
            let now = Date()
            let interval = DateInterval(start: now.addingTimeInterval(-86_400),
                                        end: now.addingTimeInterval(30 * 86_400))
            let query = HLLEventQuery(interval: interval, rule: .upcoming(now), context: "home.main")
            let snapshot = try await runtime.engine.query(query, now: now)
            events = snapshot.events
            let available = await runtime.eventKit.calendars()
            let bound = try await runtime.repository.bind(available)
            calendars = available.compactMap { info in
                bound[info.localID].map { (id: info.localID, preference: $0) }
            }
            hiddenAnnotations = try await runtime.repository.annotations()
                .filter { $0.kind == .hidden }
            annotationSyncEnabled = try await runtime.repository.settings().syncEventAnnotations
            activityPolicies = try await runtime.repository.activityPolicies()
            widgetDefaults = try await runtime.repository.widgetDefaults()
            needsCalendarAccess = await runtime.eventKit.authorizationStatus() != .fullAccess
            isLoading = false
            scheduleNextBoundary(now: now)
            if publishWidgets, try await runtime.publishWidgetSnapshot() {
                WidgetCenter.shared.reloadTimelines(ofKind: "HowLongLeftWidgets")
            }
            await reconcileLiveActivities(using: runtime)
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func scheduleNextBoundary(now: Date) {
        boundaryTask?.cancel()
        guard let next = events.flatMap({ [$0.start, $0.end] }).filter({ $0 > now }).min() else { return }
        boundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSince(now) + 0.1)))
            guard !Task.isCancelled else { return }
            await self?.refresh(publishWidgets: false)
        }
    }

    func addUserEvent(title: String, start: Date, duration: TimeInterval,
                      isAllDay: Bool = false, recurrence: HLLRecurrenceRule?) {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.engine.save(HLLUserEvent(title: title, start: start,
                                                            duration: duration, isAllDay: isAllDay,
                                                            recurrence: recurrence))
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// User occurrences are generated from one definition. Deleting any
    /// occurrence removes that definition; hiding remains available when the
    /// user wants to skip only one occurrence of a repeating event.
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

    func annotate(_ event: HLLEvent, kind: HLLEventAnnotation.Kind,
                  scope: HLLEventAnnotation.Scope) {
        guard let runtime else { return }
        Task {
            do {
                let settings = try await runtime.repository.settings()
                let canSync = event.portableKey != nil
                let annotation = HLLEventAnnotation(kind: kind, scope: scope,
                    eventID: event.id, seriesID: event.seriesID,
                    portableKey: event.portableKey, eventTitle: event.title,
                    expiresAt: scope == .occurrence ? event.end.addingTimeInterval(90 * 86_400) : nil,
                    syncAcrossDevices: settings.syncEventAnnotations && canSync)
                try await runtime.engine.save(annotation)
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
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func removeAnnotation(_ annotation: HLLEventAnnotation) {
        guard let runtime else { return }
        Task {
            do { try await runtime.engine.removeAnnotation(id: annotation.id) }
            catch { errorMessage = error.localizedDescription }
            await refresh()
        }
    }

    func setAnnotationSync(_ enabled: Bool) {
        guard let runtime else { return }
        annotationSyncEnabled = enabled
        Task {
            do { try await runtime.engine.setAnnotationSync(enabled) }
            catch { errorMessage = error.localizedDescription }
            await refresh()
        }
    }

    func setWidgetDefaults(_ defaults: HLLWidgetDefaults) {
        guard let runtime else { return }
        widgetDefaults = defaults
        Task {
            do { try await runtime.repository.save(defaults) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func startActivity(for event: HLLEvent) {
        guard let runtime else { return }
        guard isFeatureUnlocked(.liveActivities) else {
            purchaseErrorMessage = "Live Activities are available with How Long Left Premium."
            return
        }
        Task {
            do {
                try await runtime.liveActivities.start(event)
                activeActivityEventKeys = await runtime.liveActivities.activeEventKeys()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func stopActivity(for event: HLLEvent) {
        guard let runtime else { return }
        Task {
            await runtime.liveActivities.stop(event)
            activeActivityEventKeys = await runtime.liveActivities.activeEventKeys()
        }
    }

    func isActivityRunning(for event: HLLEvent) -> Bool {
        activeActivityEventKeys.contains(event.portableKey ?? event.id.uuidString)
    }

    func isAutomaticallyTracking(_ target: HLLLiveActivityPolicy.Target) -> Bool {
        activityPolicies.contains { $0.target == target }
    }

    func setAutomaticTracking(_ target: HLLLiveActivityPolicy.Target, enabled: Bool) {
        guard let runtime else { return }
        guard !enabled || isFeatureUnlocked(.liveActivities) else {
            purchaseErrorMessage = "Live Activities are available with How Long Left Premium."
            return
        }
        Task {
            do {
                if enabled {
                    if !isAutomaticallyTracking(target) {
                        try await runtime.repository.save(HLLLiveActivityPolicy(target: target))
                    }
                } else {
                    for policy in activityPolicies where policy.target == target {
                        try await runtime.repository.deleteActivityPolicy(id: policy.id)
                    }
                }
                activityPolicies = try await runtime.repository.activityPolicies()
                await reconcileLiveActivities(using: runtime)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func reconcileLiveActivities(using runtime: HLLRuntime) async {
        do {
            let mayStart = UIApplication.shared.applicationState == .active
            try await runtime.liveActivities.reconcile(mayStart: mayStart)
            activeActivityEventKeys = await runtime.liveActivities.activeEventKeys()
        } catch { errorMessage = error.localizedDescription }
    }
}
