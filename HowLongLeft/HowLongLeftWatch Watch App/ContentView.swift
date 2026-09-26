import HLLKit
import SwiftUI

struct WatchContentView: View {
    let model: WatchEventModel

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView()
                } else if model.events.isEmpty {
                    ContentUnavailableView("No events", systemImage: "calendar")
                } else {
                    List(model.events) { event in
                        VStack(alignment: .leading) {
                            Text(event.title).font(.headline)
                            Text(event.end, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("How Long Left")
            .safeAreaInset(edge: .bottom) {
                if model.needsCalendarAccess {
                    Button("Allow Calendars") { model.requestCalendarAccess() }
                }
            }
        }
    }
}
