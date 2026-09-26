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
        guard cloudContainerIdentifier?.isEmpty == false else { return }
        do {
            try await writeCloud(snapshot)
            try? removePendingCloudWrite()
        } catch {
            // A verified purchase must eventually reach the other device. Keep
            // just the newest failed projection; the coordinator retries it on
            // later launches without writing CloudKit on every normal refresh.
            try? writePendingCloudWrite(snapshot)
        }
    }

    /// Retries only when a previous CloudKit save failed. This keeps purchase
    /// propagation reliable while preserving the zero-write steady state.
    public func retryPendingCloudWrite() async {
        guard let pending = readPendingCloudWrite(),
              cloudContainerIdentifier?.isEmpty == false else { return }
        do {
            try await writeCloud(pending)
            try? removePendingCloudWrite()
        } catch {
            // Connectivity and account changes are transient. Leave the one
            // atomic outbox file in place for the next verified refresh.
        }
    }

    private func writeCloud(_ snapshot: HLLPurchaseSnapshot) async throws {
        guard let cloudContainerIdentifier, !cloudContainerIdentifier.isEmpty else { return }
        let database = CKContainer(identifier: cloudContainerIdentifier).privateCloudDatabase
        let recordID = CKRecord.ID(recordName: Self.recordName)
        let payload = try JSONEncoder().encode(snapshot) as CKRecordValue
        let update: (CKRecord) -> Void = { record in
            record["payload"] = payload
            record["checkedAt"] = snapshot.checkedAt as CKRecordValue
        }
        try await saveReplacing(recordID: recordID, database: database,
                                checkedAt: snapshot.checkedAt, update: update)
    }

    /// Fetch first, then save with the server change tag. A newly created
    /// record races safely with another device's first write by retrying once.
    private func saveReplacing(recordID: CKRecord.ID, database: CKDatabase,
                               checkedAt: Date,
                               update: (CKRecord) -> Void) async throws {
        do {
            let record = try await database.record(for: recordID)
            // A delayed watch or outbox retry must never overwrite a newer
            // StoreKit verification already uploaded by another device.
            if let serverDate = record["checkedAt"] as? Date, serverDate > checkedAt { return }
            update(record)
            do {
                _ = try await database.save(record)
            } catch let error as CKError where error.code == .serverRecordChanged {
                let latest = try await database.record(for: recordID)
                if let serverDate = latest["checkedAt"] as? Date, serverDate > checkedAt { return }
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
                if let serverDate = latest["checkedAt"] as? Date, serverDate > checkedAt { return }
                update(latest)
                _ = try await database.save(latest)
            }
        }
    }

    private func fileURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier)?.appending(path: "HLLPurchaseStatus.json")
    }

    private func pendingCloudWriteURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appending(path: "HLLPurchaseCloudOutbox.json")
    }

    private func readPendingCloudWrite() -> HLLPurchaseSnapshot? {
        guard let url = pendingCloudWriteURL(),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HLLPurchaseSnapshot.self, from: data)
    }

    private func writePendingCloudWrite(_ snapshot: HLLPurchaseSnapshot) throws {
        guard let url = pendingCloudWriteURL() else {
            throw HLLPurchaseStoreError.appGroupUnavailable
        }
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    private func removePendingCloudWrite() throws {
        guard let url = pendingCloudWriteURL(), FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}

public enum HLLPurchaseStoreError: Error, Sendable {
    case appGroupUnavailable
}
