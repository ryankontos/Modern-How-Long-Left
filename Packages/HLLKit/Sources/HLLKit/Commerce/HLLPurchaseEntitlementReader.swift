import Foundation
import StoreKit

/// A short-lived entitlement reader for app extensions.
///
/// Extensions must not start the app's long-running transaction listener. They
/// read verified current entitlements with a small deadline, then fall back to
/// the local/App Group or private CloudKit projection. Expiration and
/// revocation dates are evaluated again at the point of use, so an old cache
/// cannot keep a time-limited entitlement alive.
public struct HLLPurchaseEntitlementReader: Sendable {
    private struct TransactionState: Sendable {
        var productID: String
        var isActive: Bool
        var expirationDate: Date?
        var revocationDate: Date?
    }

    private let configuration: HLLPurchaseConfiguration
    private let store: HLLPurchaseSnapshotStore

    public init(configuration: HLLPurchaseConfiguration = .shipping,
                store: HLLPurchaseSnapshotStore) {
        self.configuration = configuration
        self.store = store
    }

    public func read() async -> HLLPurchaseSnapshot {
        // CloudKit recovery and StoreKit evaluation run in parallel. The
        // extension uses the first StoreKit result and does not wait on CloudKit
        // when it already has an authoritative answer.
        let cloudTask = Task { await store.readCloud() }
        let fresh = await freshSnapshotWithinDeadline()
        if let fresh {
            try? store.writeLocal(fresh)
            cloudTask.cancel()
            return fresh
        }

        let cached = await cloudTask.value
        let local = store.readLocal()
        return [local, cached].compactMap { $0 }.max { $0.checkedAt < $1.checkedAt }
            ?? .locked(configuration: configuration, source: .cloudKitCache)
    }

    private func freshSnapshotWithinDeadline() async -> HLLPurchaseSnapshot? {
        await withTaskGroup(of: HLLPurchaseSnapshot?.self) { group in
            group.addTask { await readStoreKit() }
            group.addTask {
                try? await Task.sleep(for: .seconds(1.0))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func readStoreKit() async -> HLLPurchaseSnapshot? {
        var states: [String: TransactionState] = [:]
        for definition in configuration.products {
            if let result = await Transaction.latest(for: definition.id),
               case .verified(let transaction) = result {
                states[definition.id] = TransactionState(
                    productID: definition.id,
                    isActive: Self.isActive(transaction),
                    expirationDate: transaction.expirationDate,
                    revocationDate: transaction.revocationDate)
            }
        }
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  configuration.definition(for: transaction.productID) != nil else { continue }
            states[transaction.productID] = TransactionState(
                productID: transaction.productID,
                isActive: Self.isActive(transaction),
                expirationDate: transaction.expirationDate,
                revocationDate: transaction.revocationDate)
        }
        return makeSnapshot(states: states)
    }

    private func makeSnapshot(states: [String: TransactionState]) -> HLLPurchaseSnapshot {
        var entitlements: [HLLPaidFeature: HLLFeatureEntitlement] = [:]
        for feature in HLLPaidFeature.allCases {
            let matching = states.values.filter {
                configuration.definition(for: $0.productID)?.features.contains(feature) == true
            }
            let active = matching.filter(\.isActive)
            entitlements[feature] = HLLFeatureEntitlement(
                feature: feature,
                isUnlocked: !active.isEmpty,
                productIDs: Set(matching.map(\.productID)),
                expirationDate: active.compactMap(\.expirationDate).max(),
                revocationDate: active.isEmpty ? matching.compactMap(\.revocationDate).max() : nil)
        }
        return HLLPurchaseSnapshot(source: .storeKit, features: entitlements)
    }

    private static func isActive(_ transaction: Transaction, at date: Date = .now) -> Bool {
        transaction.revocationDate == nil &&
            (transaction.expirationDate == nil || transaction.expirationDate! > date)
    }
}
