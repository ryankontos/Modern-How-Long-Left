import Foundation

/// A compact, immutable projection for extensions. Only the app writes it.
public struct HLLWidgetPayload: Codable, Sendable {
    /// Keep the replaceable CloudKit/App Group record comfortably below
    /// CloudKit's record-size ceiling. The full event engine remains
    /// authoritative; this bound only applies to extension projections.
    public static let maxProjectionEvents = 512

    public let revision: UInt64
    public let generatedAt: Date
    public let expiresAt: Date
    public let events: [HLLEvent]
    public let userDefinitions: [HLLUserEvent]
    public let calendars: [String: HLLCalendarPreference]
    public let annotations: [HLLEventAnnotation]

    public init(revision: UInt64, generatedAt: Date, expiresAt: Date, events: [HLLEvent],
                userDefinitions: [HLLUserEvent],
                calendars: [String: HLLCalendarPreference], annotations: [HLLEventAnnotation]) {
        self.revision = revision
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.events = events
        self.userDefinitions = userDefinitions
        self.calendars = calendars
        self.annotations = annotations
    }

    public func query(_ query: HLLEventQuery) -> [HLLEvent] {
        HLLEventReducer().reduce(HLLEventIndex(events), query: query,
                                 calendarPreferences: calendars, annotations: annotations)
    }

    /// Compares only information that can change what an extension renders.
    /// Generation dates and revisions describe the refresh attempt, so using
    /// them here would spend WidgetKit reload budget on identical content.
    public func hasSameContent(as other: Self) -> Bool {
        ordered(events) == ordered(other.events)
            && userDefinitions.sorted(by: userOrder) == other.userDefinitions.sorted(by: userOrder)
            && calendars == other.calendars
            && annotations.sorted(by: annotationOrder) == other.annotations.sorted(by: annotationOrder)
    }

    /// Reduce a projection deterministically while retaining every pinned
    /// event that fits. Unpinned events are ordered by start time, which gives
    /// widgets the most useful nearby data when a calendar is unusually busy.
    public func limitingEvents(to limit: Int = HLLWidgetPayload.maxProjectionEvents) -> Self {
        guard limit > 0, events.count > limit else { return self }
        let pinned = events.filter { event in
            annotations.contains { $0.kind == .pinned && $0.applies(to: event) }
        }.sorted(by: Self.eventOrder)
        let unpinned = events.filter { event in
            !pinned.contains(where: { $0.id == event.id })
        }.sorted(by: Self.eventOrder)
        let selected = Array((pinned + unpinned).prefix(limit))
        return Self(revision: revision, generatedAt: generatedAt, expiresAt: expiresAt,
                    events: selected, userDefinitions: userDefinitions,
                    calendars: calendars, annotations: annotations)
    }

    private static func eventOrder(_ lhs: HLLEvent, _ rhs: HLLEvent) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.id.uuidString < rhs.id.uuidString
    }


    private func ordered(_ values: [HLLEvent]) -> [HLLEvent] {
        values.sorted(by: Self.eventOrder)
    }

    private func userOrder(_ lhs: HLLUserEvent, _ rhs: HLLUserEvent) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private func annotationOrder(_ lhs: HLLEventAnnotation, _ rhs: HLLEventAnnotation) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }
}

public struct HLLWidgetSnapshotStore: Sendable {
    public let groupIdentifier: String

    public init(groupIdentifier: String) { self.groupIdentifier = groupIdentifier }

    public func read() -> HLLWidgetPayload? {
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HLLWidgetPayload.self, from: data)
    }

    public func write(_ payload: HLLWidgetPayload) throws {
        guard let url = fileURL() else { throw HLLWidgetStoreError.appGroupUnavailable }
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
    }

    private func fileURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appending(path: "HLLWidgetSnapshot.json")
    }
}

public enum HLLWidgetStoreError: Error { case appGroupUnavailable }
