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
                        .contextMenu(menuItems: {
                            WatchEventActions(event: event, model: model)
                        })
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
                        WatchPurchaseSettingsView(model: model)
                    } label: {
                        Label("Premium Access", systemImage: model.isFeatureUnlocked(.complications)
                              ? "checkmark.seal.fill" : "lock.fill")
                    }
                }
                Section {
                    NavigationLink {
                        WatchWidgetSettingsView(model: model)
                    } label: {
                        Label("Widgets & Complications", systemImage: "watchface")
                    }
                    NavigationLink {
                        WatchNotificationSettingsView(model: model)
                    } label: {
                        Label("Notifications", systemImage: "bell")
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

private struct WatchAddEventView: View {
    @Environment(\.dismiss) private var dismiss
    let model: WatchEventModel
    @State private var title = ""
    @State private var start = Date().addingTimeInterval(3_600)
    @State private var durationMinutes = 60.0
    @State private var isAllDay = false
    @State private var repetition: HLLRecurrenceRule.Frequency?

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField("Name", text: $title)
                    DatePicker("Starts", selection: $start)
                    Toggle("All day", isOn: $isAllDay)
                    if !isAllDay {
                        Stepper("Duration: \(Int(durationMinutes)) min",
                                value: $durationMinutes, in: 30...1_440, step: 30)
                    }
                }
                Section("Repeat") {
                    Picker("Schedule", selection: $repetition) {
                        Text("None").tag(HLLRecurrenceRule.Frequency?.none)
                        Text("Daily").tag(HLLRecurrenceRule.Frequency?.some(.daily))
                        Text("Weekly").tag(HLLRecurrenceRule.Frequency?.some(.weekly))
                        Text("Monthly").tag(HLLRecurrenceRule.Frequency?.some(.monthly))
                        Text("Yearly").tag(HLLRecurrenceRule.Frequency?.some(.yearly))
                    }
                }
            }
            .navigationTitle("New Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.addUserEvent(title: cleanTitle, start: start,
                                           duration: isAllDay ? 86_400 : durationMinutes * 60,
                                           isAllDay: isAllDay,
                                           recurrence: repetition.map { HLLRecurrenceRule(frequency: $0) })
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct WatchWidgetSettingsView: View {
    let model: WatchEventModel

    var body: some View {
        List {
            Section {
                Text("Configure each complication from the watch face editor. It can show current, in-progress, all upcoming, or the event with the soonest countdown, with all-day filtering, a pinned event, and several countdown styles.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !model.isFeatureUnlocked(.complications) {
                    Label("Complications are available with Premium.", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
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

private struct WatchNotificationSettingsView: View {
    let model: WatchEventModel

    var body: some View {
        List {
            Section {
                Text("Start and end alerts follow the same visible watch event list. Hidden events and calendars excluded from the watch app are never scheduled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !model.isFeatureUnlocked(.notifications) {
                    Label("Notifications are available with Premium.", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Section("Schedule") {
                Toggle("Enable notifications", isOn: enabledBinding)
                    .disabled(!model.isFeatureUnlocked(.notifications))
                Toggle("At event start", isOn: startBinding)
                    .disabled(!canEditRules)
                Toggle("At event end", isOn: endBinding)
                    .disabled(!canEditRules)
                Toggle("Include all-day events", isOn: allDayBinding)
                    .disabled(!canEditRules)
            }
        }
        .navigationTitle("Notifications")
    }

    private var canEditRules: Bool {
        model.isFeatureUnlocked(.notifications) && model.notificationPreferences.enabled
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.notificationPreferences.enabled },
                set: { value in update { $0.enabled = value } })
    }

    private var startBinding: Binding<Bool> {
        Binding(get: { model.notificationPreferences.notifyAtStart },
                set: { value in update { $0.notifyAtStart = value } })
    }

    private var endBinding: Binding<Bool> {
        Binding(get: { model.notificationPreferences.notifyAtEnd },
                set: { value in update { $0.notifyAtEnd = value } })
    }

    private var allDayBinding: Binding<Bool> {
        Binding(get: { model.notificationPreferences.includeAllDay },
                set: { value in update { $0.includeAllDay = value } })
    }

    private func update(_ change: (inout HLLNotificationPreferences) -> Void) {
        var preferences = model.notificationPreferences
        change(&preferences)
        model.setNotificationPreferences(preferences)
    }
}

private struct WatchPurchaseSettingsView: View {
    let model: WatchEventModel

    var body: some View {
        List {
            Section("Feature access") {
                WatchPurchaseFeatureRow(title: "Complications", feature: .complications,
                                        snapshot: model.purchaseSnapshot)
                WatchPurchaseFeatureRow(title: "Widgets", feature: .widgets,
                                        snapshot: model.purchaseSnapshot)
                WatchPurchaseFeatureRow(title: "Live Activities", feature: .liveActivities,
                                        snapshot: model.purchaseSnapshot)
                WatchPurchaseFeatureRow(title: "Notifications", feature: .notifications,
                                        snapshot: model.purchaseSnapshot)
            }
            Section("Available purchases") {
                if model.purchaseProducts.isEmpty {
                    Text("Products will appear when the App Store is available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.purchaseProducts) { product in
                        Button {
                            model.purchase(productID: product.id)
                        } label: {
                            HStack {
                                Text(product.displayName)
                                Spacer()
                                Text(product.displayPrice).font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
                Button("Restore Purchases", systemImage: "arrow.clockwise") {
                    model.restorePurchases()
                }
            }
            Section {
                Text("Purchase status is verified by StoreKit and mirrored through iCloud and WatchConnectivity.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Premium Access")
        .task { model.loadPurchaseProducts() }
        .alert("Purchase update failed", isPresented: Binding(
            get: { model.purchaseErrorMessage != nil },
            set: { if !$0 { model.purchaseErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.purchaseErrorMessage = nil }
        } message: {
            Text(model.purchaseErrorMessage ?? "")
        }
    }
}

private struct WatchPurchaseFeatureRow: View {
    let title: String
    let feature: HLLPaidFeature
    let snapshot: HLLPurchaseSnapshot

    var body: some View {
        Label(title, systemImage: snapshot.isUnlocked(feature)
              ? "checkmark.circle.fill" : "lock.circle")
            .foregroundStyle(snapshot.isUnlocked(feature) ? .green : .secondary)
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
