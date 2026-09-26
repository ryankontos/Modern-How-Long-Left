#if os(watchOS)
import AppIntents
import Foundation
import SwiftUI
import WidgetKit

/// One event card suggested in the watch Smart Stack when it is timely.
/// The event is re-read before display so a deleted or hidden event disappears.
public struct HLLRelevantEventEntry: RelevanceEntry {
    public let event: HLLEvent?
    public let date: Date
    public let isLocked: Bool

    public init(event: HLLEvent?, date: Date, isLocked: Bool = false) {
        self.event = event
        self.date = date
        self.isLocked = isLocked
    }
}

/// Provides separate Smart Stack suggestions for the next few events.
/// WidgetKit still chooses whether and when to display each suggestion.
public struct HLLRelevantEventProvider: RelevanceEntriesProvider {
    public typealias Configuration = HLLWidgetConfigurationIntent
    public typealias Entry = HLLRelevantEventEntry

    private let contextID: HLLContextID
    private let groupIdentifier: String
    private let cloudContainerIdentifier: String?

    public init(contextID: HLLContextID, groupIdentifier: String,
                cloudContainerIdentifier: String?) {
        self.contextID = contextID
        self.groupIdentifier = groupIdentifier
        self.cloudContainerIdentifier = cloudContainerIdentifier
    }

    /// Suggest a small, bounded set so a busy calendar can't make relevance
    /// calculation slow or create an unhelpful number of cards.
    public func relevance() async -> WidgetRelevance<HLLWidgetConfigurationIntent> {
        let now = Date()
        guard await isUnlocked(at: now), let payload = await loadPayload(at: now) else {
            return WidgetRelevance([])
        }

        let events = visibleEvents(in: payload, at: now)
        let attributes = events.prefix(6).map { event in
            WidgetRelevanceAttribute(
                configuration: configuration(for: event),
                context: relevanceContext(for: event, now: now)
            )
        }
        return WidgetRelevance(attributes)
    }

    /// WidgetKit asks for an entry only when a relevance suggestion is shown.
    /// Re-read current state and re-apply hides and calendar preferences here.
    public func entry(configuration: HLLWidgetConfigurationIntent,
                      context: Context) async throws -> HLLRelevantEventEntry {
        let now = Date()
        // Keep real calendar data out of the settings preview.
        guard !context.isPreview else {
            return HLLRelevantEventEntry(event: nil, date: now)
        }
        guard await isUnlocked(at: now) else {
            return HLLRelevantEventEntry(event: nil, date: now, isLocked: true)
        }
        guard let selectedID = configuration.event?.id,
              let payload = await loadPayload(at: now) else {
            return HLLRelevantEventEntry(event: nil, date: now)
        }

        let event = visibleEvents(in: payload, at: now).first {
            $0.id.uuidString == selectedID || $0.portableKey == selectedID
        }
        return HLLRelevantEventEntry(event: event, date: now)
    }

    public func placeholder(context: Context) -> HLLRelevantEventEntry {
        HLLRelevantEventEntry(event: nil, date: .now)
    }

    private func isUnlocked(at date: Date) async -> Bool {
        let store = HLLPurchaseSnapshotStore(
            groupIdentifier: groupIdentifier,
            cloudContainerIdentifier: cloudContainerIdentifier
        )
        let snapshot = await HLLPurchaseEntitlementReader(store: store).read()
        return snapshot.isUnlocked(.complications, at: date)
    }

    private func loadPayload(at date: Date) async -> HLLWidgetPayload? {
        await HLLExtensionSnapshotLoader().load(
            groupIdentifier: groupIdentifier,
            cloudContainerIdentifier: cloudContainerIdentifier,
            now: date
        )
    }

    /// Both the suggestion list and its eventual card use the same reducer,
    /// so hidden events and per-surface calendar choices stay consistent.
    private func visibleEvents(in payload: HLLWidgetPayload, at date: Date) -> [HLLEvent] {
        let interval = DateInterval(start: date.addingTimeInterval(-86_400),
                                    end: date.addingTimeInterval(2 * 86_400))
        let query = HLLEventQuery(interval: interval, rule: .upcoming(date),
                                  context: contextID)
        return HLLWidgetSortOrder.countdownDate.sort(payload.query(query), at: date)
    }

    private func configuration(for event: HLLEvent) -> HLLWidgetConfigurationIntent {
        let intent = HLLWidgetConfigurationIntent()
        intent.event = HLLWidgetEventEntity(event: event)
        intent.mode = .all
        intent.includeAllDay = true
        intent.style = .detailed
        intent.sortOrder = .countdownDate
        intent.count = 1
        return intent
    }

    /// Make a card relevant shortly before an event and keep it relevant while
    /// the event is running. WidgetKit owns the final Smart Stack schedule.
    private func relevanceContext(for event: HLLEvent, now: Date) -> RelevantContext {
        let start = max(now, event.start.addingTimeInterval(-30 * 60))
        let end = max(event.end, start.addingTimeInterval(60))
        return .date(interval: DateInterval(start: start, end: end), kind: .scheduled)
    }
}

/// Relevance cards complement the configurable watch-face complication.
/// `associatedKind` lets a relevant card replace the timeline widget in the
/// Smart Stack instead of showing duplicate copies of the same event.
public struct HLLRelevantEventsWidget: Widget {
    private let kind: String
    private let associatedKind: String
    private let contextID: HLLContextID
    private let groupIdentifier: String
    private let cloudContainerIdentifier: String?

    public init() {
        self.init(kind: "HLLRelevantEvents",
                  associatedKind: "HowLongLeftComplications",
                  contextID: "complication.default",
                  groupIdentifier: HLLConfiguration.appGroupIdentifier,
                  cloudContainerIdentifier: HLLConfiguration.cloudContainerIdentifier)
    }

    public init(kind: String, associatedKind: String,
                contextID: HLLContextID, groupIdentifier: String,
                cloudContainerIdentifier: String?) {
        self.kind = kind
        self.associatedKind = associatedKind
        self.contextID = contextID
        self.groupIdentifier = groupIdentifier
        self.cloudContainerIdentifier = cloudContainerIdentifier
    }

    public var body: some WidgetConfiguration {
        RelevanceConfiguration(
            kind: kind,
            provider: HLLRelevantEventProvider(
                contextID: contextID,
                groupIdentifier: groupIdentifier,
                cloudContainerIdentifier: cloudContainerIdentifier
            )
        ) { entry in
            HLLWidgetEventView(events: entry.event.map { [$0] } ?? [],
                               date: entry.date,
                               style: .detailed,
                               isLocked: entry.isLocked)
        }
        .configurationDisplayName("Next Events")
        .description("See the next event when it matters.")
        .associatedKind(associatedKind)
    }
}
#endif
