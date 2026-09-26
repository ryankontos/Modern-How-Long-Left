import Foundation

public struct HLLAppSettings: Codable, Sendable, Equatable {
    public var syncEventAnnotations: Bool = true
    public var updatedAt: Date = .now
    public init() {}
}

public struct HLLCalendarBinding: Codable, Sendable {
    public let localCalendarID: String
    public let profileID: UUID
}

/// Small, typed methods keep storage details out of the event pipeline and UI.
public actor HLLRepository {
    private let database: HLLDatabase

    public init(database: HLLDatabase) { self.database = database }

    public func settings() async throws -> HLLAppSettings {
        let values: [HLLAppSettings] = try await database.all(
            HLLAppSettings.self, kind: .preference, location: .cloud)
        return values.first ?? HLLAppSettings()
    }

    public func save(_ settings: HLLAppSettings) async throws {
        try await database.put(settings, kind: .preference, key: "app", location: .cloud)
    }

    public func widgetDefaults() async throws -> HLLWidgetDefaults {
        let values: [HLLWidgetDefaults] = try await database.all(
            HLLWidgetDefaults.self, kind: .widgetDefaults, location: .cloud)
        return values.first ?? HLLWidgetDefaults()
    }

    public func save(_ defaults: HLLWidgetDefaults) async throws {
        try await database.put(defaults, kind: .widgetDefaults,
                               key: "widget-defaults", location: .cloud)
    }

    public func userEvents() async throws -> [HLLUserEvent] {
        try await database.all(HLLUserEvent.self, kind: .userEvent, location: .cloud)
    }

    public func save(_ event: HLLUserEvent) async throws {
        try await database.put(event, kind: .userEvent, key: event.id.uuidString, location: .cloud)
    }

    public func deleteUserEvent(id: UUID) async throws {
        try await database.remove(kind: .userEvent, key: id.uuidString, location: .cloud)
    }

    /// Live Activity scheduling is device specific, so policies stay in the local store.
    public func activityPolicies() async throws -> [HLLLiveActivityPolicy] {
        try await database.all(HLLLiveActivityPolicy.self, kind: .activityPolicy, location: .local)
    }

    public func save(_ policy: HLLLiveActivityPolicy) async throws {
        try await database.put(policy, kind: .activityPolicy,
                               key: policy.id.uuidString, location: .local)
    }

    public func deleteActivityPolicy(id: UUID) async throws {
        try await database.remove(kind: .activityPolicy,
                                  key: id.uuidString, location: .local)
    }

    public func annotations() async throws -> [HLLEventAnnotation] {
        async let synced: [HLLEventAnnotation] = database.all(
            HLLEventAnnotation.self, kind: .annotation, location: .cloud)
        async let local: [HLLEventAnnotation] = database.all(
            HLLEventAnnotation.self, kind: .annotation, location: .local)
        let combined = (try await synced) + (try await local)
        return Array(Dictionary(combined.filter { $0.expiresAt.map { $0 > .now } ?? true }
            .map { ($0.id, $0) }, uniquingKeysWith: {
            $0.updatedAt >= $1.updatedAt ? $0 : $1
        }).values)
    }

    public func save(_ annotation: HLLEventAnnotation) async throws {
        let location: HLLDatabase.Location = annotation.syncAcrossDevices && annotation.portableKey != nil
            ? .cloud : .local
        try await database.put(annotation, kind: .annotation,
                               key: annotation.id.uuidString, location: location)
    }

    public func deleteAnnotation(id: UUID) async throws {
        try await database.remove(kind: .annotation, key: id.uuidString, location: .cloud)
        try await database.remove(kind: .annotation, key: id.uuidString, location: .local)
    }

    public func setAnnotationSync(_ enabled: Bool) async throws {
        let source: HLLDatabase.Location = enabled ? .local : .cloud
        let destination: HLLDatabase.Location = enabled ? .cloud : .local
        let values: [HLLEventAnnotation] = try await database.all(
            HLLEventAnnotation.self, kind: .annotation, location: source)
        for var annotation in values {
            if enabled && annotation.portableKey == nil { continue }
            annotation.syncAcrossDevices = enabled
            try await database.put(annotation, kind: .annotation,
                                   key: annotation.id.uuidString, location: destination)
            try await database.remove(kind: .annotation,
                                      key: annotation.id.uuidString, location: source)
        }
        var value = try await settings()
        value.syncEventAnnotations = enabled
        value.updatedAt = .now
        try await save(value)
    }

    public func pruneExpiredAnnotations(before date: Date) async throws {
        for location in [HLLDatabase.Location.cloud, .local] {
            let values: [HLLEventAnnotation] = try await database.all(
                HLLEventAnnotation.self, kind: .annotation, location: location)
            for annotation in values where annotation.expiresAt.map({ $0 < date }) ?? false {
                try await database.remove(kind: .annotation,
                                          key: annotation.id.uuidString, location: location)
            }
        }
    }

    public func calendarPreferences() async throws -> [HLLCalendarPreference] {
        async let profiles: [HLLCalendarPreference] = database.all(
            HLLCalendarPreference.self, kind: .calendar, location: .cloud)
        async let rules: [HLLCalendarVisibilityRule] = database.all(
            HLLCalendarVisibilityRule.self, kind: .calendarVisibility, location: .cloud)
        var byID = Dictionary(try await profiles.map { ($0.id, $0) },
                              uniquingKeysWith: { lhs, rhs in lhs.updatedAt >= rhs.updatedAt ? lhs : rhs })
        for rule in try await rules {
            byID[rule.calendarID]?.visibility[rule.context] = rule.isVisible
        }
        return Array(byID.values)
    }

    public func save(_ preference: HLLCalendarPreference) async throws {
        var metadata = preference
        metadata.visibility = [:]
        try await database.put(metadata, kind: .calendar,
                               key: preference.id.uuidString, location: .cloud)
    }

    public func setCalendarVisibility(profileID: UUID, context: HLLContextID,
                                      isVisible: Bool) async throws {
        let rule = HLLCalendarVisibilityRule(calendarID: profileID,
                                             context: context, isVisible: isVisible)
        try await database.put(rule, kind: .calendarVisibility,
                               key: rule.storageKey, location: .cloud)
    }

    /// Local bindings separate a synced calendar profile from volatile EventKit IDs.
    public func bind(_ calendars: [HLLEventKitSource.CalendarInfo]) async throws -> [String: HLLCalendarPreference] {
        let profiles = try await calendarPreferences()
        let bindings: [HLLCalendarBinding] = try await database.all(
            HLLCalendarBinding.self, kind: .calendarBinding, location: .local)
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { newer, _ in newer })
        let byLocalID = Dictionary(bindings.map { ($0.localCalendarID, $0.profileID) },
                                   uniquingKeysWith: { newer, _ in newer })
        var result: [String: HLLCalendarPreference] = [:]
        for calendar in calendars {
            let preference: HLLCalendarPreference
            if let profileID = byLocalID[calendar.localID], let existing = byID[profileID] {
                preference = existing
            } else {
                let candidates = profiles.filter {
                    $0.title == calendar.title && $0.sourceTitle == calendar.sourceTitle
                }
                preference = candidates.count == 1 ? candidates[0] : HLLCalendarPreference(
                    title: calendar.title, sourceTitle: calendar.sourceTitle)
                if candidates.count != 1 { try await save(preference) }
                let binding = HLLCalendarBinding(localCalendarID: calendar.localID,
                                                  profileID: preference.id)
                try await database.put(binding, kind: .calendarBinding,
                                       key: calendar.localID, location: .local)
            }
            result[calendar.localID] = preference
        }
        return result
    }
}
