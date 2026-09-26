import Foundation

/// The only event value used outside an event source. Its ID survives ordinary refreshes.
public struct HLLEvent: Identifiable, Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable { case eventKit, user }

    /// The event's time-relative state. It is always derived from the event's
    /// dates so a value stored on disk can never become stale while the app or
    /// a complication is asleep.
    public enum Status: String, Codable, Sendable {
        case upcoming
        case inProgress
        case complete
    }

    public let id: UUID
    public let source: Source
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarID: String?
    public let seriesID: String?
    public let portableKey: String?
    public let occurrenceStart: Date?
    public let location: String?
    public let notes: String?

    public init(id: UUID, source: Source, title: String, start: Date, end: Date,
                isAllDay: Bool = false, calendarID: String? = nil, seriesID: String? = nil,
                portableKey: String? = nil,
                occurrenceStart: Date? = nil, location: String? = nil, notes: String? = nil) {
        self.id = id
        self.source = source
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.seriesID = seriesID
        self.portableKey = portableKey
        self.occurrenceStart = occurrenceStart
        self.location = location
        self.notes = notes
    }

    /// Returns the status at any point in time. `.now` is evaluated at the call
    /// site, which keeps this convenient for UI while remaining deterministic
    /// in tests, timeline generation, and notification scheduling.
    public func status(at date: Date = .now) -> Status {
        if date < start { return .upcoming }
        if date < end { return .inProgress }
        return .complete
    }

    public func isRunning(at date: Date = .now) -> Bool {
        status(at: date) == .inProgress
    }

    /// The date a countdown is moving toward: start for an upcoming event and
    /// end for one in progress. Completed events have no useful countdown.
    public func countdownDate(at date: Date = .now) -> Date? {
        switch status(at: date) {
        case .upcoming: start
        case .inProgress: end
        case .complete: nil
        }
    }
}
