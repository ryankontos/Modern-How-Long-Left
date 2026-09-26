import Foundation

/// Device-local rules for automatically scheduling event Live Activities.
public struct HLLLiveActivityPolicy: Identifiable, Codable, Sendable, Equatable {
    public enum Target: Codable, Sendable, Equatable {
        case allEvents
        case calendar(profileID: UUID)
        case event(id: UUID, portableKey: String?)
    }

    public var id: UUID
    public var target: Target
    public var context: HLLContextID
    public var leadTime: TimeInterval
    public var includeAllDay: Bool
    public var updatedAt: Date

    public init(id: UUID = UUID(), target: Target,
                context: HLLContextID = "activity.default",
                leadTime: TimeInterval = 30 * 60,
                includeAllDay: Bool = false, updatedAt: Date = .now) {
        self.id = id
        self.target = target
        self.context = context
        self.leadTime = min(max(leadTime, 0), 24 * 60 * 60)
        self.includeAllDay = includeAllDay
        self.updatedAt = updatedAt
    }

    public func includes(_ event: HLLEvent,
                         calendars: [String: HLLCalendarPreference]) -> Bool {
        guard includeAllDay || !event.isAllDay else { return false }
        switch target {
        case .allEvents: return true
        case .calendar(let profileID):
            return event.calendarID.flatMap { calendars[$0]?.id } == profileID
        case .event(let id, let portableKey):
            return event.id == id || (portableKey != nil && event.portableKey == portableKey)
        }
    }
}
