import Foundation

/// Pure filtering and ordering. The same result powers UIKit, SwiftUI, and widgets.
public struct HLLEventReducer: Sendable {
    public init() {}

    public func reduce(_ events: [HLLEvent], query: HLLEventQuery,
                       calendarPreferences: [String: HLLCalendarPreference],
                       annotations: [HLLEventAnnotation]) -> [HLLEvent] {
        reduce(HLLEventIndex(events), query: query,
               calendarPreferences: calendarPreferences, annotations: annotations)
    }

    public func reduce(_ index: HLLEventIndex, query: HLLEventQuery,
                       calendarPreferences: [String: HLLCalendarPreference],
                       annotations: [HLLEventAnnotation]) -> [HLLEvent] {
        let hiddenIDs = Set(annotations.filter { $0.kind == .hidden && $0.scope == .occurrence }
            .compactMap(\.eventID))
        let hiddenSeries = Set(annotations.filter { $0.kind == .hidden && $0.scope == .series }
            .compactMap(\.seriesID))
        let hiddenPortable = Set(annotations.filter { $0.kind == .hidden && $0.scope == .occurrence }
            .compactMap(\.portableKey))
        let pinnedIDs = Set(annotations.filter { $0.kind == .pinned && $0.scope == .occurrence }
            .compactMap(\.eventID))
        let pinnedSeries = Set(annotations.filter { $0.kind == .pinned && $0.scope == .series }
            .compactMap(\.seriesID))
        let pinnedPortable = Set(annotations.filter { $0.kind == .pinned && $0.scope == .occurrence }
            .compactMap(\.portableKey))

        let visible = index.candidates(for: query.rule).filter { event in
            if let key = event.calendarID, let preference = calendarPreferences[key],
               !preference.isVisible(in: query.context) { return false }
            if !query.includeHidden && (hiddenIDs.contains(event.id)
                || (event.portableKey.map(hiddenPortable.contains) ?? false)
                || (event.seriesID.map(hiddenSeries.contains) ?? false)) { return false }
            return query.rule.matches(event)
        }
        let sorted = visible.sorted { lhs, rhs in
            let lhsPinned = pinnedIDs.contains(lhs.id) || (lhs.portableKey.map(pinnedPortable.contains) ?? false)
                || (lhs.seriesID.map(pinnedSeries.contains) ?? false)
            let rhsPinned = pinnedIDs.contains(rhs.id) || (rhs.portableKey.map(pinnedPortable.contains) ?? false)
                || (rhs.seriesID.map(pinnedSeries.contains) ?? false)
            if lhsPinned != rhsPinned { return lhsPinned }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return query.limit.map { Array(sorted.prefix(max(0, $0))) } ?? sorted
    }
}
