import Foundation

/// Small presentation seed decoded before the database and EventKit runtime
/// are ready. It contains values only, so apps can build it off the main actor
/// and publish the complete first screen in one assignment.
public struct HLLLaunchSnapshot: Sendable {
    public let events: [HLLEvent]
    public let calendars: [HLLCalendarPreference]
    public let hiddenAnnotations: [HLLEventAnnotation]
    public let generatedAt: Date
}

public extension HLLWidgetPayload {
    /// Converts the atomic extension payload into an app launch seed. Calendar
    /// preferences may be keyed by both a portable profile ID and a local
    /// EventKit ID, so they are deduplicated before reaching SwiftUI.
    /// When EventKit access is unavailable, stale calendar values are removed
    /// from the seed. Personal events remain safe to show while the runtime
    /// loads its authoritative local and CloudKit-backed data.
    func launchSnapshot(query: HLLEventQuery,
                        includeCalendarEvents: Bool = true) -> HLLLaunchSnapshot {
        let uniqueCalendars = Dictionary(calendars.values.map { ($0.id, $0) },
                                         uniquingKeysWith: { lhs, rhs in
            lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        }).values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let queriedEvents = self.query(query)
        let events = includeCalendarEvents
            ? queriedEvents
            : queriedEvents.filter { $0.source == .user }
        let userSeriesIDs = Set(userDefinitions.map { $0.id.uuidString })
        let hiddenAnnotations = annotations.filter { annotation in
            guard annotation.kind == .hidden else { return false }
            guard !includeCalendarEvents else { return true }
            return annotation.portableKey?.hasPrefix("user|") == true
                || annotation.seriesID.map(userSeriesIDs.contains) == true
                || annotation.eventID.map { userSeriesIDs.contains($0.uuidString) } == true
        }
        return HLLLaunchSnapshot(
            events: events,
            calendars: includeCalendarEvents ? uniqueCalendars : [],
            hiddenAnnotations: hiddenAnnotations,
            generatedAt: generatedAt)
    }
}
