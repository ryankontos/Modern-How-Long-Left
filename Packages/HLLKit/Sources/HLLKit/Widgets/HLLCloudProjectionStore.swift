import CloudKit
import Foundation

/// A single replaceable CloudKit record keeps extension settings fresh even when
/// this device has not opened the app since another device made a change.
///
/// The Core Data CloudKit mirror remains app-owned. Extensions use this tiny
/// read path instead of opening that mirror, which avoids multi-process
/// mirroring races and keeps timeline work bounded.
public struct HLLCloudProjectionStore: Sendable {
    public static let recordType = "HLLWidgetProjection"
    /// iPhone and watch have different EventKit universes. Keeping separate
    /// records prevents a watch refresh from becoming an iOS widget payload.
    public static var recordName: String {
#if os(watchOS)
        "current-watchOS"
#else
        "current-iOS"
#endif
    }

    private let containerIdentifier: String

    public init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
    }

    public func read() async -> HLLWidgetPayload? {
        do {
            let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
            let record = try await database.record(for: CKRecord.ID(recordName: Self.recordName))
            guard let data = record["payload"] as? Data else { return nil }
            return try JSONDecoder().decode(HLLWidgetPayload.self, from: data)
        } catch {
            // Offline, not signed in, or a not-yet-deployed schema: use the
            // atomic App Group copy instead of failing a widget timeline.
            return nil
        }
    }

    public func write(_ payload: HLLWidgetPayload) async {
        do {
            let recordID = CKRecord.ID(recordName: Self.recordName)
            let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
            let encoded = try JSONEncoder().encode(payload) as CKRecordValue
            let update: (CKRecord) -> Void = { record in
                record["payload"] = encoded
                record["generatedAt"] = payload.generatedAt as CKRecordValue
                record["revision"] = payload.revision as CKRecordValue
            }
            try await saveReplacing(recordID: recordID, database: database, update: update)
        } catch {
            // The local App Group projection remains the fallback source.
        }
    }

    private func saveReplacing(recordID: CKRecord.ID, database: CKDatabase,
                               update: (CKRecord) -> Void) async throws {
        do {
            let record = try await database.record(for: recordID)
            update(record)
            do {
                _ = try await database.save(record)
            } catch let error as CKError where error.code == .serverRecordChanged {
                let latest = try await database.record(for: recordID)
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
                update(latest)
                _ = try await database.save(latest)
            }
        }
    }
}
