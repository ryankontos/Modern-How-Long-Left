import CloudKit
import Foundation

/// Stores one small entitlement projection locally and in the user's private
/// CloudKit database. The local file makes extensions fast; the private record
/// lets iPhone and watch recover purchase state independently.
public struct HLLPurchaseSnapshotStore: Sendable {
    public static let recordType = "HLLPurchaseStatus"
    // CloudKit record IDs are unique within a zone, regardless of record type.
    public static let recordName = "hll.purchase-status.current"

    private let groupIdentifier: String
    private let cloudContainerIdentifier: String?

    public init(groupIdentifier: String, cloudContainerIdentifier: String? = nil) {
        self.groupIdentifier = groupIdentifier
        self.cloudContainerIdentifier = cloudContainerIdentifier
    }

    public func readLocal() -> HLLPurchaseSnapshot? {
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HLLPurchaseSnapshot.self, from: data)
    }

    public func writeLocal(_ snapshot: HLLPurchaseSnapshot) throws {
        guard let url = fileURL() else { throw HLLPurchaseStoreError.appGroupUnavailable }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// Reads CloudKit with a short deadline. StoreKit remains the authority;
    /// this path only prevents a disconnected device from starting locked.
    public func readCloud() async -> HLLPurchaseSnapshot? {
        guard let cloudContainerIdentifier, !cloudContainerIdentifier.isEmpty else { return nil }
        return await withTaskGroup(of: HLLPurchaseSnapshot?.self) { group in
            group.addTask {
                do {
                    let database = CKContainer(identifier: cloudContainerIdentifier).privateCloudDatabase
                    let record = try await database.record(for: CKRecord.ID(recordName: Self.recordName))
                    guard let data = record["payload"] as? Data else { return nil }
                    return try JSONDecoder().decode(HLLPurchaseSnapshot.self, from: data)
                        .replacing(source: .cloudKitCache)
                } catch { return nil }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1.5))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    public func readBest() async -> HLLPurchaseSnapshot? {
        let local = readLocal()
        let cloud = await readCloud()
        return [local, cloud].compactMap { $0 }.max { $0.checkedAt < $1.checkedAt }
    }

    public func persist(_ snapshot: HLLPurchaseSnapshot) async {
        try? writeLocal(snapshot)
        guard let cloudContainerIdentifier, !cloudContainerIdentifier.isEmpty else { return }
        do {
            let database = CKContainer(identifier: cloudContainerIdentifier).privateCloudDatabase
            let recordID = CKRecord.ID(recordName: Self.recordName)
            let payload = try JSONEncoder().encode(snapshot) as CKRecordValue
            let update: (CKRecord) -> Void = { record in
                record["payload"] = payload
                record["checkedAt"] = snapshot.checkedAt as CKRecordValue
            }
            try await saveReplacing(recordID: recordID, database: database, update: update)
        } catch {
            // The App Group copy and StoreKit cache remain valid on this device.
        }
    }

    /// Fetch first, then save with the server change tag. A newly created
    /// record races safely with another device's first write by retrying once.
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

    private func fileURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier)?.appending(path: "HLLPurchaseStatus.json")
    }
}

public enum HLLPurchaseStoreError: Error, Sendable {
    case appGroupUnavailable
}
