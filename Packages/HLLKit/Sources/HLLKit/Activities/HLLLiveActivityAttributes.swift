#if os(iOS)
import ActivityKit
import Foundation

/// ActivityKit receives a small, immutable event identity and dated display state.
public struct HLLLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var start: Date
        public var end: Date
        public var isAllDay: Bool

        public init(event: HLLEvent) {
            title = event.title
            start = event.start
            end = event.end
            isAllDay = event.isAllDay
        }
    }

    public var eventKey: String
    public var policyID: UUID?

    public init(eventKey: String, policyID: UUID?) {
        self.eventKey = eventKey
        self.policyID = policyID
    }
}
#endif
