import HLLKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let model: HLLAppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CalendarPreferencesView(model: model)
                    } label: {
                        HLLSettingsRow(title: "Calendar Preferences",
                                       subtitle: "Choose where each calendar appears",
                                       systemImage: "calendar.badge.clock",
                                       tint: .blue)
                    }
                    NavigationLink {
                        WidgetSettingsView(model: model)
                    } label: {
                        HLLSettingsRow(title: "Widgets & Complications",
                                       subtitle: "Set defaults for configurable surfaces",
                                       systemImage: "square.grid.2x2",
                                       tint: .purple)
                    }
                    NavigationLink {
                        ActivitySettingsView(model: model)
                    } label: {
                        HLLSettingsRow(title: "Live Activities",
                                       subtitle: "Automatically follow events",
                                       systemImage: "timer",
                                       tint: .orange)
                    }
                    NavigationLink {
                        HiddenEventsView(model: model)
                    } label: {
                        HLLSettingsRow(title: "Hidden Events",
                                       subtitle: "Restore events you have hidden",
                                       systemImage: "eye.slash",
                                       tint: .secondary)
                    }
                }

                Section {
                    Toggle("Sync hidden and pinned events", isOn: Binding(
                        get: { model.annotationSyncEnabled },
                        set: { model.setAnnotationSync($0) }
                    ))
                    Text("When iCloud is available, portable calendar matches can follow you to another device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("iCloud")
                }

                Section {
                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        HLLSettingsRow(title: "About How Long Left",
                                       subtitle: "Version and storage information",
                                       systemImage: "info.circle",
                                       tint: .gray)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct HLLSettingsRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 28)
        }
        .padding(.vertical, 4)
    }
}

private struct HLLContextOption: Identifiable {
    let id: HLLContextID
    let title: String
    let systemImage: String

    init(_ title: String, _ rawID: String, _ systemImage: String) {
        self.id = HLLContextID(rawValue: rawID)
        self.title = title
        self.systemImage = systemImage
    }
}

/// This registry is intentionally local to the UI. HLLKit accepts any context
/// ID, so adding a new surface is one new option rather than a schema change.
private let hllContextOptions = [
    HLLContextOption("App", "home.main", "rectangle.on.rectangle"),
    HLLContextOption("Widgets", "widget.default", "square.grid.2x2"),
    HLLContextOption("Complications", "complication.default", "watchface"),
    HLLContextOption("Live Activities", "activity.default", "timer")
]

private struct CalendarPreferencesView: View {
    let model: HLLAppModel

