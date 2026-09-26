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
    @State private var showsAddEvent = false

    enum Mode {
        case current
        case upcoming
    }

    var body: some View {
        NavigationStack {
            let events = mode == .current ? model.currentEvents : model.upcomingEvents
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
                            WatchEventCard(event: event)
                        }
                    }
                    .listStyle(.carousel)
                }
            }
            .navigationTitle(mode == .current ? "Now" : "Upcoming")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Event", systemImage: "plus") {
                        showsAddEvent = true
                    }
                }
            }
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
        .sheet(isPresented: $showsAddEvent) {
            WatchAddEventView(model: model)
        }
    }
}

private struct WatchEventCard: View {
    let event: HLLEvent

    private var running: Bool { event.status() == .inProgress }

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
                // SwiftUI owns this timer-backed progress view. It updates its
                // drawing without invalidating and refiltering the entire list.
                ProgressView(timerInterval: event.start...event.end, countsDown: false)
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
                WatchEventCard(event: event)
                Divider()
                LabeledContent("Starts", value: event.start.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Ends", value: event.end.formatted(date: .abbreviated, time: .shortened))
                if let location = event.location, !location.isEmpty {
                    LabeledContent("Location", value: location)
                }
                if let notes = event.notes, !notes.isEmpty {
                    Text(notes).font(.footnote).foregroundStyle(.secondary)
                }
                WatchEventActions(event: event, model: model)
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
        VStack(alignment: .leading, spacing: 8) {
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
                Button("Delete personal event", systemImage: "trash", role: .destructive) {
                    model.deleteUserEvent(event)
                }
            }
        }
    }
}
