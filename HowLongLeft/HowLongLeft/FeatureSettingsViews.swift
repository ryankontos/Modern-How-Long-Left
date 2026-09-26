import HLLKit
import SwiftUI

/// Defaults are a convenience for newly added widgets. WidgetKit's
/// configuration intent remains authoritative for each existing widget.
struct WidgetSettingsView: View {
    let model: HLLAppModel

    var body: some View {
        List {
            Section {
                Text("Every widget and complication has its own configuration: current, in progress, all upcoming, all-day filtering, a pinned event, style, and event count. These defaults are used when creating a new configuration.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !model.isFeatureUnlocked(.widgets) {
                    Label("Widgets are locked until Premium is purchased.", systemImage: "lock.fill")
                        .foregroundStyle(.orange).font(.footnote)
                }
            }
            Section("New widget defaults") {
                Picker("Events", selection: modeBinding) {
                    Text("Current or next").tag(HLLWidgetDisplayMode.current)
                    Text("In progress").tag(HLLWidgetDisplayMode.inProgress)
                    Text("All upcoming").tag(HLLWidgetDisplayMode.all)
                    Text("Soonest countdown").tag(HLLWidgetDisplayMode.soonestCountdown)
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
                Label("The app publishes local calendar data to the App Group. CloudKit carries only settings and personal events. Extensions refresh their own EventKit calendars when WidgetKit asks for a timeline.", systemImage: "arrow.clockwise.icloud")
                    .font(.footnote).foregroundStyle(.secondary)
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

struct ActivitySettingsView: View {
    let model: HLLAppModel

    var body: some View {
        List {
            Section {
                Text("Live Activities use date-driven timers for smooth countdowns and scheduled starts. You can also start or stop one from any event card's context menu.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !model.isFeatureUnlocked(.liveActivities) {
                    Label("Live Activities are a Premium feature.", systemImage: "lock.fill")
                        .foregroundStyle(.orange).font(.footnote)
                }
            }
            Section("Automatic tracking") {
                Toggle("Track all events", isOn: Binding(
                    get: { model.isAutomaticallyTracking(.allEvents) },
                    set: { model.setAutomaticTracking(.allEvents, enabled: $0) }
                ))
                .disabled(!model.isFeatureUnlocked(.liveActivities))
            }
        }
        .navigationTitle("Live Activities")
    }
}

/// Notification options update one preference record, then reconcile the
/// pending schedule through the HLLKit notification actor.
struct NotificationSettingsView: View {
    let model: HLLAppModel

    var body: some View {
        List {
            Section {
                Text("Notifications are derived from the same filtered event snapshot used by the app. Hidden events and calendars that are not visible in the app are never scheduled.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !model.isFeatureUnlocked(.notifications) {
                    Label("Notifications are a Premium feature.", systemImage: "lock.fill")
                        .foregroundStyle(.orange).font(.footnote)
                }
            }
            Section("Schedule") {
                Toggle("Enable notifications", isOn: enabledBinding)
                    .disabled(!model.isFeatureUnlocked(.notifications))
                Toggle("At event start", isOn: notifyAtStartBinding).disabled(!canEditRules)
                Toggle("At event end", isOn: notifyAtEndBinding).disabled(!canEditRules)
                Toggle("Include all-day events", isOn: includeAllDayBinding).disabled(!canEditRules)
            }
            Section {
                Text("Changing these options reconciles pending requests immediately. If access is denied in system settings, turn notifications on again there before enabling them here.")
                    .font(.footnote).foregroundStyle(.secondary)
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
    private var notifyAtStartBinding: Binding<Bool> {
        Binding(get: { model.notificationPreferences.notifyAtStart },
                set: { value in update { $0.notifyAtStart = value } })
    }
    private var notifyAtEndBinding: Binding<Bool> {
        Binding(get: { model.notificationPreferences.notifyAtEnd },
                set: { value in update { $0.notifyAtEnd = value } })
    }
    private var includeAllDayBinding: Binding<Bool> {
        Binding(get: { model.notificationPreferences.includeAllDay },
                set: { value in update { $0.includeAllDay = value } })
    }

    private func update(_ change: (inout HLLNotificationPreferences) -> Void) {
        var preferences = model.notificationPreferences
        change(&preferences)
        model.setNotificationPreferences(preferences)
    }
}
