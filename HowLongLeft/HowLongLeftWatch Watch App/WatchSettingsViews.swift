import HLLKit
import SwiftUI

/// Watch settings use small, native lists so scrolling stays cheap. Every
/// persistence operation is delegated to the model and then to HLLKit actors.
struct WatchSettingsView: View {
    let model: WatchEventModel

    var body: some View {
        NavigationStack {
            List {
                calendarSection
                Section {
                    Text("This app reads only calendars available to watchOS. Settings are shared through HLLKit where the watch has access to them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink { WatchPurchaseSettingsView(model: model) } label: {
                        Label("Premium Access", systemImage: model.isFeatureUnlocked(.complications)
                              ? "checkmark.seal.fill" : "lock.fill")
                    }
                    NavigationLink { WatchWidgetSettingsView(model: model) } label: {
                        Label("Widgets & Complications", systemImage: "watchface")
                    }
                    NavigationLink { WatchNotificationSettingsView(model: model) } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                }
                if !model.hiddenAnnotations.isEmpty {
                    Section("Hidden") {
                        ForEach(model.hiddenAnnotations) { annotation in
                            HStack {
                                Text(annotation.eventTitle ?? "Hidden event").lineLimit(1)
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

    @ViewBuilder private var calendarSection: some View {
        Section("Calendars") {
            if model.calendars.isEmpty {
                Text("No watch calendars available").foregroundStyle(.secondary)
            } else {
                ForEach(model.calendars.indices, id: \.self) { index in
                    let item = model.calendars[index]
                    NavigationLink {
                        WatchCalendarSettingsView(model: model, preference: item.preference)
                    } label: {
                        Label(item.preference.title, systemImage: "calendar")
                    }
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
                Toggle("At event start", isOn: startBinding).disabled(!canEditRules)
                Toggle("At event end", isOn: endBinding).disabled(!canEditRules)
                Toggle("Include all-day events", isOn: allDayBinding).disabled(!canEditRules)
            }
        }
        .navigationTitle("Notifications")
    }

    private var canEditRules: Bool {
        model.isFeatureUnlocked(.notifications) && model.notificationPreferences.enabled
    }
    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.notificationPreferences.enabled }, set: { value in update { $0.enabled = value } })
    }
    private var startBinding: Binding<Bool> {
        Binding(get: { model.notificationPreferences.notifyAtStart }, set: { value in update { $0.notifyAtStart = value } })
    }
    private var endBinding: Binding<Bool> {
        Binding(get: { model.notificationPreferences.notifyAtEnd }, set: { value in update { $0.notifyAtEnd = value } })
    }
    private var allDayBinding: Binding<Bool> {
        Binding(get: { model.notificationPreferences.includeAllDay }, set: { value in update { $0.includeAllDay = value } })
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
                feature("Complications", .complications)
                feature("Widgets", .widgets)
                feature("Live Activities", .liveActivities)
                feature("Notifications", .notifications)
            }
            Section("Available purchases") {
                if model.purchaseProducts.isEmpty {
                    Text("Products will appear when the App Store is available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.purchaseProducts) { product in
                        Button { model.purchase(productID: product.id) } label: {
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

    private func feature(_ title: String, _ feature: HLLPaidFeature) -> some View {
        Label(title, systemImage: model.purchaseSnapshot.isUnlocked(feature)
              ? "checkmark.circle.fill" : "lock.circle")
            .foregroundStyle(model.purchaseSnapshot.isUnlocked(feature) ? .green : .secondary)
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
        }, set: { model.setCalendarVisibility(preference, context: context, visible: $0) })
    }
}
