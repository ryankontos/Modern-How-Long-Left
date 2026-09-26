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
    public static let recordName = "current"

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
            let record = CKRecord(recordType: Self.recordType, recordID: recordID)
            record["payload"] = try JSONEncoder().encode(payload) as CKRecordValue
            record["generatedAt"] = payload.generatedAt as CKRecordValue
            record["revision"] = payload.revision as CKRecordValue
            _ = try await CKContainer(identifier: containerIdentifier)
                .privateCloudDatabase.save(record)
        } catch {
            // The local App Group projection remains the fallback source.
        }
    }
}