    var body: some View {
        List {
            Section {
                Text("Each calendar has independent visibility rules for every surface. Rules are stored by a stable calendar profile, so EventKit IDs can change without losing your choices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if model.calendars.isEmpty {
                ContentUnavailableView("No calendars available", systemImage: "calendar.badge.exclamationmark")
            } else {
                Section("Calendars") {
                    ForEach(model.calendars.indices, id: \.self) { index in
                        let item = model.calendars[index]
                        NavigationLink {
                            CalendarDetailSettingsView(model: model,
                                                       localID: item.id,
                                                       preference: item.preference)
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(.blue.gradient)
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.preference.title)
                                    if !item.preference.sourceTitle.isEmpty {
                                        Text(item.preference.sourceTitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Calendars")
    }
}

private struct CalendarDetailSettingsView: View {
    let model: HLLAppModel
    let localID: String
    let preference: HLLCalendarPreference

    var body: some View {
        List {
            Section {
                Text(preference.title).font(.title3.weight(.semibold))
                if !preference.sourceTitle.isEmpty {
                    Text(preference.sourceTitle).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Show this calendar in") {
                ForEach(hllContextOptions) { option in
                    Toggle(isOn: visibilityBinding(for: option.id)) {
                        Label(option.title, systemImage: option.systemImage)
                    }
                }
            }

            Section("Live Activity automation") {
                Toggle("Follow this calendar automatically", isOn: Binding(
                    get: { model.isAutomaticallyTracking(.calendar(profileID: preference.id)) },
                    set: { model.setAutomaticTracking(.calendar(profileID: preference.id), enabled: $0) }
                ))
                Text("A scheduled activity can start before an event and update without reopening the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func visibilityBinding(for context: HLLContextID) -> Binding<Bool> {
        Binding(
            get: {
                model.calendars.first(where: { $0.preference.id == preference.id })?.preference
                    .isVisible(in: context) ?? preference.isVisible(in: context)
            },
            set: { model.setCalendarVisibility(preference, context: context, visible: $0) }
        )
    }
}

private struct WidgetSettingsView: View {
    let model: HLLAppModel

    var body: some View {
        List {
            Section {
                Text("Every widget and complication has its own configuration: current, in progress, all upcoming, all-day filtering, a pinned event, style, and event count. These defaults are used when creating a new configuration.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("New widget defaults") {
                Picker("Events", selection: modeBinding) {
                    Text("Current or next").tag(HLLWidgetDisplayMode.current)
                    Text("In progress").tag(HLLWidgetDisplayMode.inProgress)
                    Text("All upcoming").tag(HLLWidgetDisplayMode.all)
                }
                Picker("Style", selection: styleBinding) {
                    Text("Automatic").tag(HLLWidgetStyle.automatic)
                    Text("Title").tag(HLLWidgetStyle.title)
                    Text("Countdown").tag(HLLWidgetStyle.countdown)
                    Text("Progress").tag(HLLWidgetStyle.progress)
                    Text("Detailed").tag(HLLWidgetStyle.detailed)
                }
                Toggle("Include all-day events", isOn: includeAllDayBinding)
                Stepper(value: eventCountBinding, in: 1...6) {
                    Text("Events shown: \(model.widgetDefaults.eventCount)")
                }
            }

            Section("Refresh") {
                Label("The app publishes one compact snapshot to the App Group and CloudKit. Extensions read it directly and refresh EventKit when WidgetKit asks for a timeline.", systemImage: "arrow.clockwise.icloud")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Widgets")
    }

    private var modeBinding: Binding<HLLWidgetDisplayMode> {
        Binding(get: { model.widgetDefaults.mode }, set: {
            var defaults = model.widgetDefaults
            defaults.mode = $0
            model.setWidgetDefaults(defaults)
        })
    }

    private var styleBinding: Binding<HLLWidgetStyle> {
        Binding(get: { model.widgetDefaults.style }, set: {
            var defaults = model.widgetDefaults
            defaults.style = $0
            model.setWidgetDefaults(defaults)
        })
    }

    private var includeAllDayBinding: Binding<Bool> {
        Binding(get: { model.widgetDefaults.includeAllDay }, set: {
            var defaults = model.widgetDefaults
            defaults.includeAllDay = $0
            model.setWidgetDefaults(defaults)
        })
    }

    private var eventCountBinding: Binding<Int> {
        Binding(get: { model.widgetDefaults.eventCount }, set: {
            var defaults = model.widgetDefaults
            defaults.eventCount = $0
            model.setWidgetDefaults(defaults)
        })
    }
}

private struct ActivitySettingsView: View {
    let model: HLLAppModel

    var body: some View {
        List {
            Section {
                Text("Live Activities use date-driven timers for smooth countdowns and scheduled starts. You can also start or stop one from any event card's context menu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Automatic tracking") {
                Toggle("Track all events", isOn: Binding(
                    get: { model.isAutomaticallyTracking(.allEvents) },
                    set: { model.setAutomaticTracking(.allEvents, enabled: $0) }
                ))
            }
        }
        .navigationTitle("Live Activities")
    }
}

private struct HiddenEventsView: View {
    let model: HLLAppModel

    var body: some View {
        List {
            if model.hiddenAnnotations.isEmpty {
                ContentUnavailableView("No hidden events", systemImage: "eye")
            } else {
                ForEach(model.hiddenAnnotations) { annotation in
                    HStack(spacing: 12) {
                        Image(systemName: annotation.scope == .series ? "rectangle.stack" : "calendar")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(annotation.eventTitle ?? (annotation.scope == .series ? "Hidden series" : "Hidden event"))
                            Text(annotation.scope == .series ? "Every occurrence" : "This occurrence")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show") { model.removeAnnotation(annotation) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .navigationTitle("Hidden Events")
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        List {
            Section("How Long Left") {
                LabeledContent("Version", value: "3.0")
                LabeledContent("Build", value: "253")
                LabeledContent("Architecture", value: "HLLKit + Swift 6")
            }
            Section("Storage") {
                Text("Settings and user events use the HLLKit repository. The app group keeps one atomic extension snapshot, while CloudKit stores the shared mirror and a replace-in-place extension projection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
    }
}

struct AddEventView: View {
    @Environment(\.dismiss) private var dismiss
    let model: HLLAppModel
    @State private var title = ""
    @State private var start = Date().addingTimeInterval(3_600)
    @State private var durationHours = 1.0
    @State private var isAllDay = false
    @State private var repetition: HLLRecurrenceRule.Frequency?

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField("Event name", text: $title)
                    DatePicker("Starts", selection: $start)
                    Toggle("All day", isOn: $isAllDay)
                    if !isAllDay {
                        Stepper("Duration: \(durationHours.formatted()) hours",
                                value: $durationHours, in: 0.5...24, step: 0.5)
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
                                           duration: isAllDay ? 86_400 : durationHours * 3_600,
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
