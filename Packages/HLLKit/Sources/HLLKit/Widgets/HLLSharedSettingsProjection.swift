import CloudKit
import Foundation

/// Cross-device data that does not depend on one device's EventKit IDs.
///
/// iPhone and watch projections stay separate because their calendars are
/// different. This small shared record lets an extension learn about synced
/// user events and portable annotations even when its app has not launched.
public struct HLLSharedSettingsProjection: Codable, Sendable, Equatable {
    public let revision: UInt64
    public let generatedAt: Date
    /// Latest logical portable-data mutation, including deletions.
    public let contentUpdatedAt: Date
    public let settings: HLLAppSettings
    public let calendars: [HLLCalendarPreference]
    public let userDefinitions: [HLLUserEvent]
    public let annotations: [HLLEventAnnotation]

    public init(revision: UInt64, generatedAt: Date = .now,
                contentUpdatedAt: Date = .distantPast,
                settings: HLLAppSettings,
                calendars: [HLLCalendarPreference],
                userDefinitions: [HLLUserEvent],
                annotations: [HLLEventAnnotation]) {
        self.revision = revision
        self.generatedAt = generatedAt
        self.contentUpdatedAt = contentUpdatedAt
        self.settings = settings
        self.calendars = calendars
        self.userDefinitions = userDefinitions
        self.annotations = annotations
    }

    /// Revisions and generation dates describe transport attempts. Only these
    /// fields affect another device, so equal content does not need a CloudKit
    /// save and its accompanying remote notifications.
    public func hasSameContent(as other: Self) -> Bool {
        settings == other.settings
            && calendars.sorted(by: calendarOrder) == other.calendars.sorted(by: calendarOrder)
            && userDefinitions.sorted(by: userOrder) == other.userDefinitions.sorted(by: userOrder)
            && annotations.sorted(by: annotationOrder) == other.annotations.sorted(by: annotationOrder)
    }

    private func calendarOrder(_ lhs: HLLCalendarPreference,
                               _ rhs: HLLCalendarPreference) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private func userOrder(_ lhs: HLLUserEvent, _ rhs: HLLUserEvent) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private func annotationOrder(_ lhs: HLLEventAnnotation,
                                 _ rhs: HLLEventAnnotation) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }
}

/// One replaceable private CloudKit record. It is deliberately independent
/// from Core Data mirroring, so extensions only perform one bounded read.
public struct HLLSharedSettingsProjectionStore: Sendable {
    public static let recordType = "HLLSharedSettingsProjection"
    // CloudKit record IDs are unique within a zone, regardless of record type.
    // A namespaced ID prevents this singleton from colliding with the purchase
    // singleton, which lives in the same private database.
    public static let recordName = "hll.shared-settings.current"

    private let containerIdentifier: String

    public init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
    }

    public func read() async -> HLLSharedSettingsProjection? {
        do {
            let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
            let record = try await database.record(for: CKRecord.ID(recordName: Self.recordName))
            guard let data = record["payload"] as? Data else { return nil }
            return try JSONDecoder().decode(HLLSharedSettingsProjection.self, from: data)
        } catch {
            return nil
        }
    }

    public func write(_ projection: HLLSharedSettingsProjection) async {
        do {
            let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
            let recordID = CKRecord.ID(recordName: Self.recordName)
            let payload = try JSONEncoder().encode(projection) as CKRecordValue
            let update: (CKRecord) -> Void = { record in
                record["payload"] = payload
                record["generatedAt"] = projection.generatedAt as CKRecordValue
                record["contentUpdatedAt"] = projection.contentUpdatedAt as CKRecordValue
                record["revision"] = projection.revision as CKRecordValue
            }
            try await saveReplacing(projection: projection, recordID: recordID,
                                    database: database, update: update)
        } catch {
            // A later app refresh retries. The platform projection remains usable.
        }
    }

    private func saveReplacing(projection: HLLSharedSettingsProjection,
                               recordID: CKRecord.ID, database: CKDatabase,
                               update: (CKRecord) -> Void) async throws {
        do {
            let record = try await database.record(for: recordID)
            if let serverDate = record["contentUpdatedAt"] as? Date,
               serverDate > projection.contentUpdatedAt { return }
            if let data = record["payload"] as? Data,
               let existing = try? JSONDecoder().decode(HLLSharedSettingsProjection.self, from: data),
               projection.hasSameContent(as: existing) {
                return
            }
            update(record)
            do {
                _ = try await database.save(record)
            } catch let error as CKError where error.code == .serverRecordChanged {
                let latest = try await database.record(for: recordID)
                if let serverDate = latest["contentUpdatedAt"] as? Date,
                   serverDate > projection.contentUpdatedAt { return }
                if let data = latest["payload"] as? Data,
                   let existing = try? JSONDecoder().decode(HLLSharedSettingsProjection.self, from: data),
                   projection.hasSameContent(as: existing) {
                    return
                }
                update(latest)
                _ = try await database.save(latest)
            }
        } catch let error as CKError where error.code == .unknownItem {
            let record = CKRecord(recordType: Self.recordType, recordID: recordID)
            update(record)
            do {
                _ = try await database.save(record)
            } catch let conflict as CKError where conflict.code == .serverRecordChanged {
                let latest = try await database.record(for: recordID)
                if let serverDate = latest["contentUpdatedAt"] as? Date,
                   serverDate > projection.contentUpdatedAt { return }
                update(latest)
                _ = try await database.save(latest)
            }
        }
    }
}
