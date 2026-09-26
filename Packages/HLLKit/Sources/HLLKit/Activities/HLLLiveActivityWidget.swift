#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

/// Date-driven text and progress advance without waking the app every second.
public struct HLLLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: HLLLiveActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                Text(context.state.title).font(.headline).lineLimit(2)
                HStack {
                    Text(context.state.start > .now ? "Starts in" : "Ends in")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(targetDate(context.state), style: .timer).monospacedDigit()
                }
                ProgressView(timerInterval: context.state.start...context.state.end,
                             countsDown: false)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 8) {
                        Text(context.state.title).font(.headline).lineLimit(2)
                        Text(targetDate(context.state), style: .timer).monospacedDigit()
                        ProgressView(timerInterval: context.state.start...context.state.end,
                                     countsDown: false)
                    }
                }
            } compactLeading: {
                Image(systemName: "hourglass")
            } compactTrailing: {
                Text(targetDate(context.state), style: .timer)
                    .monospacedDigit().frame(maxWidth: 48)
            } minimal: {
                Image(systemName: "hourglass")
            }
        }
    }

    private func targetDate(_ state: HLLLiveActivityAttributes.ContentState) -> Date {
        Date() < state.start ? state.start : state.end
    }
}
#endif
