import Foundation

/// A widget refreshes EventKit itself when WidgetKit asks for a timeline.
/// It never opens the app's CloudKit mirror or requests calendar permission.
public struct HLLExtensionSnapshotLoader: Sendable {
    public init() {}

    public func load(groupIdentifier: String, cloudContainerIdentifier: String? = nil,
                     now: Date = .now) async -> HLLWidgetPayload? {
        let cached = HLLWidgetSnapshotStore(groupIdentifier: groupIdentifier).read()
        // Both records have the same short deadline. Fetching them together
        // prevents a settings projection from adding another CloudKit wait.
        async let cloudTask = cloudProjection(cloudContainerIdentifier)
        async let sharedTask = sharedProjection(cloudContainerIdentifier)
        let cloud = await cloudTask
        let shared = await sharedTask
        let platformSeed = [cached, cloud].compactMap { $0 }
            .max { $0.generatedAt < $1.generatedAt }
        let seed = merge(shared: shared, into: platformSeed, now: now)
        let source = HLLEventKitSource()
        let interval = DateInterval(start: now.addingTimeInterval(-86_400),
                                    end: now.addingTimeInterval(14 * 86_400))
        let authorized = await source.authorizationStatus() == .fullAccess
        guard authorized else { return expandUserEvents(in: seed, interval: interval, now: now) }

        let raw = await source.events(in: interval)
        let sharedProfiles = shared?.calendars ?? []
        var calendars = seed?.calendars ?? [:]
        for event in raw {
            if let profile = matchingProfile(for: event, in: sharedProfiles) {
                calendars[event.calendarLocalID] = profile
            }
        }
        let existingByPortable = Dictionary((seed?.events ?? []).compactMap { event in
            event.portableKey.map { ($0, event) }
        }, uniquingKeysWith: { first, _ in first })
        let existingByFingerprint = Dictionary(grouping: (seed?.events ?? []).filter {
            $0.source == .eventKit
        }, by: fingerprint)
        var normalized: [HLLEvent] = []
        normalized.reserveCapacity(raw.count)
        for event in raw {
            let profile = calendars[event.calendarLocalID]
            let occurrence = String(event.occurrenceStart.timeIntervalSince1970)
            let portable = event.externalID.flatMap { external in
                profile.map {
                    let suffix = event.hasRecurrence ? "|\(occurrence)" : ""
                    return "\($0.id.uuidString)|\(external)\(suffix)"
                }
            }
            let key = fingerprint(event)
            let uniqueMatch = existingByFingerprint[key].flatMap { $0.count == 1 ? $0.first : nil }
            let stableID = portable.flatMap { existingByPortable[$0]?.id } ?? uniqueMatch?.id
                ?? HLLStableID.make([event.calendarLocalID,
                                     event.externalID ?? event.localID ?? key, occurrence])
            let series = event.hasRecurrence ? [profile?.id.uuidString ?? event.calendarLocalID,
                                                event.externalID ?? event.localID ?? event.title]
                .joined(separator: "|") : nil
            normalized.append(HLLEvent(id: stableID, source: .eventKit, title: event.title,
                                       start: event.start, end: event.end,
                                       isAllDay: event.isAllDay, calendarID: event.calendarLocalID,
                                       seriesID: series, portableKey: portable,
                                       occurrenceStart: event.occurrenceStart,
                                       location: event.location, notes: event.notes))
        }
        let user = userOccurrences(from: seed, in: interval)
        return HLLWidgetPayload(revision: seed?.revision ?? 0, generatedAt: now,
                                expiresAt: interval.end, events: normalized + user,
                                userDefinitions: seed?.userDefinitions ?? [],
                                calendars: calendars,
                                annotations: seed?.annotations ?? [])
    }

