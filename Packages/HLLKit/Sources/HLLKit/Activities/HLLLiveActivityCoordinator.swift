#if os(iOS)
import ActivityKit
import Foundation

/// Reconciles real ActivityKit state with the same filtered events used everywhere else.
/// Automatic requests are made while the app is foregrounded; scheduled starts run later.
public actor HLLLiveActivityCoordinator {
    private let engine: HLLEventEngine
    private let repository: HLLRepository
    private let reducer = HLLEventReducer()
    private var isReconciling = false
    private var needsAnotherPass = false

    public init(engine: HLLEventEngine, repository: HLLRepository) {
        self.engine = engine
        self.repository = repository
    }

    public var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    public func activeEventKeys() -> Set<String> {
        Set(Activity<HLLLiveActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .pending }
            .map { $0.attributes.eventKey })
    }

    public func start(_ event: HLLEvent) throws {
        guard isEnabled else { throw HLLLiveActivityError.disabled }
        let key = Self.key(for: event)
        guard !activeEventKeys().contains(key) else { return }
        _ = try Activity.request(attributes: HLLLiveActivityAttributes(eventKey: key, policyID: nil),
                                 content: Self.content(for: event), pushType: nil)
    }

    public func stop(_ event: HLLEvent) async {
        let key = Self.key(for: event)
        for activity in Activity<HLLLiveActivityAttributes>.activities
            where activity.attributes.eventKey == key {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Only a bounded number of near-term activities are reserved for each policy.
    public func reconcile(now: Date = .now, mayStart: Bool) async throws {
        if isReconciling {
            needsAnotherPass = true
            return
        }
        isReconciling = true
        defer { isReconciling = false }
        repeat {
            needsAnotherPass = false
            try await performReconcile(now: Date(), mayStart: mayStart)
        } while needsAnotherPass
    }

    private func performReconcile(now: Date, mayStart: Bool) async throws {
        let policies = try await repository.activityPolicies()
        let interval = DateInterval(start: now.addingTimeInterval(-86_400),
                                    end: now.addingTimeInterval(14 * 86_400))
        let payload = try await engine.widgetProjection(in: interval, now: now)
        let existing = Activity<HLLLiveActivityAttributes>.activities
        var desired: [UUID: [HLLEvent]] = [:]
        for policy in policies {
            let query = HLLEventQuery(interval: interval, rule: .upcoming(now),
                                      context: policy.context)
            desired[policy.id] = reducer.reduce(payload.events, query: query,
                                                calendarPreferences: payload.calendars,
                                                annotations: payload.annotations)
                .filter { policy.includes($0, calendars: payload.calendars) }
                .prefix(3).map { $0 }
        }

        // Manual activities also obey hidden and calendar rules after a later edit.
        let manualQuery = HLLEventQuery(interval: interval, rule: .upcoming(now),
                                        context: "activity.default")
        let visibleManual = reducer.reduce(payload.events, query: manualQuery,
                                           calendarPreferences: payload.calendars,
                                           annotations: payload.annotations)
        let manualByKey = Dictionary(visibleManual.map { (Self.key(for: $0), $0) },
                                     uniquingKeysWith: { first, _ in first })
        for activity in existing {
            let event: HLLEvent?
            if let policyID = activity.attributes.policyID {
                event = desired[policyID]?.first { Self.key(for: $0) == activity.attributes.eventKey }
            } else {
                event = manualByKey[activity.attributes.eventKey]
            }
            guard let event else {
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            let state = HLLLiveActivityAttributes.ContentState(event: event)
            if activity.content.state != state {
                await activity.update(Self.content(for: event))
            }
        }

        guard mayStart, isEnabled else { return }
        var reserved = Set(existing.map { $0.attributes.eventKey })
        for policy in policies {
            for event in desired[policy.id] ?? [] {
                let key = Self.key(for: event)
                guard reserved.insert(key).inserted else { continue }
                let activation = event.start.addingTimeInterval(-policy.leadTime)
                let attributes = HLLLiveActivityAttributes(eventKey: key, policyID: policy.id)
                if activation > now.addingTimeInterval(5) {
                    let alert = AlertConfiguration(title: "Event starting soon",
                                                   body: "Open How Long Left to view your countdown.",
                                                   sound: .default)
                    _ = try Activity.request(attributes: attributes, content: Self.content(for: event),
                                             pushType: nil, style: .standard,
                                             alertConfiguration: alert, start: activation)
                } else {
                    _ = try Activity.request(attributes: attributes,
                                             content: Self.content(for: event), pushType: nil)
                }
            }
        }
    }

    private static func key(for event: HLLEvent) -> String {
        event.portableKey ?? event.id.uuidString
    }

    private static func content(for event: HLLEvent) -> ActivityContent<HLLLiveActivityAttributes.ContentState> {
        ActivityContent(state: .init(event: event), staleDate: event.end)
    }
}

public enum HLLLiveActivityError: LocalizedError {
    case disabled
    public var errorDescription: String? { "Live Activities are disabled for How Long Left." }
}
#endif
