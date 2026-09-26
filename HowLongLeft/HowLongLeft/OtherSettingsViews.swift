import HLLKit
import SwiftUI

/// Hidden-event management is separate from event rendering so settings can
/// restore annotations without loading or rebuilding the event list.
struct HiddenEventsView: View {
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
                            Text(annotation.eventTitle ?? (annotation.scope == .series
                                                          ? "Hidden series" : "Hidden event"))
                            Text(annotation.scope == .series ? "Every occurrence" : "This occurrence")
                                .font(.caption).foregroundStyle(.secondary)
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

struct AboutSettingsView: View {
    var body: some View {
        List {
            Section("How Long Left") {
                LabeledContent("Version", value: "3.0")
                LabeledContent("Build", value: "253")
                LabeledContent("Architecture", value: "HLLKit + Swift 6")
            }
            Section("Storage") {
                Text("Settings and user events use the HLLKit repository. The app group keeps one atomic local EventKit snapshot, while CloudKit stores portable settings and user-created data only.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
    }
}
