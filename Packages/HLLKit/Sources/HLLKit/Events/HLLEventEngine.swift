import Foundation

/// Owns the unified read path. Refresh invalidates a bounded cache and raises one revision.
public actor HLLEventEngine {
    private let eventKit: HLLEventKitSource
    private let repository: HLLRepository
    private let identities: HLLIdentityResolver
    private let reducer = HLLEventReducer()
    private let generator = HLLUserOccurrenceGenerator()
    private var cachedInterval: DateInterval?
    private var cachedEventKitEvents: [HLLEvent] = []
    private var revision: UInt64 = 0
    private var observers: [UUID: AsyncStream<UInt64>.Continuation] = [:]

    public var currentRevision: UInt64 { revision }

    public init(eventKit: HLLEventKitSource, repository: HLLRepository,
                identities: HLLIdentityResolver) {
        self.eventKit = eventKit
        self.repository = repository
        self.identities = identities
    }

    public func changes() -> AsyncStream<UInt64> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(revision)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    public func invalidate() {
        cachedInterval = nil
        cachedEventKitEvents = []
        revision &+= 1
        for observer in observers.values { observer.yield(revision) }
    }

    public func query(_ query: HLLEventQuery, now: Date = .now) async throws -> HLLEventSnapshot {
        let calendars = await eventKit.calendars()
        let preferences = try await repository.bind(calendars)
        // These reads share no mutable state. Running them together keeps
        // launch and EventKit-change refreshes bounded by the slowest source.
        async let userDefinitionsTask = repository.userEvents()
        async let annotationsTask = repository.annotations()
        async let sourceEventsTask = eventKitEvents(in: query.interval, preferences: preferences)
        let userDefinitions = try await userDefinitionsTask
        let annotations = try await annotationsTask
        let sourceEvents = try await sourceEventsTask
        let userEvents = userDefinitions.flatMap {
            generator.occurrences(of: $0, in: query.interval)
        }
        let filtered = reducer.reduce(sourceEvents + userEvents,
                                      query: query,
                                      calendarPreferences: preferences,
                                      annotations: annotations)
        return HLLEventSnapshot(revision: revision, generatedAt: now, events: filtered)
    }

    /// Produces one unfiltered projection that configurable extensions can query cheaply.
    public func widgetProjection(in interval: DateInterval, now: Date = .now) async throws -> HLLWidgetPayload {
        let calendars = await eventKit.calendars()
        let preferences = try await repository.bind(calendars)
        async let definitionsTask = repository.userEvents()
        async let annotationsTask = repository.annotations()
        async let sourceTask = eventKitEvents(in: interval, preferences: preferences)
        let definitions = try await definitionsTask
        let annotations = try await annotationsTask
        let source = try await sourceTask
        let user = definitions.flatMap { generator.occurrences(of: $0, in: interval) }
        return HLLWidgetPayload(revision: revision, generatedAt: now, expiresAt: interval.end,
                                events: source + user,
                                userDefinitions: definitions,
                                calendars: preferences,
                                annotations: annotations)
    }

    public func save(_ event: HLLUserEvent) async throws {
        try await repository.save(event)
        invalidate()
    }

    public func deleteUserEvent(id: UUID) async throws {
        try await repository.deleteUserEvent(id: id)
        invalidate()
    }

    public func save(_ annotation: HLLEventAnnotation) async throws {
        try await repository.save(annotation)
        invalidate()
    }

    public func removeAnnotation(id: UUID) async throws {
        try await repository.deleteAnnotation(id: id)
        invalidate()
    }

    public func setAnnotationSync(_ enabled: Bool) async throws {
        try await repository.setAnnotationSync(enabled)
        invalidate()
    }

    public func save(_ preference: HLLCalendarPreference) async throws {
        try await repository.save(preference)
        invalidate()
    }

    public func setCalendarVisibility(profileID: UUID, context: HLLContextID,
                                      isVisible: Bool) async throws {
        try await repository.setCalendarVisibility(profileID: profileID,
                                                   context: context, isVisible: isVisible)
        invalidate()
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func eventKitEvents(in interval: DateInterval,
                                preferences: [String: HLLCalendarPreference]) async throws -> [HLLEvent] {
        if let cachedInterval, cachedInterval.start <= interval.start,
           cachedInterval.end >= interval.end { return cachedEventKitEvents }
        let expanded = DateInterval(start: interval.start.addingTimeInterval(-86_400),
                                    end: interval.end.addingTimeInterval(86_400))
        let raw = await eventKit.events(in: expanded)
        var normalized: [HLLEvent] = []
        normalized.reserveCapacity(raw.count)
        for source in raw {
            let profile = preferences[source.calendarLocalID]
            let identity = try await identities.resolve(source, calendarProfileID: profile?.id)
            let series = source.hasRecurrence ? [profile?.id.uuidString ?? source.calendarLocalID,
                                                 source.externalID ?? source.localID ?? source.title]
                .joined(separator: "|") : nil
            normalized.append(HLLEvent(id: identity.id, source: .eventKit, title: source.title,
                                       start: source.start, end: source.end,
                                       isAllDay: source.isAllDay, calendarID: source.calendarLocalID,
                                       seriesID: series, portableKey: identity.portableKey,
                                       occurrenceStart: source.occurrenceStart,
                                       location: source.location, notes: source.notes))
        }
        cachedInterval = expanded
        cachedEventKitEvents = normalized
        return normalized
    }
}
