import Foundation

/// A compact, immutable projection for extensions. Only the app writes it.
public struct HLLWidgetPayload: Codable, Sendable {
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
