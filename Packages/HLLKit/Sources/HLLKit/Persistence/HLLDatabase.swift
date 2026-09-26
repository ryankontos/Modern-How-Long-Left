@preconcurrency import CoreData
import Foundation

/// The apps own this stack. Extensions read a small App Group snapshot instead.
public actor HLLDatabase {
    public enum Location: Sendable { case cloud, local }
    public enum RecordKind: String, Sendable {
        case preference, widgetDefaults, calendar, calendarVisibility, userEvent, annotation, calendarBinding, eventIdentity, activityPolicy
    }

    private let container: NSPersistentCloudKitContainer
    private let mirrorsCloudKit: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init(container: NSPersistentCloudKitContainer, mirrorsCloudKit: Bool) {
        self.container = container
        self.mirrorsCloudKit = mirrorsCloudKit
    }

    /// A CloudKit identifier enables mirroring. Passing nil keeps a fully functional local store.
    public static func open(directory: URL, cloudContainerIdentifier: String?) async throws -> HLLDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = NSPersistentCloudKitContainer(name: "HLLKit", managedObjectModel: model())
        let cloud = NSPersistentStoreDescription(url: directory.appending(path: "Cloud.sqlite"))
        cloud.configuration = "Cloud"
        cloud.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        cloud.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        if let cloudContainerIdentifier {
            cloud.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: cloudContainerIdentifier)
        }
        let local = NSPersistentStoreDescription(url: directory.appending(path: "Local.sqlite"))
        local.configuration = "Local"
        container.persistentStoreDescriptions = [cloud, local]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var remaining = 2
            var firstError: Error?
            let lock = NSLock()
            container.loadPersistentStores { _, error in
                lock.lock()
                if firstError == nil { firstError = error }
                remaining -= 1
                let done = remaining == 0
                let finalError = firstError
                lock.unlock()
                if done {
                    if let finalError { continuation.resume(throwing: finalError) }
                    else { continuation.resume() }
                }
            }
        }
        return HLLDatabase(container: container,
                           mirrorsCloudKit: cloudContainerIdentifier != nil)
    }

    /// Writes are upserts by logical key. Duplicate rows from cloud merges are collapsed on read.
    public func put<T: Encodable & Sendable>(_ value: T, kind: RecordKind, key: String,
                                              location: Location) async throws {
        let data = try encoder.encode(value)
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        try await context.perform {
            let entityName = location == .cloud ? "CloudRecord" : "LocalRecord"
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            request.predicate = NSPredicate(format: "kind == %@ AND recordKey == %@", kind.rawValue, key)
            let matches = try context.fetch(request)
            let record = matches.first ?? NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
            record.setValue(kind.rawValue, forKey: "kind")
            record.setValue(key, forKey: "recordKey")
            record.setValue(data, forKey: "payload")
            record.setValue(Date(), forKey: "updatedAt")
            for duplicate in matches.dropFirst() { context.delete(duplicate) }
            try context.save()
        }
    }

    public func remove(kind: RecordKind, key: String, location: Location) async throws {
        let context = container.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: location == .cloud ? "CloudRecord" : "LocalRecord")
            request.predicate = NSPredicate(format: "kind == %@ AND recordKey == %@", kind.rawValue, key)
            for record in try context.fetch(request) { context.delete(record) }
            if context.hasChanges { try context.save() }
        }
    }

    public func all<T: Decodable & Sendable>(_ type: T.Type, kind: RecordKind,
                                              location: Location) async throws -> [T] {
        let context = container.newBackgroundContext()
        let rows: [(String, Data, Date)] = try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: location == .cloud ? "CloudRecord" : "LocalRecord")
            request.predicate = NSPredicate(format: "kind == %@", kind.rawValue)
            request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
            return try context.fetch(request).compactMap { record in
                guard let key = record.value(forKey: "recordKey") as? String,
                      let payload = record.value(forKey: "payload") as? Data else { return nil }
                return (key, payload, record.value(forKey: "updatedAt") as? Date ?? .distantPast)
            }
        }
        var seen = Set<String>()
        return try rows.compactMap { key, data, _ in
            guard seen.insert(key).inserted else { return nil }
            return try decoder.decode(T.self, from: data)
        }
    }

    /// Remove only ephemeral, device-local aliases that have not been observed recently.
    public func pruneOldEventIdentities(before cutoff: Date) async throws {
        let context = container.newBackgroundContext()
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "LocalRecord")
            request.predicate = NSPredicate(format: "kind == %@ AND updatedAt < %@",
                                            RecordKind.eventIdentity.rawValue, cutoff as NSDate)
            for record in try context.fetch(request) { context.delete(record) }
            if context.hasChanges { try context.save() }
        }
    }

    /// CloudKit models cannot use unique constraints, so reconcile duplicate logical keys.
    public func compactDuplicateRows() async throws {
        for entityName in ["CloudRecord", "LocalRecord"] {
            let context = container.newBackgroundContext()
            try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
                var seen = Set<String>()
                for record in try context.fetch(request) {
                    let key = "\(record.value(forKey: "kind") ?? "")|\(record.value(forKey: "recordKey") ?? "")"
                    if !seen.insert(key).inserted { context.delete(record) }
                }
                if context.hasChanges { try context.save() }
            }
        }
    }

    /// CloudKit needs persistent history until export succeeds. Purge only old,
    /// exported transactions, and only during infrequent background maintenance.
    public func pruneExportedHistory(olderThan age: TimeInterval = 180 * 86_400) async throws {
        guard mirrorsCloudKit,
              let cloudStore = container.persistentStoreCoordinator.persistentStores.first(where: {
                  $0.configurationName == "Cloud"
              }) else { return }
        let context = container.newBackgroundContext()
        try await context.perform {
            let fetch = NSPersistentCloudKitContainerEventRequest.fetchForEvents()
            fetch.predicate = NSPredicate(format: "type == %d AND succeeded == YES AND endDate != nil",
                                          NSPersistentCloudKitContainer.EventType.export.rawValue)
            fetch.sortDescriptors = [NSSortDescriptor(key: "endDate", ascending: false)]
            fetch.fetchLimit = 1
            let eventsRequest = NSPersistentCloudKitContainerEventRequest.fetchEvents(matchingFetch: fetch)
            eventsRequest.affectedStores = [cloudStore]
            let result = try context.execute(eventsRequest) as? NSPersistentCloudKitContainerEventResult
            guard let lastExport = (result?.result as? [NSPersistentCloudKitContainer.Event])?.first,
                  let completedAt = lastExport.endDate else { return }
            let cutoff = min(Date().addingTimeInterval(-age),
                             completedAt.addingTimeInterval(-7 * 86_400))
            let historyRequest = NSPersistentHistoryChangeRequest.deleteHistory(before: cutoff)
            historyRequest.affectedStores = [cloudStore]
            _ = try context.execute(historyRequest)
        }
    }

    /// CloudKit only mirrors the Cloud configuration. Both models use scalar fields and defaults.
    private static func model() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        func entity(_ name: String) -> NSEntityDescription {
            let entity = NSEntityDescription()
            entity.name = name
            entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
            func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
                let item = NSAttributeDescription()
                item.name = name
                item.attributeType = type
                item.isOptional = false
                return item
            }
            let kind = attribute("kind", .stringAttributeType)
            kind.defaultValue = ""
            let key = attribute("recordKey", .stringAttributeType)
            key.defaultValue = ""
            let payload = attribute("payload", .binaryDataAttributeType)
            payload.defaultValue = Data()
            let updated = attribute("updatedAt", .dateAttributeType)
            updated.defaultValue = Date.distantPast
            entity.properties = [kind, key, payload, updated]
            entity.indexes = [NSFetchIndexDescription(name: "byKindAndKey", elements: [
                NSFetchIndexElementDescription(property: kind, collationType: .binary),
                NSFetchIndexElementDescription(property: key, collationType: .binary)
            ])]
            return entity
        }
        let cloud = entity("CloudRecord")
        let local = entity("LocalRecord")
        model.entities = [cloud, local]
        model.setEntities([cloud], forConfigurationName: "Cloud")
        model.setEntities([local], forConfigurationName: "Local")
        return model
    }
}
