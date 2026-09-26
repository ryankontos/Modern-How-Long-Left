import Foundation

/// Consumers choose context IDs; HLLKit does not know the app's screen or widget types.
public struct HLLContextID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

/// Common filters are explicit so the query planner can use indexes.
public indirect enum HLLEventRule: Sendable {
    case intersects(DateInterval)
    case start(DateInterval)
    case end(DateInterval)
    case running(Date)
    case upcoming(Date)
    case allDay(Bool)
    case source(HLLEvent.Source)
    case calendar(String)
    case and([HLLEventRule])
    case or([HLLEventRule])
    case not(HLLEventRule)
    case custom(@Sendable (HLLEvent) -> Bool)

    public func matches(_ event: HLLEvent) -> Bool {
        switch self {
        case .intersects(let range): event.start < range.end && event.end > range.start
        case .start(let range): range.contains(event.start)
        case .end(let range): range.contains(event.end)
        case .running(let date): event.isRunning(at: date)
        case .upcoming(let date): event.end > date
        case .allDay(let value): event.isAllDay == value
        case .source(let source): event.source == source
        case .calendar(let calendar): event.calendarID == calendar
        case .and(let rules): rules.allSatisfy { $0.matches(event) }
        case .or(let rules): rules.contains { $0.matches(event) }
        case .not(let rule): !rule.matches(event)
        case .custom(let predicate): predicate(event)
        }
    }
}

/// The interval bounds source work; the rule selects from that bounded set.
public struct HLLEventQuery: Sendable {
    public var interval: DateInterval
    public var rule: HLLEventRule
    public var context: HLLContextID
    public var includeHidden: Bool
    public var limit: Int?

    public init(interval: DateInterval, rule: HLLEventRule? = nil, context: HLLContextID,
                includeHidden: Bool = false, limit: Int? = nil) {
        self.interval = interval
        self.rule = rule ?? .intersects(interval)
        self.context = context
        self.includeHidden = includeHidden
        self.limit = limit
    }
}

public struct HLLEventSnapshot: Sendable, Equatable, Codable {
    public let revision: UInt64
    public let generatedAt: Date
    public let events: [HLLEvent]
    public init(revision: UInt64, generatedAt: Date, events: [HLLEvent]) {
        self.revision = revision
        self.generatedAt = generatedAt
        self.events = events
    }
}
