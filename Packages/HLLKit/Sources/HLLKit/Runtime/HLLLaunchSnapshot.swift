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
    func launchSnapshot(query: HLLEventQuery) -> HLLLaunchSnapshot {
        let uniqueCalendars = Dictionary(calendars.values.map { ($0.id, $0) },
                                         uniquingKeysWith: { lhs, rhs in
            lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        }).values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return HLLLaunchSnapshot(
            events: self.query(query),
            calendars: uniqueCalendars,
            hiddenAnnotations: annotations.filter { $0.kind == .hidden },
            generatedAt: generatedAt)
    }
}
