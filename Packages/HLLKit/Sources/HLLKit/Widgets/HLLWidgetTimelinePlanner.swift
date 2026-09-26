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
                     rule: @Sendable (Date) -> HLLEventRule) -> [HLLWidgetTimelinePoint] {
        guard let payload else { return [HLLWidgetTimelinePoint(date: now, events: [])] }
        let horizon = min(max(payload.expiresAt, now.addingTimeInterval(60)),
                          now.addingTimeInterval(2 * 86_400))
        let transitions = payload.events.flatMap { [$0.start, $0.end] }
            .filter { $0 > now && $0 < horizon }
        // Progress bars receive intermediate entries; timer text advances on its own.
        var progressDates: [Date] = []
        if updateProgress {
            for event in payload.events where event.start < horizon && event.end > now {
                var date = max(event.start, now).addingTimeInterval(15 * 60)
                while date < min(event.end, horizon) {
                    progressDates.append(date)
                    date = date.addingTimeInterval(15 * 60)
                }
            }
        }
        let dates = Array(Set([now] + transitions + progressDates)).sorted().prefix(96)
        let index = HLLEventIndex(payload.events)
        let reducer = HLLEventReducer()
        return dates.map { date in
            let query = HLLEventQuery(interval: DateInterval(start: date, end: horizon),
                                      rule: rule(date), context: context, limit: limit)
            let events = reducer.reduce(index, query: query,
                                        calendarPreferences: payload.calendars,
                                        annotations: payload.annotations)
            return HLLWidgetTimelinePoint(date: date, events: events)
        }
    }
}
