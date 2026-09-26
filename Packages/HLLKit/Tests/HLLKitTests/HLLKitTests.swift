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

@Test func eventStatusUsesExclusiveEndBoundary() {
    let start = Date(timeIntervalSince1970: 1_000)
    let end = start.addingTimeInterval(60)
    let event = HLLEvent(id: UUID(), source: .user, title: "Status",
                         start: start, end: end)

    #expect(event.status(at: start.addingTimeInterval(-0.1)) == .upcoming)
    #expect(event.status(at: start) == .inProgress)
    #expect(event.status(at: end.addingTimeInterval(-0.1)) == .inProgress)
    #expect(event.status(at: end) == .complete)
}

@Test func widgetContentComparisonIgnoresRefreshMetadataAndOrdering() {
    let start = Date(timeIntervalSince1970: 1_000)
    let first = HLLEvent(id: UUID(), source: .user, title: "First",
                         start: start, end: start.addingTimeInterval(60))
    let second = HLLEvent(id: UUID(), source: .user, title: "Second",
                          start: start.addingTimeInterval(120),
                          end: start.addingTimeInterval(180))
    let old = HLLWidgetPayload(revision: 1, generatedAt: start,
                               expiresAt: start.addingTimeInterval(300),
                               events: [first, second], userDefinitions: [],
                               calendars: [:], annotations: [])
    let refreshed = HLLWidgetPayload(revision: 99,
                                     generatedAt: start.addingTimeInterval(30),
                                     expiresAt: start.addingTimeInterval(600),
                                     events: [second, first], userDefinitions: [],
                                     calendars: [:], annotations: [])

    #expect(old.hasSameContent(as: refreshed))
}

@Test func countdownOrderingUsesEndForRunningAndStartForUpcoming() {
    let now = Date(timeIntervalSince1970: 10_000)
    let running = HLLEvent(id: UUID(), source: .user, title: "Running",
                           start: now.addingTimeInterval(-600),
                           end: now.addingTimeInterval(300))
    let startingSooner = HLLEvent(id: UUID(), source: .user, title: "Sooner",
                                  start: now.addingTimeInterval(60),
                                  end: now.addingTimeInterval(3_600))

    #expect(HLLWidgetSortOrder.countdownDate.sort([running, startingSooner], at: now)
        == [startingSooner, running])
    #expect(running.countdownDate(at: now) == running.end)
    #expect(startingSooner.countdownDate(at: now) == startingSooner.start)
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

@Test func compoundIndexIntersectsRunningCandidates() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    let running = HLLEvent(id: UUID(), source: .user, title: "Running", start: base,
                           end: base.addingTimeInterval(3_600), calendarID: "home")
    let futureHome = HLLEvent(id: UUID(), source: .user, title: "Future",
                              start: base.addingTimeInterval(7_200),
                              end: base.addingTimeInterval(10_800), calendarID: "home")
    let otherRunning = HLLEvent(id: UUID(), source: .user, title: "Other", start: base,
                                end: base.addingTimeInterval(3_600), calendarID: "work")
    let rule: HLLEventRule = .and([.calendar("home"), .running(base.addingTimeInterval(60))])
    #expect(HLLEventIndex([running, futureHome, otherRunning]).candidates(for: rule) == [running])
}

@Test func oneOffEventIdentitySurvivesRescheduling() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await HLLDatabase.open(directory: directory, cloudContainerIdentifier: nil)
    let resolver = HLLIdentityResolver(database: database)
    let profile = UUID()
    let first = HLLEventKitSource.RawEvent(
        localID: "local-1", externalID: "external-1", calendarLocalID: "calendar-1",
        calendarTitle: "Home", calendarSourceTitle: "iCloud", calendarSourceIdentifier: "source-1",
        title: "Dinner", start: Date(timeIntervalSince1970: 1_000_000),
        end: Date(timeIntervalSince1970: 1_003_600), occurrenceStart: Date(timeIntervalSince1970: 1_000_000),
        isAllDay: false, hasRecurrence: false, location: nil, notes: nil)
    let moved = HLLEventKitSource.RawEvent(
        localID: "local-2", externalID: "external-1", calendarLocalID: "calendar-1",
        calendarTitle: "Home", calendarSourceTitle: "iCloud", calendarSourceIdentifier: "source-1",
        title: "Dinner", start: Date(timeIntervalSince1970: 1_100_000),
        end: Date(timeIntervalSince1970: 1_103_600), occurrenceStart: Date(timeIntervalSince1970: 1_100_000),
        isAllDay: false, hasRecurrence: false, location: nil, notes: nil)
    let firstIdentity = try await resolver.resolve(first, calendarProfileID: profile)
    let movedIdentity = try await resolver.resolve(moved, calendarProfileID: profile)
    #expect(firstIdentity.id == movedIdentity.id)
    #expect(firstIdentity.portableKey == movedIdentity.portableKey)
}

