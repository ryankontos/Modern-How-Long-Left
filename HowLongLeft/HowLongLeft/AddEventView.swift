import HLLKit
import SwiftUI

/// Minimal editor for an app-owned event definition. Repeating occurrences
/// are generated in HLLKit so this view stores one compact record per series.
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
