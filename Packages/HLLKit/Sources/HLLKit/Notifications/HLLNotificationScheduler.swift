#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// Notification policy is deliberately a small service at the edge of HLLKit.
/// It accepts HLLEvents, never EKEvents, and uses the same entitlement actor as
/// widgets and Live Activities. The service is safe to call repeatedly: every
/// request has a deterministic identifier and replaces the previous request.
public actor HLLNotificationScheduler {
    public struct ScheduleOptions: Sendable, Equatable {
        public let notifyAtStart: Bool
        public let notifyAtEnd: Bool
        public let includeAllDay: Bool

        public init(notifyAtStart: Bool = true, notifyAtEnd: Bool = true,
                    includeAllDay: Bool = false) {
            self.notifyAtStart = notifyAtStart
            self.notifyAtEnd = notifyAtEnd
            self.includeAllDay = includeAllDay
        }
    }

    private let center: UNUserNotificationCenter
    private let purchases: HLLPurchaseCoordinator
    private let identifierPrefix: String
    private let maxPendingRequests: Int

    public init(center: UNUserNotificationCenter = .current(),
                purchases: HLLPurchaseCoordinator,
                identifierPrefix: String = "hll.notification.",
                maxPendingRequests: Int = 64) {
        self.center = center
        self.purchases = purchases
        self.identifierPrefix = identifierPrefix
        self.maxPendingRequests = max(1, maxPendingRequests)
    }

    public func requestAuthorization() async throws -> Bool {
        guard await purchases.isUnlocked(.notifications) else {
            throw HLLNotificationError.premiumRequired
        }
        return try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func scheduleStart(for event: HLLEvent) async throws {
        guard await purchases.isUnlocked(.notifications) else {
            throw HLLNotificationError.premiumRequired
        }
        guard event.start > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = "Your event is starting."
        content.sound = .default
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: event.start)
        let request = UNNotificationRequest(
            identifier: identifier(for: event, kind: "start"),
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        try await replace(request)
    }

    public func scheduleEnd(for event: HLLEvent) async throws {
        guard await purchases.isUnlocked(.notifications) else {
            throw HLLNotificationError.premiumRequired
        }
        guard event.end > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = "Your event is ending."
        content.sound = .default
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: event.end)
        let request = UNNotificationRequest(
            identifier: identifier(for: event, kind: "end"),
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        try await replace(request)
    }

    public func cancel(for event: HLLEvent) {
        let identifiers = [identifier(for: event, kind: "start"),
                           identifier(for: event, kind: "end")]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Reconciles a caller-provided visible event set. Hidden events never
    /// reach this method because the main engine performs annotation filtering
    /// before it hands the list to the scheduler.
    public func reconcile(events: [HLLEvent], options: ScheduleOptions = .init()) async throws {
        guard await purchases.isUnlocked(.notifications) else {
            await cancelAllManagedRequests()
            return
        }
        let now = Date()
        let visibleEvents = events
            .filter { options.includeAllDay || !$0.isAllDay }
            .sorted { nextTrigger(for: $0, options: options, now: now)
                < nextTrigger(for: $1, options: options, now: now) }
        let requests = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(identifierPrefix) }
        var desired = Set<String>()
        var scheduledEvents: [HLLEvent] = []
        for event in visibleEvents {
            let identifiers = identifiers(for: event, options: options, now: now)
            guard !identifiers.isEmpty,
                  desired.count + identifiers.count <= maxPendingRequests else { break }
            desired.formUnion(identifiers)
            scheduledEvents.append(event)
        }
        let stale = requests.map(\.identifier).filter { !desired.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        center.removeDeliveredNotifications(withIdentifiers: stale)
        for event in scheduledEvents {
            if options.notifyAtStart { try await scheduleStart(for: event) }
            if options.notifyAtEnd { try await scheduleEnd(for: event) }
        }
    }

    private func replace(_ request: UNNotificationRequest) async throws {
        center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
        try await center.add(request)
    }

    private func cancelAllManagedRequests() async {
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func identifiers(for event: HLLEvent, options: ScheduleOptions,
                             now: Date) -> [String] {
        var identifiers: [String] = []
        if options.notifyAtStart && event.start > now {
            identifiers.append(identifier(for: event, kind: "start"))
        }
        if options.notifyAtEnd && event.end > now {
            identifiers.append(identifier(for: event, kind: "end"))
        }
        return identifiers
    }

    private func nextTrigger(for event: HLLEvent, options: ScheduleOptions,
                             now: Date) -> Date {
        let triggers = [
            options.notifyAtStart && event.start > now ? event.start : nil,
            options.notifyAtEnd && event.end > now ? event.end : nil
        ].compactMap { $0 }
        return triggers.min() ?? .distantFuture
    }

    private func identifier(for event: HLLEvent, kind: String) -> String {
        let key = event.portableKey ?? event.id.uuidString
        return identifierPrefix + kind + "." + key
    }
}

public enum HLLNotificationError: LocalizedError, Sendable {
    case premiumRequired

    public var errorDescription: String? {
        "Notifications are available with How Long Left Premium."
    }
}
#endif
