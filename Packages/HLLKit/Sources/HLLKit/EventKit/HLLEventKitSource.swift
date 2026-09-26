@preconcurrency import EventKit
import Foundation

/// EventKit stays inside this actor. Callers receive only Sendable values.
public actor HLLEventKitSource {
    public struct CalendarInfo: Sendable, Hashable {
        public let localID: String
        public let title: String
        public let sourceTitle: String
    }

    public struct RawEvent: Sendable {
        public let localID: String?
        public let externalID: String?
        public let calendarLocalID: String
        public let title: String
        public let start: Date
        public let end: Date
        public let occurrenceStart: Date
        public let isAllDay: Bool
        public let hasRecurrence: Bool
        public let location: String?
        public let notes: String?
    }

    private let store = EKEventStore()

    public init() {}

    public func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    @discardableResult
    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    public func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map {
            CalendarInfo(localID: $0.calendarIdentifier, title: $0.title,
                         sourceTitle: $0.source.title)
        }
    }

    /// EventKit's predicate is bounded; we never scan an entire calendar history.
    public func events(in interval: DateInterval) -> [RawEvent] {
        guard authorizationStatus() == .fullAccess, interval.duration > 0 else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end,
                                                 calendars: nil)
        return store.events(matching: predicate).map { event in
            RawEvent(localID: event.eventIdentifier,
                     externalID: event.calendarItemExternalIdentifier,
                     calendarLocalID: event.calendar.calendarIdentifier,
                     title: event.title ?? "Untitled Event",
                     start: event.startDate, end: event.endDate,
                     occurrenceStart: event.occurrenceDate ?? event.startDate,
                     isAllDay: event.isAllDay,
                     hasRecurrence: event.hasRecurrenceRules,
                     location: event.location, notes: event.notes)
        }
    }
}
