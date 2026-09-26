import Foundation
import Testing
@testable import HLLKit

@Test func deterministicIdentityAndFiltering() {
    let date = Date(timeIntervalSince1970: 1_000_000)
    let id = HLLStableID.make(["a", "b"])
    #expect(id == HLLStableID.make(["a", "b"]))
    let event = HLLEvent(id: id, source: .user, title: "Test", start: date,
                         end: date.addingTimeInterval(3600))
    let query = HLLEventQuery(interval: DateInterval(start: date, duration: 7200),
                              rule: .running(date.addingTimeInterval(60)), context: "test")
    #expect(HLLEventReducer().reduce([event], query: query,
                                     calendarPreferences: [:], annotations: []) == [event])
}

@Test func indexedRulesAndCalendarContexts() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    let morning = HLLEvent(id: UUID(), source: .eventKit, title: "Morning", start: base,
                           end: base.addingTimeInterval(3600), calendarID: "home")
    let evening = HLLEvent(id: UUID(), source: .eventKit, title: "Evening",
                           start: base.addingTimeInterval(20_000), end: base.addingTimeInterval(21_000),
                           isAllDay: false, calendarID: "work")
    let context: HLLContextID = "dashboard.compact"
    let query = HLLEventQuery(interval: DateInterval(start: base, duration: 86_400),
                              rule: .and([.calendar("home"), .running(base.addingTimeInterval(30)),
                                          .allDay(false)]), context: context)
    let index = HLLEventIndex([morning, evening])
    #expect(index.candidates(for: query.rule).count == 1)
    #expect(HLLEventReducer().reduce(index, query: query, calendarPreferences: [:],
                                     annotations: []) == [morning])
    let hidden = HLLCalendarPreference(title: "Home", visibility: [context: false])
    #expect(HLLEventReducer().reduce(index, query: query,
                                     calendarPreferences: ["home": hidden], annotations: []).isEmpty)
}

@Test func localDatabaseRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await HLLDatabase.open(directory: directory, cloudContainerIdentifier: nil)
    let repository = HLLRepository(database: database)
    let event = HLLUserEvent(title: "Saved", start: .now, duration: 1_200)
    try await repository.save(event)
    #expect(try await repository.userEvents().contains(event))
    try await repository.deleteUserEvent(id: event.id)
    #expect(try await repository.userEvents().isEmpty)
}

@Test func calendarVisibilityPersistsByContext() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await HLLDatabase.open(directory: directory, cloudContainerIdentifier: nil)
    let repository = HLLRepository(database: database)
    let profile = HLLCalendarPreference(title: "Home", sourceTitle: "iCloud")
    try await repository.save(profile)
    try await repository.setCalendarVisibility(profileID: profile.id, context: "home.main", isVisible: false)
    try await repository.setCalendarVisibility(profileID: profile.id, context: "widget.default", isVisible: true)
    let loaded = try #require(await repository.calendarPreferences().first)
    #expect(!loaded.isVisible(in: "home.main"))
    #expect(loaded.isVisible(in: "widget.default"))
    #expect(loaded.isVisible(in: "new.context"))
}

@Test func appSettingsAndWidgetDefaultsStayTypeSafe() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await HLLDatabase.open(directory: directory, cloudContainerIdentifier: nil)
    let repository = HLLRepository(database: database)

    var settings = HLLAppSettings()
    settings.syncEventAnnotations = false
    try await repository.save(settings)
    let defaults = HLLWidgetDefaults(mode: .all, style: .progress,
                                      includeAllDay: false, eventCount: 4)
    try await repository.save(defaults)

    #expect(try await repository.settings().syncEventAnnotations == false)
    #expect(try await repository.widgetDefaults() == defaults)
}

