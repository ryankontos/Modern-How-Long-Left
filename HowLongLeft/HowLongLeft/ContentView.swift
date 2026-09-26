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
            EventListView(model: model,
                          events: model.currentEvents,
                          emptyTitle: "Nothing in progress",
                          emptyMessage: "Events appear here while they are happening.",
                          groupsByDay: false)
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
            EventListView(model: model,
                          events: model.upcomingEvents,
                          emptyTitle: "Nothing upcoming",
                          emptyMessage: "New events from your calendars will appear here.",
                          groupsByDay: true)
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
            HLLEventCard(event: event)
        }
        .contextMenu { HLLContextMenu(event: event, model: model) }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
