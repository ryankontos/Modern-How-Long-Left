import AppIntents
import Foundation

/// A configurable widget can follow one stable HLL event ID.
public struct HLLWidgetEventEntity: AppEntity, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Event" }
    public static var defaultQuery: HLLWidgetEventQuery { HLLWidgetEventQuery() }

    public let id: String
    public let title: String
    public let start: Date

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(start.formatted(date: .abbreviated, time: .shortened))")
    }

    public init(event: HLLEvent) {
        id = event.id.uuidString
        title = event.title
        start = event.start
    }
}

public struct HLLWidgetEventQuery: EntityQuery {
    public init() {}
    public static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }

    public func entities(for identifiers: [String]) async throws -> [HLLWidgetEventEntity] {
        let wanted = Set(identifiers)
        return await available().filter { wanted.contains($0.id) }
    }

    public func suggestedEntities() async throws -> [HLLWidgetEventEntity] {
        await available()
    }

    private func available() async -> [HLLWidgetEventEntity] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HLLAppGroupIdentifier") as? String,
              let payload = await HLLExtensionSnapshotLoader().load(
                  groupIdentifier: group,
                  cloudContainerIdentifier: HLLConfiguration.cloudContainerIdentifier) else { return [] }
        let context = HLLContextID(rawValue:
            (Bundle.main.object(forInfoDictionaryKey: "HLLContextID") as? String)
            ?? "widget.default")
        let now = Date()
        let query = HLLEventQuery(
            interval: DateInterval(start: now.addingTimeInterval(-86_400),
                                   end: now.addingTimeInterval(14 * 86_400)),
            rule: .upcoming(now), context: context, limit: 100)
        return payload.query(query).map(HLLWidgetEventEntity.init)
    }
}
