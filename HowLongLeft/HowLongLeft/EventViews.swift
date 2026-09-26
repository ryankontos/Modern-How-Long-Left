import HLLKit
import SwiftUI

/// The reusable event card. System-owned timer and progress views keep the
/// countdown smooth without a per-row task or a per-second list rebuild.
struct HLLEventCard: View {
    let event: HLLEvent

    private var isRunning: Bool { event.status() == .inProgress }
    private var accent: Color {
        if isRunning { return .orange }
        return event.source == .user ? .indigo : .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent.gradient)
                    .frame(width: 5)
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title).font(.headline).lineLimit(2)
                    HStack(spacing: 6) {
                        Image(systemName: event.source == .user ? "person.fill" : "calendar")
                        Text(eventTime)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(isRunning ? event.end : event.start,
                         style: isRunning ? .timer : .relative)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(accent)
                    Text(isRunning ? "left" : "to start")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if isRunning && event.end > event.start {
                ProgressView(timerInterval: event.start...event.end, countsDown: false)
                    .tint(accent)
                    .accessibilityLabel("Event progress")
            }
            HStack(spacing: 8) {
                if event.isAllDay { Label("All day", systemImage: "sun.max.fill") }
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse").lineLimit(1)
                }
                Spacer()
                Text(event.end, format: .dateTime.hour().minute())
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(accent.opacity(isRunning ? 0.35 : 0.14), lineWidth: 1)
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(event.title)
        .accessibilityValue(accessibilityValue)
    }

    private var eventTime: String {
        event.isAllDay
            ? event.start.formatted(date: .abbreviated, time: .omitted)
            : event.start.formatted(date: .abbreviated, time: .shortened)
    }

    private var accessibilityValue: String {
        isRunning
            ? "Ends \(event.end.formatted(date: .omitted, time: .shortened))"
            : "Starts \(event.start.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct EventDetailView: View {
    let model: HLLAppModel
    let event: HLLEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HLLEventCard(event: event)
                VStack(alignment: .leading, spacing: 14) {
                    Label(event.source == .user ? "Personal event" : "Calendar event",
                          systemImage: event.source == .user ? "person.fill" : "calendar")
                    LabeledContent("Starts", value: event.start.formatted(date: .complete, time: .shortened))
                    LabeledContent("Ends", value: event.end.formatted(date: .complete, time: .shortened))
                    if let location = event.location, !location.isEmpty {
                        LabeledContent("Location", value: location)
                    }
                    if let notes = event.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notes").font(.headline)
                            Text(notes).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding()
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu { HLLContextMenu(event: event, model: model) } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
    }
}

/// Every event surface uses the same actions and therefore the same HLLKit
/// mutation path, including hidden state and automatic Live Activity policy.
struct HLLContextMenu: View {
    let event: HLLEvent
    let model: HLLAppModel

    var body: some View {
        if model.isActivityRunning(for: event) {
            Button("Stop Live Activity", systemImage: "stop.circle") { model.stopActivity(for: event) }
        } else {
            Button("Start Live Activity", systemImage: "play.circle") { model.startActivity(for: event) }
        }
        let target = HLLLiveActivityPolicy.Target.event(
            id: event.id, portableKey: event.portableKey, seriesID: event.seriesID)
        Button(model.isAutomaticallyTracking(target)
               ? "Stop automatic tracking" : "Track automatically", systemImage: "clock.badge") {
            model.setAutomaticTracking(target, enabled: !model.isAutomaticallyTracking(target))
        }
        Button("Pin this event", systemImage: "pin") {
            model.annotate(event, kind: .pinned, scope: .occurrence)
        }
        Button("Hide this event", systemImage: "eye.slash") {
            model.annotate(event, kind: .hidden, scope: .occurrence)
        }
        if event.seriesID != nil {
            Button("Hide this series", systemImage: "eye.slash.fill") {
                model.annotate(event, kind: .hidden, scope: .series)
            }
        }
        if event.source == .user {
            Divider()
            Button("Delete personal event", systemImage: "trash", role: .destructive) {
                model.deleteUserEvent(event)
            }
        }
    }
}
