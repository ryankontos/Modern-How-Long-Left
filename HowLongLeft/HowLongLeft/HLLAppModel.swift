import EventKit
import Foundation
import HLLKit
import Observation
import WidgetKit

/// The main actor owns presentation state. HLLKit actors do source and disk work.
@MainActor @Observable
final class HLLAppModel {
    var events: [HLLEvent] = []
    /// Prepared once per source refresh or time boundary. Views can scroll and
    /// update timer text without repeatedly filtering the complete event set.
    var currentEvents: [HLLEvent] = []
    var upcomingEvents: [HLLEvent] = []
    var calendars: [(id: String, preference: HLLCalendarPreference)] = []
    var hiddenAnnotations: [HLLEventAnnotation] = []
    var annotationSyncEnabled = true
    var activityPolicies: [HLLLiveActivityPolicy] = []
    var widgetDefaults = HLLWidgetDefaults()
    var notificationPreferences = HLLNotificationPreferences()
    var activeActivityEventKeys: Set<String> = []
    var purchaseSnapshot = HLLPurchaseSnapshot.locked(configuration: .shipping)
    var purchaseProducts: [HLLStoreProduct] = []
    var purchaseErrorMessage: String?
    var needsCalendarAccess = false
    var isLoading = true
    var errorMessage: String?

    /// Service access for focused extensions in adjacent files. Observation is
    /// unnecessary because views consume the value properties above.
    @ObservationIgnored var runtime: HLLRuntime?
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
        let quickSnapshot = Task.detached(priority: .userInitiated) {
            let payload = HLLWidgetSnapshotStore(
                groupIdentifier: HLLConfiguration.appGroupIdentifier).read()
            let now = Date()
            return payload?.launchSnapshot(query: HLLEventQuery(
                interval: DateInterval(start: now.addingTimeInterval(-86_400),
                                       end: now.addingTimeInterval(30 * 86_400)),
                rule: .upcoming(now), context: "home.main"))
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
                        await self.reconcileLiveActivities(using: runtime)
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
        // EventKit and CloudKit commonly emit several notifications for one
        // logical edit. A short trailing debounce prevents duplicate queries.
        sourceChangeTask?.cancel()
        sourceChangeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await runtime.engine.invalidate()
        }
    }

    func refresh(publishWidgets: Bool = true) async {
        guard let runtime else { return }
        do {
            let now = Date()
            let interval = DateInterval(start: now.addingTimeInterval(-86_400),
                                        end: now.addingTimeInterval(30 * 86_400))
            let query = HLLEventQuery(interval: interval, rule: .upcoming(now), context: "home.main")
            // This result already contains the calendars and annotations used
            // to compose the list, so the UI never repeats those database reads.
            let result = try await runtime.engine.queryResult(query, now: now)
            apply(result.snapshot.events, at: now)
            calendars = result.calendars.map { (id: $0.localID, preference: $0.preference) }
            hiddenAnnotations = result.annotations.filter { $0.kind == .hidden }
            annotationSyncEnabled = try await runtime.repository.settings().syncEventAnnotations
            activityPolicies = try await runtime.repository.activityPolicies()
            widgetDefaults = try await runtime.repository.widgetDefaults()
            notificationPreferences = try await runtime.repository.notificationPreferences()
            needsCalendarAccess = await runtime.eventKit.authorizationStatus() != .fullAccess
            isLoading = false
            if publishWidgets, try await runtime.publishWidgetSnapshot() {
                WidgetCenter.shared.reloadTimelines(ofKind: "HowLongLeftWidgets")
            }
            await reconcileLiveActivities(using: runtime)
            await reconcileNotifications(using: runtime)
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// A clock boundary only changes classification. Reusing the loaded values
    /// avoids reopening EventKit and the database when an event starts or ends.
    private func apply(_ newEvents: [HLLEvent], at date: Date) {
        events = newEvents
        currentEvents = newEvents.filter { $0.status(at: date) == .inProgress }
        upcomingEvents = newEvents.filter { $0.status(at: date) == .upcoming }
        scheduleNextBoundary(now: date)
    }

    private func scheduleNextBoundary(now: Date) {
        boundaryTask?.cancel()
        guard let next = events.flatMap({ [$0.start, $0.end] }).filter({ $0 > now }).min() else { return }
        boundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSince(now) + 0.1)))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.apply(self.events, at: .now)
        }
    }

}
