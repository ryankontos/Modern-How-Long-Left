import Foundation

/// The only event value used outside an event source. Its ID survives ordinary refreshes.
public struct HLLEvent: Identifiable, Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable { case eventKit, user }

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

    public func isRunning(at date: Date) -> Bool { start <= date && date < end }
}
