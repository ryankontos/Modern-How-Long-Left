import AppIntents
import SwiftUI
import WidgetKit

/// One configuration contract is shared by iOS widgets and watch complications.
public struct HLLWidgetConfigurationIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource { "How Long Left" }
    public static var description: IntentDescription { "Choose which events appear." }
    public static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }

    @Parameter(title: "Show", default: .current)
    public var mode: HLLWidgetDisplayMode

    @Parameter(title: "Include All Day Events", default: true)
    public var includeAllDay: Bool

    @Parameter(title: "Specific Event")
    public var event: HLLWidgetEventEntity?

    @Parameter(title: "Style", default: .automatic)
    public var style: HLLWidgetStyle

    @Parameter(title: "Order", default: .countdownDate)
    public var sortOrder: HLLWidgetSortOrder

    @Parameter(title: "Number of Events", default: 3)
    public var count: Int

    public init() {}
}

public struct HLLWidgetEntry: TimelineEntry {
    public let date: Date
    public let events: [HLLEvent]
    public let style: HLLWidgetStyle

    /// Locked entries are still valid timeline entries. Rendering a lock
    /// instead of stale event data keeps a revoked entitlement private.
    public let isLocked: Bool

    public init(date: Date, events: [HLLEvent], style: HLLWidgetStyle,
                isLocked: Bool = false) {
        self.date = date
        self.events = events
        self.style = style
        self.isLocked = isLocked
    }
}

/// WidgetKit reads a small snapshot; the app refreshes it after observed changes.
public struct HLLWidgetProvider: AppIntentTimelineProvider {
    public typealias Intent = HLLWidgetConfigurationIntent
    public typealias Entry = HLLWidgetEntry

    private let contextID: HLLContextID
    private let groupIdentifier: String
    private let cloudContainerIdentifier: String?
    private let requiredFeature: HLLPaidFeature

    public init(contextID: HLLContextID, groupIdentifier: String,
                cloudContainerIdentifier: String?,
                requiredFeature: HLLPaidFeature = .widgets) {
        self.contextID = contextID
        self.groupIdentifier = groupIdentifier
        self.cloudContainerIdentifier = cloudContainerIdentifier
        self.requiredFeature = requiredFeature
    }

    /// watchOS requires this method; an empty list leaves configuration to the user.
    public func recommendations() -> [AppIntentRecommendation<HLLWidgetConfigurationIntent>] { [] }

    public func placeholder(in context: Context) -> HLLWidgetEntry {
        HLLWidgetEntry(date: .now, events: [], style: .automatic)
    }

    public func snapshot(for configuration: HLLWidgetConfigurationIntent,
                         in context: Context) async -> HLLWidgetEntry {
        await entries(for: configuration).first ?? HLLWidgetEntry(date: .now, events: [], style: configuration.style)
    }

    public func timeline(for configuration: HLLWidgetConfigurationIntent,
                         in context: Context) async -> Timeline<HLLWidgetEntry> {
        let now = Date()
        let entries = await entries(for: configuration)
#if os(watchOS)
        // A watch with an active complication receives a larger refresh budget.
        // Known transitions are already in the timeline; this cadence mainly
        // discovers edits made in Calendar while both apps are closed.
        let refreshInterval: TimeInterval = 15 * 60
#else
        let refreshInterval: TimeInterval = 30 * 60
#endif
        return Timeline(entries: entries.isEmpty ? [HLLWidgetEntry(date: now, events: [], style: configuration.style)] : entries,
                        policy: .after(now.addingTimeInterval(refreshInterval)))
    }

    private func entries(for configuration: HLLWidgetConfigurationIntent) async -> [HLLWidgetEntry] {
        let now = Date()
        let purchaseStore = HLLPurchaseSnapshotStore(
            groupIdentifier: groupIdentifier,
            cloudContainerIdentifier: cloudContainerIdentifier)
        let purchase = await HLLPurchaseEntitlementReader(store: purchaseStore).read()
        guard purchase.isUnlocked(requiredFeature, at: now) else {
            return [HLLWidgetEntry(date: now, events: [], style: configuration.style,
                                   isLocked: true)]
        }
        let payload = await HLLExtensionSnapshotLoader().load(
            groupIdentifier: groupIdentifier,
            cloudContainerIdentifier: cloudContainerIdentifier,
            now: now)
        let mode = configuration.mode
        let sortOrder = configuration.sortOrder
        let selectedID = configuration.event?.id
        let includeAllDay = configuration.includeAllDay
        let count = (mode == .current || mode == .soonestCountdown)
            ? 1 : min(max(configuration.count, 1), 6)
        let points = HLLWidgetTimelinePlanner().plan(
            payload: payload, now: now, context: contextID,
            limit: count,
            updateProgress: configuration.style == .progress || configuration.style == .detailed,
            sortOrder: mode == .soonestCountdown ? .countdownDate : sortOrder,
            rule: { date in
                var rules: [HLLEventRule] = [mode.rule(at: date)]
                if !includeAllDay { rules.append(.allDay(false)) }
                if let selectedID {
                    rules.append(.custom {
                        $0.id.uuidString == selectedID || $0.portableKey == selectedID
                    })
                }
                return .and(rules)
            })
        return points.map { HLLWidgetEntry(date: $0.date, events: $0.events,
                                           style: configuration.style) }
    }
}

/// The extension chooses its kind and supported families; all behavior stays shared.
public struct HLLWidget: Widget {
    private let kind: String
    private let contextID: HLLContextID
    private let groupIdentifier: String
    private let cloudContainerIdentifier: String?
    private let families: [WidgetFamily]
    private let requiredFeature: HLLPaidFeature

    public init() {
#if os(watchOS)
        self.init(kind: "HLLWidget", contextID: "default",
                  groupIdentifier: "", families: [.accessoryRectangular],
                  requiredFeature: .widgets)
#else
        self.init(kind: "HLLWidget", contextID: "default",
                  groupIdentifier: "", families: [.systemSmall],
                  requiredFeature: .widgets)
#endif
    }

    public init(kind: String, contextID: HLLContextID, groupIdentifier: String,
                cloudContainerIdentifier: String? = nil,
                families: [WidgetFamily],
                requiredFeature: HLLPaidFeature = .widgets) {
        self.kind = kind
        self.contextID = contextID
        self.groupIdentifier = groupIdentifier
        self.cloudContainerIdentifier = cloudContainerIdentifier
        self.families = families
        self.requiredFeature = requiredFeature
    }

    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: HLLWidgetConfigurationIntent.self,
                               provider: HLLWidgetProvider(contextID: contextID,
                                                           groupIdentifier: groupIdentifier,
                                                           cloudContainerIdentifier: cloudContainerIdentifier,
                                                           requiredFeature: requiredFeature)) { entry in
            HLLWidgetEventView(events: entry.events, date: entry.date, style: entry.style,
                               isLocked: entry.isLocked)
        }
        .configurationDisplayName("How Long Left")
        .description("Current and upcoming events at a glance.")
        .supportedFamilies(families)
    }
}
