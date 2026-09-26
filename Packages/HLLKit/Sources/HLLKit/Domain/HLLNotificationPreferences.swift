import Foundation

/// Device-local notification policy. Notification requests themselves are
/// derived from the current visible HLLEvent snapshot and never stored one by
/// one in the database.
public struct HLLNotificationPreferences: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var notifyAtStart: Bool
    public var notifyAtEnd: Bool
    public var includeAllDay: Bool
    public var context: HLLContextID
    public var updatedAt: Date

    public init(enabled: Bool = false, notifyAtStart: Bool = true,
                notifyAtEnd: Bool = true, includeAllDay: Bool = false,
                context: HLLContextID = "home.main", updatedAt: Date = .now) {
        self.enabled = enabled
        self.notifyAtStart = notifyAtStart
        self.notifyAtEnd = notifyAtEnd
        self.includeAllDay = includeAllDay
        self.context = context
        self.updatedAt = updatedAt
    }

    public var hasActions: Bool { notifyAtStart || notifyAtEnd }
}
