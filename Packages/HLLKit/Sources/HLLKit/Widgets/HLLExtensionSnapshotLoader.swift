import Foundation

/// A widget refreshes EventKit itself when WidgetKit asks for a timeline.
/// It never opens the app's CloudKit mirror or requests calendar permission.
public struct HLLExtensionSnapshotLoader: Sendable {
    public init() {}

    public func load(groupIdentifier: String, now: Date = .now) async -> HLLWidgetPayload? {
        let cached = HLLWidgetSnapshotStore(groupIdentifier: groupIdentifier).read()
        let source = HLLEventKitSource()
        let interval = DateInterval(start: now.addingTimeInterval(-86_400),
                                    end: now.addingTimeInterval(14 * 86_400))
        let authorized = await source.authorizationStatus() == .fullAccess
        guard authorized else { return expandUserEvents(in: cached, interval: interval, now: now) }

        let raw = await source.events(in: interval)
        let existingByPortable = Dictionary((cached?.events ?? []).compactMap { event in
            event.portableKey.map { ($0, event) }
        }, uniquingKeysWith: { first, _ in first })
        let existingByFingerprint = Dictionary(grouping: (cached?.events ?? []).filter {
            $0.source == .eventKit
        }, by: fingerprint)
        var normalized: [HLLEvent] = []
        normalized.reserveCapacity(raw.count)
        for event in raw {
            let profile = cached?.calendars[event.calendarLocalID]
            let occurrence = String(event.occurrenceStart.timeIntervalSince1970)
            let portable = event.externalID.flatMap { external in
                profile.map { "\($0.id.uuidString)|\(external)|\(occurrence)" }
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
        let user = userOccurrences(from: cached, in: interval)
        return HLLWidgetPayload(revision: cached?.revision ?? 0, generatedAt: now,
                                expiresAt: interval.end, events: normalized + user,
                                userDefinitions: cached?.userDefinitions ?? [],
                                calendars: cached?.calendars ?? [:],
                                annotations: cached?.annotations ?? [])
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
