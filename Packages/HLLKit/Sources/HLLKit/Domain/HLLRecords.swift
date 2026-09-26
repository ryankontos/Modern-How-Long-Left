import Foundation

/// Context flags are stored per logical calendar, then bound to local EventKit IDs.
public struct HLLCalendarPreference: Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var sourceTitle: String
    /// EventKit source identifiers survive local calendar identifier changes
    /// more reliably than a calendar's device-local ID.
    public var sourceIdentifier: String?
    /// A missing context is visible. New contexts need no schema change.
    public var visibility: [HLLContextID: Bool]
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, sourceTitle: String = "",
                sourceIdentifier: String? = nil,
                visibility: [HLLContextID: Bool] = [:],
                updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
        self.sourceIdentifier = sourceIdentifier
        self.visibility = visibility
        self.updatedAt = updatedAt
    }

    public func isVisible(in context: HLLContextID) -> Bool {
        visibility[context] ?? true
    }
}

/// One CloudKit record per calendar and context prevents unrelated switches from colliding.
public struct HLLCalendarVisibilityRule: Codable, Sendable, Equatable {
    public let calendarID: UUID
    public let context: HLLContextID
    public let isVisible: Bool
    public let updatedAt: Date

    public init(calendarID: UUID, context: HLLContextID, isVisible: Bool, updatedAt: Date = .now) {
        self.calendarID = calendarID
        self.context = context
        self.isVisible = isVisible
        self.updatedAt = updatedAt
    }

    public var storageKey: String { "\(calendarID.uuidString)|\(context.rawValue)" }
}

public struct HLLRecurrenceRule: Codable, Sendable, Equatable {
    public enum Frequency: String, Codable, Sendable { case daily, weekly, monthly, yearly }
    public var frequency: Frequency
    public var interval: Int
    /// Calendar weekday values (1 = Sunday). Empty means the start date's weekday.
    public var weekdays: [Int]
    public var until: Date?

    public init(frequency: Frequency, interval: Int = 1, weekdays: [Int] = [], until: Date? = nil) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.until = until
    }
}

public struct HLLUserEvent: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var start: Date
    public var duration: TimeInterval
    public var isAllDay: Bool
    public var recurrence: HLLRecurrenceRule?
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, start: Date, duration: TimeInterval,
                isAllDay: Bool = false, recurrence: HLLRecurrenceRule? = nil,
                updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.start = start
        self.duration = max(0, duration)
        self.isAllDay = isAllDay
        self.recurrence = recurrence
        self.updatedAt = updatedAt
    }
}

/// One persistent annotation can address one occurrence or its entire series.
public struct HLLEventAnnotation: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case hidden, pinned }
    public enum Scope: String, Codable, Sendable { case occurrence, series }

    public var id: UUID
    public var kind: Kind
    public var scope: Scope
    public var eventID: UUID?
    public var seriesID: String?
    public var portableKey: String?
    public var eventTitle: String?
    public var expiresAt: Date?
    public var syncAcrossDevices: Bool
    public var updatedAt: Date

    public init(id: UUID? = nil, kind: Kind, scope: Scope, eventID: UUID? = nil,
                seriesID: String? = nil, portableKey: String? = nil,
                eventTitle: String? = nil, expiresAt: Date? = nil,
                syncAcrossDevices: Bool = true, updatedAt: Date = .now) {
        let target = scope == .series ? (seriesID ?? "")
            : (portableKey ?? eventID?.uuidString ?? "")
        self.id = id ?? HLLStableID.make(["annotation", kind.rawValue, scope.rawValue, target])
        self.kind = kind
        self.scope = scope
        self.eventID = eventID
        self.seriesID = seriesID
        self.portableKey = portableKey
        self.eventTitle = eventTitle
        self.expiresAt = expiresAt
        self.syncAcrossDevices = syncAcrossDevices
        self.updatedAt = updatedAt
    }

    public func applies(to event: HLLEvent) -> Bool {
        switch scope {
        case .occurrence: event.id == eventID || (portableKey != nil && event.portableKey == portableKey)
        case .series: seriesID != nil && event.seriesID == seriesID
        }
    }
}
