import Foundation

/// Expands only the requested window; recurring events never become an unbounded table.
public struct HLLUserOccurrenceGenerator: Sendable {
    public init() {}

    public func occurrences(of definition: HLLUserEvent, in window: DateInterval,
                            calendar: Calendar = .current, limit: Int = 1_000) -> [HLLEvent] {
        guard window.duration > 0, limit > 0 else { return [] }
        guard let rule = definition.recurrence else {
            return intersects(definition.start, definition.duration, window)
                ? [makeEvent(definition, at: definition.start)] : []
        }

        // Start near the requested window so old daily events remain cheap to query.
        let earliest = window.start.addingTimeInterval(-definition.duration)
        var results: [HLLEvent] = []
        var cursor = firstCandidate(for: definition.start, rule: rule, near: earliest, calendar: calendar)
        var iterations = 0
        while cursor < window.end && results.count < limit && iterations < 10_000 {
            if cursor >= definition.start && (rule.until == nil || cursor <= rule.until!)
                && matchesWeekday(cursor, start: definition.start, rule: rule, calendar: calendar)
                && intersects(cursor, definition.duration, window) {
                results.append(makeEvent(definition, at: cursor))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
            iterations += 1
        }
        return results
    }

    private func firstCandidate(for start: Date, rule: HLLRecurrenceRule,
                                near date: Date, calendar: Calendar) -> Date {
        guard date > start else { return start }
        let unit: Calendar.Component = switch rule.frequency {
        case .daily, .weekly: .day
        case .monthly: .month
        case .yearly: .year
        }
        let count = calendar.dateComponents([unit], from: start, to: date).value(for: unit) ?? 0
        let step = rule.frequency == .weekly ? 7 * rule.interval : rule.interval
        let offset = max(0, count / step * step - step)
        return calendar.date(byAdding: unit, value: offset, to: start) ?? start
    }

    private func matchesWeekday(_ date: Date, start: Date, rule: HLLRecurrenceRule,
                                calendar: Calendar) -> Bool {
        switch rule.frequency {
        case .daily:
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                               to: calendar.startOfDay(for: date)).day ?? 0
            return days >= 0 && days % rule.interval == 0
        case .weekly:
            let startWeek = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
            let candidateWeek = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            let weeks = calendar.dateComponents([.weekOfYear], from: startWeek,
                                                to: candidateWeek).weekOfYear ?? 0
            let weekdays = rule.weekdays.isEmpty ? [calendar.component(.weekday, from: start)] : rule.weekdays
            return weeks >= 0 && weeks % rule.interval == 0
                && weekdays.contains(calendar.component(.weekday, from: date))
        case .monthly:
            let months = calendar.dateComponents([.month], from: start, to: date).month ?? 0
            return months >= 0 && months % rule.interval == 0
                && calendar.component(.day, from: date) == calendar.component(.day, from: start)
        case .yearly:
            let years = calendar.dateComponents([.year], from: start, to: date).year ?? 0
            return years >= 0 && years % rule.interval == 0
                && calendar.component(.month, from: date) == calendar.component(.month, from: start)
                && calendar.component(.day, from: date) == calendar.component(.day, from: start)
        }
    }

    private func intersects(_ start: Date, _ duration: TimeInterval, _ window: DateInterval) -> Bool {
        start < window.end && start.addingTimeInterval(duration) > window.start
    }

    private func makeEvent(_ definition: HLLUserEvent, at date: Date) -> HLLEvent {
        let id = definition.recurrence == nil ? definition.id
            : HLLStableID.make(["user", definition.id.uuidString, String(date.timeIntervalSince1970)])
        return HLLEvent(id: id, source: .user, title: definition.title, start: date,
                        end: date.addingTimeInterval(definition.duration), isAllDay: definition.isAllDay,
                        seriesID: definition.id.uuidString, portableKey: "user|\(id.uuidString)",
                        occurrenceStart: date)
    }
}