@Test func sharedProjectionKeepsPortableDataOnly() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await HLLDatabase.open(directory: directory, cloudContainerIdentifier: nil)
    let repository = HLLRepository(database: database)
    let profile = HLLCalendarPreference(title: "Home", sourceTitle: "iCloud")
    let userEvent = HLLUserEvent(title: "Personal", start: .now, duration: 600)
    let portable = HLLEventAnnotation(kind: .hidden, scope: .occurrence,
                                       portableKey: "profile|event|occurrence")
    let localOnly = HLLEventAnnotation(kind: .hidden, scope: .occurrence,
                                       eventID: UUID())

    try await repository.save(profile)
    try await repository.save(userEvent)
    try await repository.save(portable)
    try await repository.save(localOnly)

    let projection = try await repository.sharedSettingsProjection(revision: 4)
    #expect(projection.revision == 4)
    #expect(projection.calendars.contains(profile))
    #expect(projection.userDefinitions.contains(userEvent))
    #expect(projection.annotations == [portable])
}

@Test func recurrenceHandlesWeekAlignmentAndMonthEnd() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 10))!
    let monthly = HLLUserEvent(title: "Monthly", start: start, duration: 3600,
                               recurrence: HLLRecurrenceRule(frequency: .monthly))
    let window = DateInterval(start: start, end: calendar.date(byAdding: .month, value: 5, to: start)!)
    let occurrences = HLLUserOccurrenceGenerator().occurrences(of: monthly, in: window,
                                                                 calendar: calendar)
    #expect(occurrences.map { calendar.component(.month, from: $0.start) } == [1, 3, 5])

    let monday = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 10))!
    let biweekly = HLLUserEvent(title: "Biweekly", start: monday, duration: 3600,
        recurrence: HLLRecurrenceRule(frequency: .weekly, interval: 2, weekdays: [2, 4]))
    let after = DateInterval(start: monday, end: calendar.date(byAdding: .day, value: 29, to: monday)!)
    let dates = HLLUserOccurrenceGenerator().occurrences(of: biweekly, in: after,
                                                         calendar: calendar).map { $0.start }
    #expect(dates.count == 5)
    #expect(calendar.dateComponents([.day], from: dates[0], to: dates[2]).day == 14)
}

@Test func annotationIdentityAndWidgetFiltering() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let event = HLLEvent(id: UUID(), source: .eventKit, title: "Hidden", start: start,
                         end: start.addingTimeInterval(3600), portableKey: "portable")
    let hidden = HLLEventAnnotation(kind: .hidden, scope: .occurrence,
                                    eventID: event.id, portableKey: "portable")
    #expect(hidden.id == HLLEventAnnotation(kind: .hidden, scope: .occurrence,
                                             eventID: UUID(), portableKey: "portable").id)
    let payload = HLLWidgetPayload(revision: 1, generatedAt: start,
                                   expiresAt: start.addingTimeInterval(86_400),
                                   events: [event], userDefinitions: [], calendars: [:],
                                   annotations: [hidden])
    let points = HLLWidgetTimelinePlanner().plan(payload: payload, now: start,
        context: "new.widget.mode", limit: 3, rule: { .upcoming($0) })
    #expect(points.allSatisfy { $0.events.isEmpty })
}

@Test func purchaseSnapshotsRespectExpiryAndRevocation() {
    let soon = Date(timeIntervalSince1970: 10_000)
    let active = HLLFeatureEntitlement(feature: .widgets, isUnlocked: true,
                                        productIDs: ["HLLWidget"],
                                        expirationDate: soon.addingTimeInterval(60))
    let snapshot = HLLPurchaseSnapshot(checkedAt: soon, features: [
        .widgets: active,
        .complications: HLLFeatureEntitlement(feature: .complications, isUnlocked: false),
        .liveActivities: HLLFeatureEntitlement(feature: .liveActivities, isUnlocked: false),
        .notifications: HLLFeatureEntitlement(feature: .notifications, isUnlocked: false)
    ])
    #expect(snapshot.isUnlocked(.widgets, at: soon))
    #expect(!snapshot.isUnlocked(.widgets, at: soon.addingTimeInterval(61)))
    #expect(!HLLFeatureEntitlement(feature: .widgets, isUnlocked: true,
                                   productIDs: ["HLLWidget"], revocationDate: soon)
        .isActive(at: soon))
    #expect(HLLPurchaseConfiguration.shipping.definition(for: "HLLWidget")?.features
        .contains(.liveActivities) == true)
}
