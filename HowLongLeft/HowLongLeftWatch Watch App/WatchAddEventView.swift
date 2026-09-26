import HLLKit
import SwiftUI

/// A deliberately small watch editor for personal events. The model sends the
/// definition to HLLKit, where recurrence expansion and CloudKit sync live.
struct WatchAddEventView: View {
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
