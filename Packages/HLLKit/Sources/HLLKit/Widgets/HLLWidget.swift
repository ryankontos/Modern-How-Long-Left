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

    @Parameter(title: "Number of Events", default: 3)
    public var count: Int

    public init() {}
}

public struct HLLWidgetEntry: TimelineEntry {
    public let date: Date
    public let events: [HLLEvent]
    public let style: HLLWidgetStyle
}

/// WidgetKit reads a small snapshot; the app refreshes it after observed changes.
public struct HLLWidgetProvider: AppIntentTimelineProvider {
    public typealias Intent = HLLWidgetConfigurationIntent
    public typealias Entry = HLLWidgetEntry

    private let contextID: HLLContextID
    private let groupIdentifier: String
    private let cloudContainerIdentifier: String?

    public init(contextID: HLLContextID, groupIdentifier: String,
                cloudContainerIdentifier: String?) {
        self.contextID = contextID
        self.groupIdentifier = groupIdentifier
        self.cloudContainerIdentifier = cloudContainerIdentifier
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
        return Timeline(entries: entries.isEmpty ? [HLLWidgetEntry(date: now, events: [], style: configuration.style)] : entries,
                        policy: .after(now.addingTimeInterval(30 * 60)))
    }

    private func entries(for configuration: HLLWidgetConfigurationIntent) async -> [HLLWidgetEntry] {
        let now = Date()
        let payload = await HLLExtensionSnapshotLoader().load(
            groupIdentifier: groupIdentifier,
            cloudContainerIdentifier: cloudContainerIdentifier,
            now: now)
        let mode = configuration.mode
        let selectedID = configuration.event?.id
        let includeAllDay = configuration.includeAllDay
        let count = mode == .current ? 1 : min(max(configuration.count, 1), 6)
        let points = HLLWidgetTimelinePlanner().plan(
            payload: payload, now: now, context: contextID,
            limit: count,
            updateProgress: configuration.style == .progress || configuration.style == .detailed,
            rule: { date in
                var rules: [HLLEventRule] = [mode.rule(at: date)]
                if !includeAllDay { rules.append(.allDay(false)) }
                if let selectedID { rules.append(.custom { $0.id.uuidString == selectedID }) }
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

    public init() {
#if os(watchOS)
        self.init(kind: "HLLWidget", contextID: "default",
                  groupIdentifier: "", families: [.accessoryRectangular])
#else
        self.init(kind: "HLLWidget", contextID: "default",
                  groupIdentifier: "", families: [.systemSmall])
#endif
    }

    public init(kind: String, contextID: HLLContextID, groupIdentifier: String,
                cloudContainerIdentifier: String? = nil,
                families: [WidgetFamily]) {
        self.kind = kind
        self.contextID = contextID
        self.groupIdentifier = groupIdentifier
        self.cloudContainerIdentifier = cloudContainerIdentifier
        self.families = families
    }

    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: HLLWidgetConfigurationIntent.self,
                               provider: HLLWidgetProvider(contextID: contextID,
                                                           groupIdentifier: groupIdentifier,
                                                           cloudContainerIdentifier: cloudContainerIdentifier)) { entry in
            HLLWidgetEventView(events: entry.events, date: entry.date, style: entry.style)
        }
        .configurationDisplayName("How Long Left")
        .description("Current and upcoming events at a glance.")
        .supportedFamilies(families)
    }
}
