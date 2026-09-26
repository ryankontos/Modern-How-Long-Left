import EventKit
import HLLKit
import Observation
import WidgetKit

/// Main-actor presentation state for the watch. EventKit, Core Data, CloudKit,
/// StoreKit, and notification work stays behind HLLKit actors.
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
    /// A newer refresh wins if multiple classification tasks overlap.
    private var classificationGeneration: UInt64 = 0
    private var hasLoadedAuthoritativeSnapshot = false
    private var hasStarted = false

    func event(withID id: UUID) -> HLLEvent? { events.first { $0.id == id } }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            needsCalendarAccess = true
            isLoading = false
        }

        // Decode the tiny App Group launch snapshot away from the main actor.
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
            guard let snapshot = await quickSnapshot.value,
                  let self, self.isLoading else { return }
            guard !self.hasLoadedAuthoritativeSnapshot,
                  await self.apply(snapshot.events, at: .now) else { return }
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

    /// Coalesce EventKit, CloudKit, and lifecycle bursts into one actor refresh.
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
            // Reuse the metadata the engine already needed to compose events.
            // This removes two duplicate reads from every watch refresh.
            let result = try await runtime.engine.queryResult(query, now: now)
            hasLoadedAuthoritativeSnapshot = true
            guard await apply(result.snapshot.events, at: now) else { return }
            calendars = result.calendars.map { (id: $0.localID, preference: $0.preference) }
            hiddenAnnotations = result.annotations.filter { $0.kind == .hidden }
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

    /// Reclassify in memory at the next start/end; never reopen a database just
    /// because wall-clock time crossed an event boundary.
    private func apply(_ newEvents: [HLLEvent], at date: Date) async -> Bool {
        classificationGeneration &+= 1
        let generation = classificationGeneration
        // Keep array filtering and boundary scans away from the watch UI actor.
        let classification = await Task.detached(priority: .userInitiated) {
            HLLEventClassification(events: newEvents, at: date)
        }.value
        guard generation == classificationGeneration else { return false }
        events = newEvents
        currentEvents = classification.current
        upcomingEvents = classification.upcoming
        scheduleNextBoundary(classification.nextBoundary, classifiedAt: date)
        return true
    }

    private func scheduleNextBoundary(_ next: Date?, classifiedAt date: Date) {
        boundaryTask?.cancel()
        guard let next else { return }
        boundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, next.timeIntervalSince(date) + 0.05)))
            guard !Task.isCancelled, let self else { return }
            _ = await self.apply(self.events, at: .now)
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
            do { try await runtime.engine.removeAnnotation(id: annotation.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func deleteUserEvent(_ event: HLLEvent) {
        guard event.source == .user, let runtime else { return }
        let definitionID = event.seriesID.flatMap(UUID.init(uuidString:)) ?? event.id
        Task {
            do { try await runtime.engine.deleteUserEvent(id: definitionID) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func setCalendarVisibility(_ calendar: HLLCalendarPreference,
                               context: HLLContextID, visible: Bool) {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.engine.setCalendarVisibility(
                    profileID: calendar.id, context: context, isVisible: visible)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Watch-created personal events use the same CloudKit-backed repository
    /// as iPhone-created events and never depend on iPhone reachability.
    func addUserEvent(title: String, start: Date, duration: TimeInterval,
                      isAllDay: Bool = false, recurrence: HLLRecurrenceRule?) {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.engine.save(HLLUserEvent(
                    title: title, start: start, duration: duration,
                    isAllDay: isAllDay, recurrence: recurrence))
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
            let visibleEvents = notificationPreferences.enabled ? events : []
            try await runtime.notifications.reconcile(events: visibleEvents, options: options)
        } catch { errorMessage = error.localizedDescription }
    }
}
