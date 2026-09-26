import HLLKit
import SwiftUI

/// The app shell. The first frame stays empty while HLLKit builds a snapshot,
/// then the complete tab shell fades in as one inexpensive transition.
struct ContentView: View {
    @Bindable var model: HLLAppModel
    @State private var selectedTab: AppTab = .current
    @State private var showsSettings = false

    private enum AppTab: Hashable {
        case current
        case upcoming
    }

    var body: some View {
        Group {
            if model.isLoading {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            } else {
                TabView(selection: $selectedTab) {
                    CurrentEventsView(model: model, showsSettings: $showsSettings)
                        .tabItem { Label("Current", systemImage: "clock.fill") }
                        .tag(AppTab.current)

                    UpcomingEventsView(model: model, showsSettings: $showsSettings)
                        .tabItem { Label("Upcoming", systemImage: "calendar") }
                        .tag(AppTab.upcoming)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.28), value: model.isLoading)
        .sheet(isPresented: $showsSettings) {
            SettingsView(model: model)
        }
        .alert("Could not update events", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct CurrentEventsView: View {
    let model: HLLAppModel
    @Binding var showsSettings: Bool
    @State private var showsAddEvent = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                EventListView(model: model,
                              events: model.currentEvents(at: context.date),
                              emptyTitle: "Nothing in progress",
                              emptyMessage: "Events appear here while they are happening.",
                              groupsByDay: false,
                              now: context.date)
            }
            .navigationTitle("Current")
            .navigationDestination(for: UUID.self) { id in
                if let event = model.event(withID: id) {
                    EventDetailView(model: model, event: event)
                }
            }
            .toolbar {
                HLLSettingsToolbarButton(showsSettings: $showsSettings)
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Event", systemImage: "plus") { showsAddEvent = true }
                }
            }
            .safeAreaInset(edge: .bottom) {
                CalendarAccessBanner(model: model)
            }
        }
        .sheet(isPresented: $showsAddEvent) { AddEventView(model: model) }
    }
}

private struct UpcomingEventsView: View {
    let model: HLLAppModel
    @Binding var showsSettings: Bool
    @State private var showsAddEvent = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                EventListView(model: model,
                              events: model.upcomingEvents(at: context.date),
                              emptyTitle: "Nothing upcoming",
                              emptyMessage: "New events from your calendars will appear here.",
                              groupsByDay: true,
                              now: context.date)
            }
            .navigationTitle("Upcoming")
            .navigationDestination(for: UUID.self) { id in
                if let event = model.event(withID: id) {
                    EventDetailView(model: model, event: event)
                }
            }
            .toolbar {
                HLLSettingsToolbarButton(showsSettings: $showsSettings)
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Event", systemImage: "plus") { showsAddEvent = true }
                }
            }
            .safeAreaInset(edge: .bottom) {
                CalendarAccessBanner(model: model)
            }
        }
        .sheet(isPresented: $showsAddEvent) { AddEventView(model: model) }
    }
}

private struct EventListView: View {
    let model: HLLAppModel
    let events: [HLLEvent]
    let emptyTitle: String
    let emptyMessage: String
    let groupsByDay: Bool
    let now: Date

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView(emptyTitle,
                                       systemImage: "calendar.badge.clock",
                                       description: Text(emptyMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groupsByDay {
                List {
                    ForEach(dayGroups, id: \.day) { group in
                        Section(group.day.formatted(.dateTime.weekday(.wide).month().day())) {
                            ForEach(group.events) { event in
                                eventLink(event)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                List(events) { event in
                    eventLink(event)
                }
                .listStyle(.insetGrouped)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: events)
    }

    private var dayGroups: [(day: Date, events: [HLLEvent])] {
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: events) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted().map { day in
            (day: day, events: grouped[day, default: []].sorted { $0.start < $1.start })
        }
    }

    @ViewBuilder private func eventLink(_ event: HLLEvent) -> some View {
        NavigationLink(value: event.id) {
            HLLEventCard(event: event, now: now)
        }
        .contextMenu { HLLContextMenu(event: event, model: model) }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

private struct HLLEventCard: View {
    let event: HLLEvent
    let now: Date

    private var isRunning: Bool { event.isRunning(at: now) }
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
                    Text(event.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Image(systemName: event.source == .user ? "person.fill" : "calendar")
                        Text(eventTime)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    if isRunning {
                        Text(event.end, style: .timer)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(accent)
                        Text("left")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(event.start, style: .relative)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(accent)
                        Text("to start")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if isRunning && event.end > event.start {
                ProgressView(value: event.progress(at: now))
                    .tint(accent)
                    .accessibilityLabel("Event progress")
            }

            HStack(spacing: 8) {
                if event.isAllDay {
                    Label("All day", systemImage: "sun.max.fill")
                }
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .lineLimit(1)
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
        if event.isAllDay { return event.start.formatted(date: .abbreviated, time: .omitted) }
        return event.start.formatted(date: .abbreviated, time: .shortened)
    }

    private var accessibilityValue: String {
        if isRunning {
            return "Ends \(event.end.formatted(date: .omitted, time: .shortened))"
        }
        return "Starts \(event.start.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct EventDetailView: View {
    let model: HLLAppModel
    let event: HLLEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HLLEventCard(event: event, now: context.date)
                }

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
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding()
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    HLLContextMenu(event: event, model: model)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
    }
}

private struct HLLContextMenu: View {
    let event: HLLEvent
    let model: HLLAppModel

    var body: some View {
        if model.isActivityRunning(for: event) {
            Button("Stop Live Activity", systemImage: "stop.circle") { model.stopActivity(for: event) }
        } else {
            Button("Start Live Activity", systemImage: "play.circle") { model.startActivity(for: event) }
        }
        Button(model.isAutomaticallyTracking(.event(id: event.id, portableKey: event.portableKey))
               ? "Stop automatic tracking" : "Track automatically", systemImage: "clock.badge") {
            let target = HLLLiveActivityPolicy.Target.event(id: event.id, portableKey: event.portableKey)
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

private struct CalendarAccessBanner: View {
    let model: HLLAppModel

    var body: some View {
        if model.needsCalendarAccess {
            Button("Allow Calendar Access", systemImage: "calendar.badge.plus") {
                model.requestCalendarAccess()
            }
            .buttonStyle(.borderedProminent)
            .padding(.vertical, 8)
        }
    }
}

private struct HLLSettingsToolbarButton: ToolbarContent {
    @Binding var showsSettings: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Settings", systemImage: "gearshape") { showsSettings = true }
        }
    }
}

private extension HLLEvent {
    func progress(at date: Date) -> Double {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return 1 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }
}
