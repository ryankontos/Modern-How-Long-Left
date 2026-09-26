import CloudKit
import Foundation

/// Installs the silent-push subscriptions used by the replaceable projections.
///
/// NSPersistentCloudKitContainer manages its own mirroring subscription, but
/// the small projection records are written with direct CloudKit APIs. They
/// need their own subscriptions or a remote change may never wake an app that
/// has been closed for a long time. Installation is idempotent and always runs
/// off the launch-critical path.
public actor HLLCloudKitSubscriptionInstaller {
    public static let settingsSubscriptionID = "hll.settings.remote-change.v1"
    public static let purchaseSubscriptionID = "hll.purchase.remote-change.v1"

    private let database: CKDatabase

    public init(containerIdentifier: String) {
        database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    /// Returns false only when CloudKit could not be reached or rejected the
    /// operation. A later launch retries; no caller needs to block on it.
    @discardableResult
    public func install() async -> Bool {
        let definitions = [
            makeSubscription(recordType: HLLSharedSettingsProjectionStore.recordType,
                             id: Self.settingsSubscriptionID),
            makeSubscription(recordType: HLLPurchaseSnapshotStore.recordType,
                             id: Self.purchaseSubscriptionID)
        ]
        do {
            let existing = try await database.subscriptions(for: definitions.map(\.subscriptionID))
            let missing = definitions.filter { subscription in
                guard let result = existing[subscription.subscriptionID] else { return true }
                if case .success = result { return false }
                return true
            }
            guard !missing.isEmpty else { return true }
            let result = try await database.modifySubscriptions(saving: missing, deleting: [])
            return missing.allSatisfy { subscription in
                guard let saved = result.saveResults[subscription.subscriptionID] else { return false }
                if case .success = saved { return true }
                return false
            }
        } catch {
            return false
        }
    }

    private func makeSubscription(recordType: String, id: CKSubscription.ID) -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: id,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        return subscription
    }
}
