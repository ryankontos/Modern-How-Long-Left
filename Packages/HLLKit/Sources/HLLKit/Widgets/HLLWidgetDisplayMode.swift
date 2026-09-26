import AppIntents
import Foundation

/// Widget presentation choices sit above the composable HLLKit query rules.
public enum HLLWidgetDisplayMode: String, AppEnum, Sendable {
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

public enum HLLWidgetStyle: String, AppEnum, Sendable {
    case automatic, title, countdown, progress, detailed

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Style" }
    public static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.automatic: "Automatic", .title: "Title", .countdown: "Countdown",
         .progress: "Progress", .detailed: "Detailed"]
    }
}
