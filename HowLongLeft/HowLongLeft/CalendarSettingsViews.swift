import HLLKit
import SwiftUI

/// This UI registry provides friendly labels for the contexts used by the
/// current targets. HLLKit accepts arbitrary context IDs, so new surfaces do
/// not require changes to its storage schema.
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

private let hllContextOptions = [
    HLLContextOption("App", "home.main", "rectangle.on.rectangle"),
    HLLContextOption("Widgets", "widget.default", "square.grid.2x2"),
    HLLContextOption("Complications", "complication.default", "watchface"),
    HLLContextOption("Live Activities", "activity.default", "timer")
]

/// Lists the stable calendar profiles currently bound to this device's
/// EventKit calendars. EventKit IDs remain local implementation details.
struct CalendarPreferencesView: View {
    let model: HLLAppModel

    var body: some View {
        List {
            Section {
                Text("Each calendar has independent visibility rules for every surface. Rules are stored by a stable calendar profile, so EventKit IDs can change without losing your choices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if model.calendars.isEmpty {
                ContentUnavailableView("No calendars available",
                                       systemImage: "calendar.badge.exclamationmark")
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
                                Circle().fill(.blue.gradient).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.preference.title)
                                    if !item.preference.sourceTitle.isEmpty {
                                        Text(item.preference.sourceTitle)
                                            .font(.caption).foregroundStyle(.secondary)
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
                    .font(.footnote).foregroundStyle(.secondary)
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
