import HLLKit
import SwiftUI

struct WatchContentView: View {
    let model: WatchEventModel
    @State private var selectedTab: WatchTab = .current

    private enum WatchTab: Hashable {
        case current
        case upcoming
        case settings
    }

    var body: some View {
        Group {
            if model.isLoading {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            } else {
                TabView(selection: $selectedTab) {
                    WatchEventListView(model: model, mode: .current)
                        .tag(WatchTab.current)
                    WatchEventListView(model: model, mode: .upcoming)
                        .tag(WatchTab.upcoming)
                    WatchSettingsView(model: model)
                        .tag(WatchTab.settings)
                }
                .tabViewStyle(.verticalPage)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.isLoading)
    }
}

private struct WatchEventListView: View {
    let model: WatchEventModel
    let mode: Mode

    enum Mode {
        case current
        case upcoming
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: mode == .current ? 1 : 30)) { context in
                let events = mode == .current
                    ? model.currentEvents(at: context.date)
                    : model.upcomingEvents(at: context.date)
                Group {
                    if events.isEmpty {
                        ContentUnavailableView(mode == .current ? "Nothing now" : "Nothing next",
                                               systemImage: mode == .current ? "clock" : "calendar",
                                               description: Text(mode == .current
                                                                 ? "Events appear here while active."
                                                                 : "Your next events appear here."))
                    } else {
                        List(events) { event in
                            NavigationLink(value: event.id) {
                                WatchEventCard(event: event, now: context.date)
                            }
                            .contextMenu {
                                WatchEventActions(event: event, model: model)
                            }
                        }
                        .listStyle(.carousel)
                    }
                }
            }
            .navigationTitle(mode == .current ? "Now" : "Upcoming")
            .navigationDestination(for: UUID.self) { id in
                if let event = model.event(withID: id) {
                    WatchEventDetailView(event: event, model: model)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.needsCalendarAccess {
                    Button("Allow Calendars") { model.requestCalendarAccess() }
                }
            }
        }
    }
}

private struct WatchEventCard: View {
    let event: HLLEvent
    let now: Date

    private var running: Bool { event.isRunning(at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(event.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Image(systemName: event.source == .user ? "person.fill" : "calendar")
                    .foregroundStyle(running ? .orange : .blue)
            }
            HStack {
                if running {
                    Text(event.end, style: .timer)
                        .font(.title3.monospacedDigit().weight(.semibold))
                    Text("left")
                } else {
                    Text(event.start, style: .relative)
                        .font(.title3.monospacedDigit().weight(.semibold))
                    Text("to start")
                }
                Spacer()
            }
            .foregroundStyle(running ? .orange : .blue)
            if running && event.end > event.start {
                ProgressView(value: event.progress(at: now))
                    .tint(.orange)
            }
            Text(event.isAllDay ? "All day" : event.start.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(event.title)
    }
}

private struct WatchEventDetailView: View {
    let event: HLLEvent
    let model: WatchEventModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    WatchEventCard(event: event, now: context.date)
                }
                Divider()
                LabeledContent("Starts", value: event.start.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Ends", value: event.end.formatted(date: .abbreviated, time: .shortened))
                if let location = event.location, !location.isEmpty {
                    LabeledContent("Location", value: location)
                }
                if let notes = event.notes, !notes.isEmpty {
                    Text(notes).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Hide this event", systemImage: "eye.slash") {
                    model.annotate(event, kind: .hidden, scope: .occurrence)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
        }
        .navigationTitle("Details")
    }
}

private struct WatchEventActions: View {
    let event: HLLEvent
    let model: WatchEventModel

    var body: some View {
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

private struct WatchSettingsView: View {
    let model: WatchEventModel

    var body: some View {
        NavigationStack {
            List {
                Section("Calendars") {
                    if model.calendars.isEmpty {
                        Text("No watch calendars available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.calendars.indices, id: \.self) { index in
                            let item = model.calendars[index]
                            NavigationLink {
                                WatchCalendarSettingsView(model: model,
                                                          preference: item.preference)
                            } label: {
                                Label(item.preference.title, systemImage: "calendar")
                            }
                        }
                    }
                }
                Section {
                    Text("This app reads only calendars available to watchOS. Settings are shared through HLLKit where the watch has access to them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink {
                        WatchWidgetSettingsView()
                    } label: {
                        Label("Widgets & Complications", systemImage: "watchface")
                    }
                }
                if !model.hiddenAnnotations.isEmpty {
                    Section("Hidden") {
                        ForEach(model.hiddenAnnotations) { annotation in
                            HStack {
                                Text(annotation.eventTitle ?? "Hidden event")
                                    .lineLimit(1)
                                Spacer()
                                Button("Show") { model.removeAnnotation(annotation) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct WatchWidgetSettingsView: View {
    var body: some View {
        List {
            Section {
                Text("Configure each complication from the watch face editor. The shared configuration supports current, in-progress, or all upcoming events, all-day filtering, a pinned event, and several countdown styles.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Styles") {
                Label("Countdown to start or end", systemImage: "timer")
                Label("Progress bar", systemImage: "chart.bar.fill")
                Label("Event title and details", systemImage: "text.alignleft")
            }
        }
        .navigationTitle("Complications")
    }
}

private struct WatchCalendarSettingsView: View {
    let model: WatchEventModel
    let preference: HLLCalendarPreference

    var body: some View {
        List {
            Section("Show in") {
                Toggle("Watch app", isOn: visibilityBinding("watch.main"))
                Toggle("Complications", isOn: visibilityBinding("complication.default"))
                Toggle("Widgets", isOn: visibilityBinding("widget.default"))
            }
        }
        .navigationTitle(preference.title)
    }

    private func visibilityBinding(_ value: String) -> Binding<Bool> {
        let context = HLLContextID(rawValue: value)
        return Binding(get: {
            model.calendars.first(where: { $0.preference.id == preference.id })?.preference
                .isVisible(in: context) ?? preference.isVisible(in: context)
        },
                       set: { model.setCalendarVisibility(preference, context: context, visible: $0) })
    }
}

private extension HLLEvent {
    func progress(at date: Date) -> Double {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return 1 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }
}
