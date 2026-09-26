import HLLKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: HLLAppModel
    @State private var selectedEventID: UUID?
    @State private var showsAddEvent = false
    @State private var showsCalendars = false

    var body: some View {
        // This naturally collapses on the outer display and opens into two columns on Duo.
        NavigationSplitView {
            Group {
                if model.isLoading {
                    ProgressView("Loading events")
                } else if model.events.isEmpty {
                    ContentUnavailableView("No upcoming events", systemImage: "calendar")
                } else {
                    List(selection: $selectedEventID) {
                        ForEach(model.events) { event in
                            EventRow(event: event)
                                .tag(event.id)
                                .contextMenu { actions(for: event) }
                        }
                    }
                }
            }
            .navigationTitle("How Long Left")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Event", systemImage: "plus") { showsAddEvent = true }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Calendars", systemImage: "calendar.badge.clock") { showsCalendars = true }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.needsCalendarAccess {
                    Button("Allow Calendar Access") { model.requestCalendarAccess() }
                        .buttonStyle(.borderedProminent)
                        .padding()
                }
            }
        } detail: {
            if let event = model.events.first(where: { $0.id == selectedEventID }) {
                EventDetail(event: event)
            } else {
                ContentUnavailableView("Select an event", systemImage: "clock")
            }
        }
        .sheet(isPresented: $showsAddEvent) { AddEventView(model: model) }
        .sheet(isPresented: $showsCalendars) { CalendarSettingsView(model: model) }
        .alert("Could not update events", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) { Button("OK", role: .cancel) { model.errorMessage = nil } } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private func actions(for event: HLLEvent) -> some View {
        if model.isActivityRunning(for: event) {
            Button("Stop Live Activity", systemImage: "stop.circle") {
                model.stopActivity(for: event)
            }
        } else {
            Button("Start Live Activity", systemImage: "play.circle") {
                model.startActivity(for: event)
            }
        }
        let target = HLLLiveActivityPolicy.Target.event(id: event.id,
                                                         portableKey: event.portableKey)
        Button(model.isAutomaticallyTracking(target) ? "Stop automatic tracking" : "Track automatically",
               systemImage: "clock.badge") {
            model.setAutomaticTracking(target,
                                       enabled: !model.isAutomaticallyTracking(target))
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
    }
}

private struct EventRow: View {
    let event: HLLEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title).font(.headline)
            HStack {
                Text(event.start, format: .dateTime.weekday().month().day().hour().minute())
                Spacer()
                if event.isRunning(at: .now) { Text("Now").foregroundStyle(.tint) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct EventDetail: View {
    let event: HLLEvent

    var body: some View {
        Form {
            LabeledContent("Starts", value: event.start.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Ends", value: event.end.formatted(date: .abbreviated, time: .shortened))
            if let location = event.location, !location.isEmpty {
                LabeledContent("Location", value: location)
            }
            if let notes = event.notes, !notes.isEmpty { Text(notes) }
        }
        .navigationTitle(event.title)
    }
}

private struct AddEventView: View {
    @Environment(\.dismiss) private var dismiss
    let model: HLLAppModel
    @State private var title = ""
    @State private var start = Date().addingTimeInterval(3_600)
    @State private var durationHours = 1.0
    @State private var repetition = "None"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Event name", text: $title)
                DatePicker("Starts", selection: $start)
                Stepper("Duration: \(durationHours.formatted()) hours", value: $durationHours,
                        in: 0.5...24, step: 0.5)
                Picker("Repeat", selection: $repetition) {
                    ForEach(["None", "Daily", "Weekly", "Monthly", "Yearly"], id: \.self) { Text($0) }
                }
            }
            .navigationTitle("New Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let frequency = HLLRecurrenceRule.Frequency(rawValue: repetition.lowercased())
                        model.addUserEvent(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                           start: start, duration: durationHours * 3_600,
                                           recurrence: frequency.map { HLLRecurrenceRule(frequency: $0) })
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct CalendarSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let model: HLLAppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Event Choices") {
                    Toggle("Sync hidden and pinned events", isOn: Binding(
                        get: { model.annotationSyncEnabled },
                        set: { model.setAnnotationSync($0) }
                    ))
                }
                Section("Live Activities") {
                    Toggle("Automatically track upcoming events", isOn: Binding(
                        get: { model.isAutomaticallyTracking(.allEvents) },
                        set: { model.setAutomaticTracking(.allEvents, enabled: $0) }
                    ))
                    Text("Starts tracking 30 minutes before an event. You can also start one from an event’s menu.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !model.hiddenAnnotations.isEmpty {
                    Section("Hidden Events") {
                        ForEach(model.hiddenAnnotations) { annotation in
                            HStack {
                                Text(hiddenTitle(for: annotation))
                                Spacer()
                                Button("Show") { model.removeAnnotation(annotation) }
                            }
                        }
                    }
                }
                ForEach(model.calendars, id: \.id) { item in
                    Section(item.preference.title) {
                        visibilityToggle("Main view", item: item, context: "home.main")
                        visibilityToggle("Widgets", item: item, context: "widget.default")
                        visibilityToggle("Complications", item: item, context: "complication.default")
                        visibilityToggle("Live Activities", item: item, context: "activity.default")
                        Toggle("Automatically track this calendar", isOn: Binding(
                            get: { model.isAutomaticallyTracking(.calendar(profileID: item.preference.id)) },
                            set: { model.setAutomaticTracking(.calendar(profileID: item.preference.id), enabled: $0) }
                        ))
                    }
                }
            }
            .navigationTitle("Calendars")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func visibilityToggle(_ title: String,
                                  item: (id: String, preference: HLLCalendarPreference),
                                  context: HLLContextID) -> some View {
        Toggle(title, isOn: Binding(
            get: { item.preference.isVisible(in: context) },
            set: { model.setCalendarVisibility(item.preference, context: context, visible: $0) }
        ))
    }

    private func hiddenTitle(for annotation: HLLEventAnnotation) -> String {
        if let title = annotation.eventTitle { return title }
        if let event = model.events.first(where: annotation.applies) { return event.title }
        return annotation.scope == .series ? "Hidden series" : "Hidden event"
    }
}