@Test func queryIntervalAlwaysBoundsComposedRules() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    let inside = HLLEvent(id: UUID(), source: .user, title: "Inside", start: base,
                          end: base.addingTimeInterval(300), calendarID: "home")
    let outside = HLLEvent(id: UUID(), source: .user, title: "Outside",
                           start: base.addingTimeInterval(86_400),
                           end: base.addingTimeInterval(87_000), calendarID: "home")
    let query = HLLEventQuery(
        interval: DateInterval(start: base.addingTimeInterval(-60), duration: 3_600),
        rule: .calendar("home"), context: "test")
    #expect(HLLEventReducer().reduce([inside, outside], query: query,
                                     calendarPreferences: [:], annotations: []) == [inside])
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

@Test func calendarProfileFollowsEventKitSourceWhenLocalIDChanges() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await HLLDatabase.open(directory: directory, cloudContainerIdentifier: nil)
    let repository = HLLRepository(database: database)

    let first = HLLEventKitSource.CalendarInfo(localID: "local-1", title: "Home",
                                                sourceTitle: "iCloud",
                                                sourceIdentifier: "source-1")
    let second = HLLEventKitSource.CalendarInfo(localID: "local-2", title: "Home",
                                                 sourceTitle: "iCloud",
                                                 sourceIdentifier: "source-1")
    let firstProfile = try #require(await repository.bind([first])[first.localID])
    let secondProfile = try #require(await repository.bind([second])[second.localID])
    #expect(firstProfile.id == secondProfile.id)
}

@Test func obsoleteCalendarBindingsArePruned() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await HLLDatabase.open(directory: directory, cloudContainerIdentifier: nil)
    let repository = HLLRepository(database: database)
    let calendars = [
        HLLEventKitSource.CalendarInfo(localID: "old", title: "Home", sourceTitle: "iCloud",
                                       sourceIdentifier: "source-1"),
        HLLEventKitSource.CalendarInfo(localID: "current", title: "Work", sourceTitle: "iCloud",
                                       sourceIdentifier: "source-2")
    ]
    _ = try await repository.bind(calendars)
    try await repository.pruneObsoleteCalendarBindings(keeping: ["current"])
    let bindings = try await database.all(HLLCalendarBinding.self, kind: .calendarBinding,
                                          location: .local)
    #expect(bindings.map(\.localCalendarID) == ["current"])
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

    let notifications = HLLNotificationPreferences(enabled: true,
                                                     notifyAtStart: true,
                                                     notifyAtEnd: false,
                                                     includeAllDay: true,
                                                     context: "notifications.main")
    try await repository.save(notifications)
    #expect(try await repository.notificationPreferences() == notifications)
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

@Test func widgetTimelineReevaluatesSmartCountdownAtTransitions() {
    let now = Date()
    let running = HLLEvent(id: UUID(), source: .user, title: "Running",
                           start: now.addingTimeInterval(-60),
                           end: now.addingTimeInterval(300))
    let startingSoon = HLLEvent(id: UUID(), source: .user, title: "Starting",
                                start: now.addingTimeInterval(100),
                                end: now.addingTimeInterval(500))
    let payload = HLLWidgetPayload(revision: 1, generatedAt: now,
                                   expiresAt: now.addingTimeInterval(86_400),
                                   events: [running, startingSoon], userDefinitions: [],
                                   calendars: [:], annotations: [])
    let points = HLLWidgetTimelinePlanner().plan(
        payload: payload, now: now, context: "test", limit: 1,
        sortOrder: .countdownDate, rule: { .upcoming($0) })

    #expect(points.first?.events == [startingSoon])
    #expect(points.contains { $0.date == startingSoon.start && $0.events == [running] })
    #expect(points.contains { $0.date == running.end && $0.events == [startingSoon] })
}

@Test func widgetProjectionBoundRetainsPinnedEvents() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let events = (0..<4).map { index in
        HLLEvent(id: UUID(), source: .user, title: "Event \(index)",
                 start: start.addingTimeInterval(TimeInterval(index * 60)),
                 end: start.addingTimeInterval(TimeInterval(index * 60 + 30)))
    }
    let pinned = HLLWidgetPayload(revision: 1, generatedAt: start,
                                  expiresAt: start.addingTimeInterval(86_400),
                                  events: events, userDefinitions: [], calendars: [:],
                                  annotations: [HLLAnnotationForTest.pinned(events[3])])
    let limited = pinned.limitingEvents(to: 2)
    #expect(limited.events.count == 2)
    #expect(limited.events.contains(events[3]))
}

private enum HLLAnnotationForTest {
    static func pinned(_ event: HLLEvent) -> HLLEventAnnotation {
        HLLEventAnnotation(kind: .pinned, scope: .occurrence,
                           eventID: event.id, portableKey: event.portableKey)
    }
}

@Test func widgetEventEntityPrefersPortableIdentity() {
    let event = HLLEvent(id: UUID(), source: .eventKit, title: "Pinned",
                         start: .now, end: .now.addingTimeInterval(900),
                         portableKey: "calendar-profile|event|occurrence")
    #expect(HLLWidgetEventEntity(event: event).id == event.portableKey)
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
