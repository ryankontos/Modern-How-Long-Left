import AppIntents
import Foundation

/// Widget presentation choices sit above the composable HLLKit query rules.
public enum HLLWidgetDisplayMode: String, AppEnum, Codable, Sendable {
    case current
    case inProgress
    case all

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Events to Show" }
    public static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.current: "Current or Next", .inProgress: "In Progress", .all: "All Upcoming"]
    }

    public func rule(at date: Date) -> HLLEventRule {
        switch self {
        case .current, .all: .upcoming(date)
        case .inProgress: .running(date)
        }
    }
}

public enum HLLWidgetStyle: String, AppEnum, Codable, Sendable {
    case automatic, title, countdown, progress, detailed

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Style" }
    public static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.automatic: "Automatic", .title: "Title", .countdown: "Countdown",
         .progress: "Progress", .detailed: "Detailed"]
    }
}

/// Optional defaults shown in the app's widget settings screen.
///
/// WidgetKit still owns each widget's actual configuration. These values are
/// a lightweight preference for future widget creation and are kept separate
/// from WidgetKit's per-widget AppIntent state.
public struct HLLWidgetDefaults: Codable, Sendable, Equatable {
    public var mode: HLLWidgetDisplayMode
    public var style: HLLWidgetStyle
    public var includeAllDay: Bool
    public var eventCount: Int

    public init(mode: HLLWidgetDisplayMode = .current,
                style: HLLWidgetStyle = .automatic,
                includeAllDay: Bool = true,
                eventCount: Int = 3) {
        self.mode = mode
        self.style = style
        self.includeAllDay = includeAllDay
        self.eventCount = min(max(eventCount, 1), 6)
    }
}
