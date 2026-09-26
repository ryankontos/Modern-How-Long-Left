import Foundation

/// Calendar metadata already resolved while composing an event query. Returning
/// it with the events prevents app targets from repeating the same Core Data
/// and EventKit reads just to populate a settings screen.
public struct HLLBoundCalendar: Sendable {
    public let localID: String
    public let preference: HLLCalendarPreference
}

/// One coherent read of every source needed by the visible event list.
public struct HLLEventQueryResult: Sendable {
    public let snapshot: HLLEventSnapshot
    public let calendars: [HLLBoundCalendar]
    public let annotations: [HLLEventAnnotation]
}

/// Owns the unified read path. Refresh invalidates a bounded cache and raises one revision.
public actor HLLEventEngine {
    private struct SourceBundle: Sendable {
        let calendars: [HLLEventKitSource.CalendarInfo]
        let preferences: [String: HLLCalendarPreference]
        let userDefinitions: [HLLUserEvent]
        let annotations: [HLLEventAnnotation]
    }

    private let eventKit: HLLEventKitSource
    private let repository: HLLRepository
    private let identities: HLLIdentityResolver
    private let reducer = HLLEventReducer()
    private let generator = HLLUserOccurrenceGenerator()
    private var cachedInterval: DateInterval?
    private var cachedEventKitEvents: [HLLEvent] = []
    /// Repository values are immutable for the lifetime of one engine
    /// revision. Foreground and extension projections can safely reuse them.
    private var cachedSources: SourceBundle?
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
        cachedSources = nil
        revision &+= 1
        for observer in observers.values { observer.yield(revision) }
    }

    public func query(_ query: HLLEventQuery, now: Date = .now) async throws -> HLLEventSnapshot {
        try await queryResult(query, now: now).snapshot
    }

    /// Preferred app read path. EventKit calendars, their durable profiles,
    /// annotations, and events are fetched once and returned as immutable values.
    public func queryResult(_ query: HLLEventQuery,
                            now: Date = .now) async throws -> HLLEventQueryResult {
        let startingRevision = revision
        let sources = try await sourceBundle()
        let sourceEvents = try await eventKitEvents(in: query.interval,
                                                    preferences: sources.preferences)
        // Actors are reentrant at every await. If EventKit or CloudKit changed
        // mid-read, restart instead of publishing a mixed-revision snapshot.
        guard revision == startingRevision else {
            return try await queryResult(query, now: now)
        }
        let userDefinitions = sources.userDefinitions
        let annotations = sources.annotations
        let userEvents = userDefinitions.flatMap {
            generator.occurrences(of: $0, in: query.interval)
        }
        let filtered = reducer.reduce(sourceEvents + userEvents,
                                      query: query,
                                      calendarPreferences: sources.preferences,
                                      annotations: annotations)
        let snapshot = HLLEventSnapshot(revision: revision, generatedAt: now, events: filtered)
        let bound = sources.calendars.compactMap { calendar in
            sources.preferences[calendar.localID].map {
                HLLBoundCalendar(localID: calendar.localID, preference: $0)
            }
        }
        return HLLEventQueryResult(snapshot: snapshot, calendars: bound,
                                   annotations: annotations)
    }

    /// Produces one unfiltered projection that configurable extensions can query cheaply.
    public func widgetProjection(in interval: DateInterval, now: Date = .now) async throws -> HLLWidgetPayload {
        let startingRevision = revision
        let sources = try await sourceBundle()
        let source = try await eventKitEvents(in: interval, preferences: sources.preferences)
        guard revision == startingRevision else {
            return try await widgetProjection(in: interval, now: now)
        }
        let definitions = sources.userDefinitions
        let annotations = sources.annotations
        let user = definitions.flatMap { generator.occurrences(of: $0, in: interval) }
        return HLLWidgetPayload(revision: revision, generatedAt: now, expiresAt: interval.end,
                                events: source + user,
                                userDefinitions: definitions,
                                calendars: sources.preferences,
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

    /// Loads the small settings side of event composition once per revision.
    /// Event intervals remain independently cached because list and widget
    /// windows can differ while these values remain identical.
    private func sourceBundle() async throws -> SourceBundle {
        if let cachedSources { return cachedSources }
        let startingRevision = revision
        let calendars = await eventKit.calendars()
        let preferences = try await repository.bind(calendars)
        async let definitionsTask = repository.userEvents()
        async let annotationsTask = repository.annotations()
        let bundle = try await SourceBundle(
            calendars: calendars,
            preferences: preferences,
            userDefinitions: definitionsTask,
            annotations: annotationsTask)
        guard revision == startingRevision else { return try await sourceBundle() }
        cachedSources = bundle
        return bundle
    }

    private func eventKitEvents(in interval: DateInterval,
                                preferences: [String: HLLCalendarPreference]) async throws -> [HLLEvent] {
        if let cachedInterval, cachedInterval.start <= interval.start,
           cachedInterval.end >= interval.end { return cachedEventKitEvents }
        let expanded = DateInterval(start: interval.start.addingTimeInterval(-86_400),
                                    end: interval.end.addingTimeInterval(86_400))
        let startingRevision = revision
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
        // The caller owns the coherent-query retry because a new revision may
        // also require different calendar profiles. Do not cache this stale pass.
        guard revision == startingRevision else { return normalized }
        cachedInterval = expanded
        cachedEventKitEvents = normalized
        return normalized
    }
}
