import HLLKit
import UIKit

/// User-initiated mutations and feature integrations.
///
/// Keeping these commands away from launch and refresh code makes it clear
/// that every mutation enters HLLKit, invalidates the event engine, and then
/// returns through the model's single revision stream.
extension HLLAppModel {
    func addUserEvent(title: String, start: Date, duration: TimeInterval,
                      isAllDay: Bool = false, recurrence: HLLRecurrenceRule?) {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.engine.save(HLLUserEvent(title: title, start: start,
                                                            duration: duration, isAllDay: isAllDay,
                                                            recurrence: recurrence))
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Deleting one generated user occurrence removes its source definition.
    /// Hiding remains the operation for skipping just one occurrence.
    func deleteUserEvent(_ event: HLLEvent) {
        guard event.source == .user, let runtime else { return }
        let definitionID = event.seriesID.flatMap(UUID.init(uuidString:)) ?? event.id
        Task {
            do { try await runtime.engine.deleteUserEvent(id: definitionID) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func annotate(_ event: HLLEvent, kind: HLLEventAnnotation.Kind,
                  scope: HLLEventAnnotation.Scope) {
        guard let runtime else { return }
        Task {
            do {
                let settings = try await runtime.repository.settings()
                let annotation = HLLEventAnnotation(
                    kind: kind, scope: scope, eventID: event.id,
                    seriesID: event.seriesID, portableKey: event.portableKey,
                    eventTitle: event.title,
                    expiresAt: scope == .occurrence
                        ? event.end.addingTimeInterval(90 * 86_400) : nil,
                    syncAcrossDevices: settings.syncEventAnnotations
                        && event.portableKey != nil)
                try await runtime.engine.save(annotation)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func removeAnnotation(_ annotation: HLLEventAnnotation) {
        guard let runtime else { return }
        Task {
            do { try await runtime.engine.removeAnnotation(id: annotation.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func setAnnotationSync(_ enabled: Bool) {
        guard let runtime else { return }
        annotationSyncEnabled = enabled
        Task {
            do { try await runtime.engine.setAnnotationSync(enabled) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func setCalendarVisibility(_ calendar: HLLCalendarPreference,
                               context: HLLContextID, visible: Bool) {
        guard let runtime else { return }
        Task {
            do {
                try await runtime.engine.setCalendarVisibility(
                    profileID: calendar.id, context: context, isVisible: visible)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setWidgetDefaults(_ defaults: HLLWidgetDefaults) {
        guard let runtime else { return }
        widgetDefaults = defaults
        Task {
            do { try await runtime.repository.save(defaults) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func setNotificationPreferences(_ preferences: HLLNotificationPreferences) {
        guard let runtime else { return }
        guard !preferences.enabled || isFeatureUnlocked(.notifications) else {
            purchaseErrorMessage = "Notifications are available with How Long Left Premium."
            return
        }
        Task {
            do {
                if preferences.enabled {
                    guard try await runtime.notifications.requestAuthorization() else {
                        notificationPreferences.enabled = false
                        errorMessage = "Notifications are disabled in Settings."
                        return
                    }
                }
                var saved = preferences
                saved.updatedAt = .now
                try await runtime.repository.save(saved)
                notificationPreferences = saved
                await reconcileNotifications(using: runtime)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func startActivity(for event: HLLEvent) {
        guard let runtime else { return }
        guard isFeatureUnlocked(.liveActivities) else {
            purchaseErrorMessage = "Live Activities are available with How Long Left Premium."
            return
        }
        Task {
            do {
                try await runtime.liveActivities.start(event)
                activeActivityEventKeys = await runtime.liveActivities.activeEventKeys()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func stopActivity(for event: HLLEvent) {
        guard let runtime else { return }
        Task {
            await runtime.liveActivities.stop(event)
            activeActivityEventKeys = await runtime.liveActivities.activeEventKeys()
        }
    }

    func isActivityRunning(for event: HLLEvent) -> Bool {
        activeActivityEventKeys.contains(event.portableKey ?? event.id.uuidString)
    }

    func isAutomaticallyTracking(_ target: HLLLiveActivityPolicy.Target) -> Bool {
        activityPolicies.contains { $0.target == target }
    }

    func setAutomaticTracking(_ target: HLLLiveActivityPolicy.Target, enabled: Bool) {
        guard let runtime else { return }
        guard !enabled || isFeatureUnlocked(.liveActivities) else {
            purchaseErrorMessage = "Live Activities are available with How Long Left Premium."
            return
        }
        Task {
            do {
                if enabled, !isAutomaticallyTracking(target) {
                    try await runtime.repository.save(HLLLiveActivityPolicy(target: target))
                } else if !enabled {
                    for policy in activityPolicies where policy.target == target {
                        try await runtime.repository.deleteActivityPolicy(id: policy.id)
                    }
                }
                activityPolicies = try await runtime.repository.activityPolicies()
                await reconcileLiveActivities(using: runtime)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func reconcileLiveActivities(using runtime: HLLRuntime) async {
        do {
            let mayStart = UIApplication.shared.applicationState == .active
            try await runtime.liveActivities.reconcile(mayStart: mayStart)
            activeActivityEventKeys = await runtime.liveActivities.activeEventKeys()
        } catch { errorMessage = error.localizedDescription }
    }

    func reconcileNotifications(using runtime: HLLRuntime) async {
        let options = HLLNotificationScheduler.ScheduleOptions(
            notifyAtStart: notificationPreferences.notifyAtStart,
            notifyAtEnd: notificationPreferences.notifyAtEnd,
            includeAllDay: notificationPreferences.includeAllDay)
        do {
            let visibleEvents = notificationPreferences.enabled ? events : []
            try await runtime.notifications.reconcile(events: visibleEvents, options: options)
        } catch { errorMessage = error.localizedDescription }
    }
}
