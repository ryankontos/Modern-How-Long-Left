import Foundation

/// The small amount of derived state used by the app's current and upcoming
/// lists. This calculation touches only immutable values, so callers can run
/// it away from the UI actor without carrying EventKit or database objects.
public struct HLLEventClassification: Sendable {
    public let current: [HLLEvent]
    public let upcoming: [HLLEvent]
    public let nextBoundary: Date?

    public init(events: [HLLEvent], at date: Date) {
        var current: [HLLEvent] = []
        var upcoming: [HLLEvent] = []
        current.reserveCapacity(events.count)
        upcoming.reserveCapacity(events.count)
        var nextBoundary: Date?

        for event in events {
            switch event.status(at: date) {
            case .inProgress:
                current.append(event)
            case .upcoming:
                upcoming.append(event)
            case .complete:
                break
            }

            if event.start > date, nextBoundary.map({ event.start < $0 }) ?? true {
                nextBoundary = event.start
            }
            if event.end > date, nextBoundary.map({ event.end < $0 }) ?? true {
                nextBoundary = event.end
            }
        }

        self.current = current
        self.upcoming = upcoming
        self.nextBoundary = nextBoundary
    }
}
