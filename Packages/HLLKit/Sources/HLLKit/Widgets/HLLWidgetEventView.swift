import SwiftUI
import WidgetKit

/// Both widget extensions use the same small, family-aware presentation.
public struct HLLWidgetEventView: View {
    public let events: [HLLEvent]
    public let date: Date
    public let style: HLLWidgetStyle
    public let isLocked: Bool
    @Environment(\.widgetFamily) private var family

    public init(events: [HLLEvent], date: Date, style: HLLWidgetStyle = .automatic,
                isLocked: Bool = false) {
        self.events = events
        self.date = date
        self.style = style
        self.isLocked = isLocked
    }

    public var body: some View {
        Group {
            if isLocked {
                lockedContent
            } else {
                switch family {
            case .accessoryInline:
                Text(inlineText)
            case .accessoryCircular:
                circularContent
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text(events.first?.title ?? "No events").font(.headline).lineLimit(1)
                    if let first = events.first { compactDetail(for: first) }
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Label("How Long Left", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                    if events.isEmpty {
                        Text("No upcoming events").font(.headline)
                    } else {
                        ForEach(events.prefix(maxRows)) { event in
                            eventLine(event)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding()
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var lockedContent: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.title3)
            Text("Unlock How Long Left")
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inlineText: String {
        guard let first = events.first else { return "No events" }
        if style == .title { return first.title }
        return "\(first.title) · \(targetDate(for: first).formatted(.relative(presentation: .numeric)))"
    }

    private var maxRows: Int {
#if os(watchOS)
        2
#else
        family == .systemSmall ? 2 : 4
#endif
    }

    @ViewBuilder private var circularContent: some View {
        if let first = events.first {
            if style == .progress {
                Gauge(value: progress(for: first)) {
                    Image(systemName: "hourglass")
                } currentValueLabel: {
                    Text(Int(progress(for: first) * 100).formatted()).font(.caption2)
                }
                .gaugeStyle(.accessoryCircular)
            } else {
                VStack(spacing: 1) {
                    Image(systemName: "hourglass")
                    if style == .title {
                        Text(first.title).font(.caption2).lineLimit(1)
                    } else {
                        Text(targetDate(for: first), style: .timer)
                            .font(.caption2).minimumScaleFactor(0.5)
                    }
                }
            }
        } else {
            Image(systemName: "calendar")
        }
    }

    @ViewBuilder private func compactDetail(for event: HLLEvent) -> some View {
        if style == .progress {
            ProgressView(value: progress(for: event))
        } else if style == .title {
            Text(event.start, format: .dateTime.hour().minute()).font(.caption)
        } else {
            Text(targetDate(for: event), style: .timer).font(.caption)
        }
    }

    @ViewBuilder private func eventLine(_ event: HLLEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.title).lineLimit(1)
                Spacer(minLength: 4)
                if style != .title {
                    Text(targetDate(for: event), style: .timer)
                        .font(.caption).monospacedDigit()
                }
            }
            if style == .progress || style == .detailed {
                ProgressView(value: progress(for: event))
            }
        }
    }

    private func targetDate(for event: HLLEvent) -> Date {
        date < event.start ? event.start : event.end
    }

    private func progress(for event: HLLEvent) -> Double {
        guard event.end > event.start else { return 1 }
        return min(max(date.timeIntervalSince(event.start) / event.end.timeIntervalSince(event.start), 0), 1)
    }
}
