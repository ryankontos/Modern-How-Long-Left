import Foundation

public struct HLLWidgetTimelinePoint: Sendable {
    public let date: Date
    public let events: [HLLEvent]
}

/// Precomputes event transitions so widgets can update when the app is asleep.
public struct HLLWidgetTimelinePlanner: Sendable {
    public init() {}

    public func plan(payload: HLLWidgetPayload?, now: Date, context: HLLContextID,
                     limit: Int, updateProgress: Bool = false,
                     sortOrder: HLLWidgetSortOrder = .countdownDate,
                     rule: @Sendable (Date) -> HLLEventRule) -> [HLLWidgetTimelinePoint] {
        guard let payload else { return [HLLWidgetTimelinePoint(date: now, events: [])] }
        // Align the timeline to calendar days. Its membership stays identical
        // throughout the day, so an event ending changes which entry is shown
        // without changing the backing projection fingerprint.
        let calendar = Calendar.autoupdatingCurrent
        let startOfToday = calendar.startOfDay(for: now)
        let fixedEnd = calendar.date(byAdding: .day, value: 2, to: startOfToday)
            ?? now.addingTimeInterval(2 * 86_400)
        let horizon = min(max(payload.expiresAt, now.addingTimeInterval(60)), fixedEnd)
        let index = HLLEventIndex(payload.events)
        let reducer = HLLEventReducer()

        func selectedEvents(at date: Date) -> [HLLEvent] {
            let query = HLLEventQuery(interval: DateInterval(start: date, end: horizon),
                                      rule: rule(date), context: context)
            let events = reducer.reduce(index, query: query,
                                        calendarPreferences: payload.calendars,
                                        annotations: payload.annotations)
            return Array(sortOrder.sort(events, at: date).prefix(max(0, limit)))
        }

        // Filter durable visibility once before collecting transitions. Use an
        // upcoming rule here because a mode such as `inProgress` can match a
        // future event after it starts even though it does not match right now.
        let initialQuery = HLLEventQuery(interval: DateInterval(start: now, end: horizon),
                                         rule: .upcoming(now), context: context)
        let eligible = reducer.reduce(index, query: initialQuery,
                                      calendarPreferences: payload.calendars,
                                      annotations: payload.annotations)
        let transitions = Set(eligible.flatMap { [$0.start, $0.end] }
            .filter { $0 > now && $0 < horizon })

        // Keep only points where the chosen event or its countdown target
        // changes. This preserves starts and ends while collapsing irrelevant
        // transitions from a busy calendar.
        var structural: [HLLWidgetTimelinePoint] = []
        var lastSignature: [String]?
        for date in ([now] + Array(transitions)).sorted() {
            let events = selectedEvents(at: date)
            let signature = events.map {
                "\($0.id.uuidString)|\($0.countdownDate(at: date)?.timeIntervalSince1970 ?? -1)"
            }
            if signature != lastSignature {
                structural.append(HLLWidgetTimelinePoint(date: date, events: events))
                lastSignature = signature
            }
        }

        let maximumEntries = 96
        if !updateProgress || structural.count >= maximumEntries {
            return Array(structural.prefix(maximumEntries))
        }

        // Date-driven Text timers animate without entries. Progress bars need
        // snapshots, so use the remaining budget only for events that are
        // selected in at least one structural point.
        let visible = Dictionary(structural.flatMap(\.events).map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first }).values
        let structuralDates = Set(structural.map(\.date))
        var progressDates: [Date] = []
        for event in visible where event.start < horizon && event.end > now {
            var date = max(event.start, now).addingTimeInterval(15 * 60)
            while date < min(event.end, horizon) {
                if !structuralDates.contains(date) { progressDates.append(date) }
                date = date.addingTimeInterval(15 * 60)
            }
        }
        let remaining = maximumEntries - structural.count
        let progress = Array(Set(progressDates)).sorted().prefix(remaining).map {
            HLLWidgetTimelinePoint(date: $0, events: selectedEvents(at: $0))
        }
        return (structural + progress).sorted { $0.date < $1.date }
    }
}
