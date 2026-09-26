import Foundation

/// One runtime per app process. It keeps I/O and EventKit work outside the UI layer.
public actor HLLRuntime {
    public let eventKit: HLLEventKitSource
    public let repository: HLLRepository
    public let engine: HLLEventEngine
    public let widgetStore: HLLWidgetSnapshotStore
    public let cloudProjection: HLLCloudProjectionStore?
    /// StoreKit-backed entitlement coordinator shared by every feature boundary.
    /// The actor owns transaction updates and persists a small cache for extensions.
    public let purchases: HLLPurchaseCoordinator
#if canImport(UserNotifications)
    public let notifications: HLLNotificationScheduler
#endif
#if os(iOS)
    public let liveActivities: HLLLiveActivityCoordinator
#endif
    private var lastPublishedRevision: UInt64?
    private var lastPublishedAt: Date?
    private var lastCloudProjectionRevision: UInt64?
    private let cloudContainerIdentifier: String?

    #if canImport(UserNotifications)
    private init(eventKit: HLLEventKitSource, repository: HLLRepository,
                 engine: HLLEventEngine, widgetStore: HLLWidgetSnapshotStore,
                 cloudProjection: HLLCloudProjectionStore?,
                 cloudContainerIdentifier: String?, purchases: HLLPurchaseCoordinator,
                 notifications: HLLNotificationScheduler) {
        self.eventKit = eventKit
        self.repository = repository
        self.engine = engine
        self.widgetStore = widgetStore
        self.cloudProjection = cloudProjection
        self.cloudContainerIdentifier = cloudContainerIdentifier
        self.purchases = purchases
        self.notifications = notifications
#if os(iOS)
        self.liveActivities = HLLLiveActivityCoordinator(engine: engine, repository: repository,
                                                         purchases: purchases)
#endif
    }
    #else
    private init(eventKit: HLLEventKitSource, repository: HLLRepository,
                 engine: HLLEventEngine, widgetStore: HLLWidgetSnapshotStore,
                 cloudProjection: HLLCloudProjectionStore?,
                 cloudContainerIdentifier: String?, purchases: HLLPurchaseCoordinator) {
        self.eventKit = eventKit
        self.repository = repository
        self.engine = engine
        self.widgetStore = widgetStore
        self.cloudProjection = cloudProjection
        self.cloudContainerIdentifier = cloudContainerIdentifier
        self.purchases = purchases
#if os(iOS)
        self.liveActivities = HLLLiveActivityCoordinator(engine: engine, repository: repository,
                                                         purchases: purchases)
#endif
    }
    #endif

    /// A process has exactly one CloudKit mirror, even when it has several scenes.
    public static func shared(groupIdentifier: String,
                              cloudContainerIdentifier: String) async throws -> HLLRuntime {
        try await HLLRuntimeRegistry.shared.runtime(groupIdentifier: groupIdentifier,
                                                     cloudContainerIdentifier: cloudContainerIdentifier)
    }

    fileprivate static func open(groupIdentifier: String,
                                 cloudContainerIdentifier: String) async throws -> HLLRuntime {
        let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appending(path: "Database") ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "HLLKit")
        let database = try await HLLDatabase.open(directory: directory,
                                                   cloudContainerIdentifier: cloudContainerIdentifier)
        // Direct CloudKit projection records need explicit subscriptions. Do
        // this after the stores are open and never make launch wait for it.
        Task.detached(priority: .utility) {
            _ = await HLLCloudKitSubscriptionInstaller(
                containerIdentifier: cloudContainerIdentifier).install()
        }
        let eventKit = HLLEventKitSource()
        let repository = HLLRepository(database: database)
        Task.detached(priority: .background) {
            // Keep recurring launch cheap; cleanup runs at most monthly per device.
            let marker = directory.appending(path: "LastMaintenance.txt")
            if let data = try? Data(contentsOf: marker),
               let value = String(data: data, encoding: .utf8),
               let timestamp = TimeInterval(value),
               Date().timeIntervalSince1970 - timestamp < 30 * 86_400 { return }
            do {
                try await database.pruneOldEventIdentities(before: Date().addingTimeInterval(-90 * 86_400))
                try await repository.pruneExpiredAnnotations(before: .now)
                // An empty list can mean permission has not been granted, so
                // only prune bindings after an authorized EventKit read.
                if await eventKit.authorizationStatus() == .fullAccess {
                    let calendars = await eventKit.calendars()
                    try await repository.pruneObsoleteCalendarBindings(
                        keeping: Set(calendars.map(\.localID)))
                }
                try await database.compactDuplicateRows()
                try await database.pruneExportedHistory()
                try Data(String(Date().timeIntervalSince1970).utf8).write(to: marker, options: .atomic)
            } catch {
                // A later launch retries maintenance without delaying this launch.
            }
        }
        let identities = HLLIdentityResolver(database: database)
        let engine = HLLEventEngine(eventKit: eventKit, repository: repository, identities: identities)
        let purchaseStore = HLLPurchaseSnapshotStore(
            groupIdentifier: groupIdentifier,
            cloudContainerIdentifier: cloudContainerIdentifier)
#if canImport(WatchConnectivity)
        let purchaseBridge = HLLPurchaseWatchBridge(store: purchaseStore)
        let purchases = HLLPurchaseCoordinator(snapshotStore: purchaseStore,
                                                watchBridge: purchaseBridge)
#else
        let purchases = HLLPurchaseCoordinator(snapshotStore: purchaseStore)
#endif
#if canImport(UserNotifications)
        let notifications = HLLNotificationScheduler(purchases: purchases)
#endif
#if canImport(UserNotifications)
        return HLLRuntime(eventKit: eventKit, repository: repository, engine: engine,
                          widgetStore: HLLWidgetSnapshotStore(groupIdentifier: groupIdentifier),
                          cloudProjection: HLLCloudProjectionStore(containerIdentifier: cloudContainerIdentifier),
                          cloudContainerIdentifier: cloudContainerIdentifier,
                          purchases: purchases, notifications: notifications)
#else
        return HLLRuntime(eventKit: eventKit, repository: repository, engine: engine,
                          widgetStore: HLLWidgetSnapshotStore(groupIdentifier: groupIdentifier),
                          cloudProjection: HLLCloudProjectionStore(containerIdentifier: cloudContainerIdentifier),
                          cloudContainerIdentifier: cloudContainerIdentifier,
                          purchases: purchases)
#endif
    }

    /// Call after source or settings changes. Timeline reloads are requested by the app target.
    @discardableResult
    public func publishWidgetSnapshot(days: Int = 14) async throws -> Bool {
        let now = Date()
        let currentRevision = await engine.currentRevision
        if lastPublishedRevision == currentRevision,
           let lastPublishedAt, now.timeIntervalSince(lastPublishedAt) < 15 * 60 { return false }
        let interval = DateInterval(start: now.addingTimeInterval(-86_400),
                                    end: now.addingTimeInterval(TimeInterval(days) * 86_400))
        let payload = try await engine.widgetProjection(in: interval, now: now)
            .limitingEvents()
        try widgetStore.write(payload)
        lastPublishedRevision = payload.revision
        lastPublishedAt = now
        if lastCloudProjectionRevision != payload.revision, let cloudProjection {
            lastCloudProjectionRevision = payload.revision
            Task.detached(priority: .utility) {
                await cloudProjection.write(payload)
            }
        }
        // This projection is portable across the iPhone/watch EventKit
        // boundary. It is written separately so a watch extension can learn
        // about synced annotations and user events without opening Core Data.
        let repository = repository
        if let cloudContainerIdentifier, !cloudContainerIdentifier.isEmpty {
            Task.detached(priority: .utility) {
                guard let shared = try? await repository.sharedSettingsProjection(
                    revision: payload.revision, generatedAt: now) else { return }
                await HLLSharedSettingsProjectionStore(
                    containerIdentifier: cloudContainerIdentifier).write(shared)
            }
        }
        return true
    }
}

private actor HLLRuntimeRegistry {
    static let shared = HLLRuntimeRegistry()
    private var opening: Task<HLLRuntime, Error>?

    func runtime(groupIdentifier: String, cloudContainerIdentifier: String) async throws -> HLLRuntime {
        if let opening { return try await opening.value }
        let task = Task {
            try await HLLRuntime.open(groupIdentifier: groupIdentifier,
                                      cloudContainerIdentifier: cloudContainerIdentifier)
        }
        opening = task
        do { return try await task.value }
        catch {
            opening = nil
            throw error
        }
    }
}
