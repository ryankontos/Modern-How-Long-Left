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

    public func notificationPreferences() async throws -> HLLNotificationPreferences {
        let values: [HLLNotificationPreferences] = try await database.all(
            HLLNotificationPreferences.self, kind: .notificationPreferences, location: .local)
        return values.first ?? HLLNotificationPreferences()
    }

    public func save(_ preferences: HLLNotificationPreferences) async throws {
        try await database.put(preferences, kind: .notificationPreferences,
                               key: "notifications", location: .local)
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

    /// Builds the portable portion of settings for extensions on another
    /// device. Device-local EventKit IDs are intentionally not included.
    public func sharedSettingsProjection(revision: UInt64,
                                         generatedAt: Date = .now) async throws -> HLLSharedSettingsProjection {
        async let appSettings = settings()
        async let profiles = calendarPreferences()
        async let events = userEvents()
        async let annotations = annotations()
        let allAnnotations = try await annotations
        let syncedAnnotations = allAnnotations.filter {
            $0.syncAcrossDevices && $0.portableKey != nil
        }
        return HLLSharedSettingsProjection(
            revision: revision,
            generatedAt: generatedAt,
            settings: try await appSettings,
            calendars: try await profiles,
            userDefinitions: try await events,
            annotations: syncedAnnotations)
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
                let sourceCandidates = profiles.filter {
                    guard let sourceIdentifier = calendar.sourceIdentifier,
                          !sourceIdentifier.isEmpty else { return false }
                    return $0.sourceIdentifier == sourceIdentifier
                        && $0.title == calendar.title
                        && $0.sourceTitle == calendar.sourceTitle
                }
                let titleCandidates = profiles.filter {
                    $0.title == calendar.title && $0.sourceTitle == calendar.sourceTitle
                }
                if sourceCandidates.count == 1 {
                    preference = sourceCandidates[0]
                } else if sourceCandidates.isEmpty && titleCandidates.count == 1 {
                    // This also adopts a profile created before source IDs
                    // were stored, without creating a second preference.
                    preference = titleCandidates[0]
                } else {
                    let identity = calendar.sourceIdentifier ?? calendar.localID
                    preference = HLLCalendarPreference(
                        id: HLLStableID.make(["calendar-profile", identity,
                                               calendar.title, calendar.sourceTitle]),
                        title: calendar.title,
                        sourceTitle: calendar.sourceTitle,
                        sourceIdentifier: calendar.sourceIdentifier)
                    try await save(preference)
                }
                let binding = HLLCalendarBinding(localCalendarID: calendar.localID,
                                                  profileID: preference.id)
                try await database.put(binding, kind: .calendarBinding,
                                       key: calendar.localID, location: .local)
            }
            result[calendar.localID] = preference
        }
        return result
    }

    /// EventKit can replace a calendar's local identifier after an account
    /// refresh. Keep current bindings, but remove aliases that can no longer
    /// be reached on this device so the local store stays bounded.
    public func pruneObsoleteCalendarBindings(keeping localIDs: Set<String>) async throws {
        guard !localIDs.isEmpty else { return }
        let bindings: [HLLCalendarBinding] = try await database.all(
            HLLCalendarBinding.self, kind: .calendarBinding, location: .local)
        for binding in bindings where !localIDs.contains(binding.localCalendarID) {
            try await database.remove(kind: .calendarBinding,
                                      key: binding.localCalendarID, location: .local)
        }
    }
}