    private func cloudProjection(_ identifier: String?) async -> HLLWidgetPayload? {
        guard let identifier, !identifier.isEmpty else { return nil }
        // CloudKit must not consume a widget's whole timeline budget offline.
        return await withTaskGroup(of: HLLWidgetPayload?.self) { group in
            group.addTask { await HLLCloudProjectionStore(containerIdentifier: identifier).read() }
            group.addTask {
                try? await Task.sleep(for: .seconds(1.5))
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }

    private func sharedProjection(_ identifier: String?) async -> HLLSharedSettingsProjection? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return await withTaskGroup(of: HLLSharedSettingsProjection?.self) { group in
            group.addTask { await HLLSharedSettingsProjectionStore(
                containerIdentifier: identifier).read() }
            group.addTask {
                try? await Task.sleep(for: .seconds(1.5))
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }

    private func merge(shared: HLLSharedSettingsProjection?,
                       into platform: HLLWidgetPayload?,
                       now: Date) -> HLLWidgetPayload? {
        guard let shared else { return platform }
        var calendars = platform?.calendars ?? [:]
        // Shared profiles are keyed by UUID until local EventKit IDs are
        // available. The direct EventKit pass below binds them by title/source.
        let platformCalendars = platform?.calendars ?? [:]
        let platformProfiles = Dictionary(platformCalendars.values.map { ($0.id, $0) },
                                          uniquingKeysWith: { newerCalendar($0, $1)! })
        for sharedProfile in shared.calendars {
            guard let profile = newerCalendar(platformProfiles[sharedProfile.id], sharedProfile) else {
                continue
            }
            calendars[profile.id.uuidString] = profile
            // Preserve an already-bound local ID when the extension has no
            // calendar permission yet. This keeps visibility rules effective
            // while the next authorized refresh rebinds by name/source.
            for (localID, existing) in platformCalendars where existing.id == profile.id {
                calendars[localID] = profile
            }
        }

        var definitions = Dictionary((platform?.userDefinitions ?? []).map { ($0.id, $0) },
                                     uniquingKeysWith: { newerUserEvent($0, $1)! })
        for definition in shared.userDefinitions {
            definitions[definition.id] = newerUserEvent(definitions[definition.id], definition)
        }

        // A device-local annotation may be intentionally unsynced. Merge by
        // logical ID and updatedAt instead of replacing the entire list with
        // the most recently uploaded cross-device projection.
        var annotations = Dictionary((platform?.annotations ?? []).map { ($0.id, $0) },
                                     uniquingKeysWith: { newerAnnotation($0, $1)! })
        for annotation in shared.annotations {
            annotations[annotation.id] = newerAnnotation(annotations[annotation.id], annotation)
        }

        return HLLWidgetPayload(revision: max(platform?.revision ?? 0, shared.revision),
                                generatedAt: max(platform?.generatedAt ?? .distantPast,
                                                 shared.generatedAt),
                                expiresAt: platform?.expiresAt ?? now.addingTimeInterval(14 * 86_400),
                                events: platform?.events ?? [],
                                userDefinitions: definitions.values.sorted { $0.start < $1.start },
                                calendars: calendars,
                                annotations: annotations.values.sorted { $0.updatedAt < $1.updatedAt })
    }

    private func newerCalendar(_ lhs: HLLCalendarPreference?,
                               _ rhs: HLLCalendarPreference?) -> HLLCalendarPreference? {
        switch (lhs, rhs) {
        case let (left?, right?): return left.updatedAt >= right.updatedAt ? left : right
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private func newerUserEvent(_ lhs: HLLUserEvent?, _ rhs: HLLUserEvent?) -> HLLUserEvent? {
        switch (lhs, rhs) {
        case let (left?, right?): return left.updatedAt >= right.updatedAt ? left : right
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private func newerAnnotation(_ lhs: HLLEventAnnotation?,
                                 _ rhs: HLLEventAnnotation?) -> HLLEventAnnotation? {
        switch (lhs, rhs) {
        case let (left?, right?): return left.updatedAt >= right.updatedAt ? left : right
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private func matchingProfile(for event: HLLEventKitSource.RawEvent,
                                 in profiles: [HLLCalendarPreference]) -> HLLCalendarPreference? {
        let sourceMatches = profiles.filter {
            guard let sourceIdentifier = event.calendarSourceIdentifier,
                  !sourceIdentifier.isEmpty else { return false }
            return $0.sourceIdentifier == sourceIdentifier
                && $0.title == event.calendarTitle
                && $0.sourceTitle == event.calendarSourceTitle
        }
        if sourceMatches.count == 1 { return sourceMatches[0] }
        let matches = profiles.filter {
            $0.title == event.calendarTitle && $0.sourceTitle == event.calendarSourceTitle
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func expandUserEvents(in cached: HLLWidgetPayload?, interval: DateInterval,
                                  now: Date) -> HLLWidgetPayload? {
        guard let cached else { return nil }
        let calendarEvents = cached.events.filter { $0.source == .eventKit && $0.end > now }
        return HLLWidgetPayload(revision: cached.revision, generatedAt: cached.generatedAt,
                                expiresAt: interval.end,
                                events: calendarEvents + userOccurrences(from: cached, in: interval),
                                userDefinitions: cached.userDefinitions,
                                calendars: cached.calendars, annotations: cached.annotations)
    }

    private func userOccurrences(from cached: HLLWidgetPayload?, in interval: DateInterval) -> [HLLEvent] {
        (cached?.userDefinitions ?? []).flatMap {
            HLLUserOccurrenceGenerator().occurrences(of: $0, in: interval)
        }
    }

    private func fingerprint(_ event: HLLEvent) -> String {
        [event.calendarID ?? "", event.title, String(event.start.timeIntervalSince1970),
         String(event.end.timeIntervalSince1970)].joined(separator: "|")
    }

    private func fingerprint(_ event: HLLEventKitSource.RawEvent) -> String {
        [event.calendarLocalID, event.title, String(event.start.timeIntervalSince1970),
         String(event.end.timeIntervalSince1970)].joined(separator: "|")
    }
}
