import HLLKit
import SwiftUI

/// The settings sheet is an index into focused subsections. Storage and
/// mutation behavior stay in `HLLAppModel` and HLLKit.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let model: HLLAppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { PurchaseSettingsView(model: model) } label: {
                        HLLSettingsRow(title: "Premium Access",
                                       subtitle: model.purchaseSnapshot.isUnlocked(.widgets)
                                           ? "Widgets and extras are unlocked"
                                           : "Unlock widgets, activities, and notifications",
                                       systemImage: model.purchaseSnapshot.isUnlocked(.widgets)
                                           ? "checkmark.seal.fill" : "lock.fill",
                                       tint: model.purchaseSnapshot.isUnlocked(.widgets) ? .green : .orange)
                    }
                    NavigationLink { CalendarPreferencesView(model: model) } label: {
                        HLLSettingsRow(title: "Calendar Preferences",
                                       subtitle: "Choose where each calendar appears",
                                       systemImage: "calendar.badge.clock", tint: .blue)
                    }
                    NavigationLink { WidgetSettingsView(model: model) } label: {
                        HLLSettingsRow(title: "Widgets & Complications",
                                       subtitle: "Set defaults for configurable surfaces",
                                       systemImage: "square.grid.2x2", tint: .purple)
                    }
                    NavigationLink { ActivitySettingsView(model: model) } label: {
                        HLLSettingsRow(title: "Live Activities",
                                       subtitle: "Automatically follow events",
                                       systemImage: "timer", tint: .orange)
                    }
                    NavigationLink { NotificationSettingsView(model: model) } label: {
                        HLLSettingsRow(title: "Notifications",
                                       subtitle: "Schedule start and end alerts",
                                       systemImage: "bell", tint: .red)
                    }
                    NavigationLink { HiddenEventsView(model: model) } label: {
                        HLLSettingsRow(title: "Hidden Events",
                                       subtitle: "Restore events you have hidden",
                                       systemImage: "eye.slash", tint: .secondary)
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
                    NavigationLink { AboutSettingsView() } label: {
                        HLLSettingsRow(title: "About How Long Left",
                                       subtitle: "Version and storage information",
                                       systemImage: "info.circle", tint: .gray)
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

/// Shared row styling keeps the settings index consistent without a generic
/// navigation framework that would make destinations harder to follow.
struct HLLSettingsRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint).frame(width: 28)
        }
        .padding(.vertical, 4)
    }
}
