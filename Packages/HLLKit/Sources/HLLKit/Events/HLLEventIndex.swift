import Foundation

/// Immutable indexes narrow common queries before custom or composed rules run.
public struct HLLEventIndex: Sendable {
    private let events: [HLLEvent]
    private let byStart: [Int]
    private let byEnd: [Int]
    private let byCalendar: [String: [Int]]
    private let bySource: [HLLEvent.Source: [Int]]
    private let byAllDay: [Bool: [Int]]

    public init(_ events: [HLLEvent]) {
        self.events = events
        self.byStart = events.indices.sorted { events[$0].start < events[$1].start }
        self.byEnd = events.indices.sorted { events[$0].end < events[$1].end }
        var calendar: [String: [Int]] = [:]
        var source: [HLLEvent.Source: [Int]] = [:]
        var allDay: [Bool: [Int]] = [:]
        for index in events.indices {
            let event = events[index]
            if let id = event.calendarID { calendar[id, default: []].append(index) }
            source[event.source, default: []].append(index)
            allDay[event.isAllDay, default: []].append(index)
        }
        self.byCalendar = calendar
        self.bySource = source
        self.byAllDay = allDay
    }

    public func candidates(for rule: HLLEventRule) -> [HLLEvent] {
        let indices = candidateIndices(for: rule) ?? Array(events.indices)
        return indices.map { events[$0] }
    }

    private func candidateIndices(for rule: HLLEventRule) -> [Int]? {
        switch rule {
        case .calendar(let id): byCalendar[id] ?? []
        case .source(let source): bySource[source] ?? []
        case .allDay(let value): byAllDay[value] ?? []
        case .start(let range): rangeOf(byStart, key: { events[$0].start }, in: range)
        case .end(let range): rangeOf(byEnd, key: { events[$0].end }, in: range)
        case .running(let date): smaller(
            Array(byStart.prefix(lowerBound(byStart) { events[$0].start <= date })),
            Array(byEnd.suffix(from: lowerBound(byEnd) { events[$0].end <= date })))
        case .upcoming(let date):
            Array(byEnd.suffix(from: lowerBound(byEnd) { events[$0].end <= date }))
        case .intersects(let range): smaller(
            Array(byStart.prefix(lowerBound(byStart) { events[$0].start < range.end })),
            Array(byEnd.suffix(from: lowerBound(byEnd) { events[$0].end <= range.start })))
        case .and(let rules):
            rules.compactMap(candidateIndices).min(by: { $0.count < $1.count })
        case .or, .not, .custom: nil
        }
    }

    private func smaller(_ lhs: [Int], _ rhs: [Int]) -> [Int] { lhs.count <= rhs.count ? lhs : rhs }

    private func rangeOf(_ indices: [Int], key: (Int) -> Date,
                         in range: DateInterval) -> [Int] {
        let first = lowerBound(indices) { key($0) < range.start }
        let last = lowerBound(indices) { key($0) < range.end }
        return Array(indices[first..<last])
    }

    /// Returns the first index for which the monotone condition is false.
    private func lowerBound(_ indices: [Int], condition: (Int) -> Bool) -> Int {
        var low = 0
        var high = indices.count
        while low < high {
            let middle = (low + high) / 2
            if condition(indices[middle]) { low = middle + 1 }
            else { high = middle }
        }
        return low
    }
}
