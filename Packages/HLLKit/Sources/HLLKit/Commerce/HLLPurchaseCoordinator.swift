import Foundation
import StoreKit

/// StoreKit 2 is the authority for paid capabilities on every device.
///
/// The coordinator deliberately has no UI concerns. Apps, widgets, and
/// complications can all ask the same actor for a feature snapshot, while
/// purchase screens only consume the small `HLLStoreProduct` value type.
public actor HLLPurchaseCoordinator {
    private struct TransactionState: Sendable {
        var productID: String
        var isActive: Bool
        var expirationDate: Date?
        var revocationDate: Date?
    }

    private let configuration: HLLPurchaseConfiguration
    private let snapshotStore: HLLPurchaseSnapshotStore
#if canImport(WatchConnectivity)
    private let watchBridge: HLLPurchaseWatchBridge?
#endif
    private var snapshot: HLLPurchaseSnapshot
    private var updatesTask: Task<Void, Never>?
    private var streams: [UUID: AsyncStream<HLLPurchaseSnapshot>.Continuation] = [:]

    #if canImport(WatchConnectivity)
    public init(
        configuration: HLLPurchaseConfiguration = .shipping,
        snapshotStore: HLLPurchaseSnapshotStore,
        watchBridge: HLLPurchaseWatchBridge? = nil
    ) {
        self.configuration = configuration
        self.snapshotStore = snapshotStore
        self.watchBridge = watchBridge
        self.snapshot = .locked(configuration: configuration)
    }
    #else
    public init(
        configuration: HLLPurchaseConfiguration = .shipping,
        snapshotStore: HLLPurchaseSnapshotStore
    ) {
        self.configuration = configuration
        self.snapshotStore = snapshotStore
        self.snapshot = .locked(configuration: configuration)
    }
    #endif

    /// Starts the transaction listener once per process and refreshes the
    /// current entitlements without blocking the caller's first frame.
    public func start() {
        guard updatesTask == nil else { return }
#if canImport(WatchConnectivity)
        watchBridge?.setReceiveHandler { [weak self] cached in
            Task { await self?.adoptCachedSnapshot(cached) }
        }
        watchBridge?.start()
#endif
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
        Task { [weak self] in
            await self?.loadCachedSnapshot()
            _ = await self?.refresh()
        }
    }

    public func currentSnapshot() -> HLLPurchaseSnapshot { snapshot }

    public func changes() -> AsyncStream<HLLPurchaseSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            streams[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStream(id) }
            }
        }
    }

    public func isUnlocked(_ feature: HLLPaidFeature, at date: Date = .now) -> Bool {
        snapshot.isUnlocked(feature, at: date)
    }

    /// Product metadata is fetched lazily so app launch never waits for the
    /// App Store. Results are returned in the configured product order.
    public func products() async throws -> [HLLStoreProduct] {
        let fetched = try await Product.products(for: Array(configuration.productIDs))
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        return configuration.products.compactMap { definition in
            guard let product = byID[definition.id] else { return nil }
            return HLLStoreProduct(id: product.id, kind: definition.kind,
                                   features: definition.features,
                                   displayName: product.displayName,
                                   description: product.description,
                                   displayPrice: product.displayPrice)
        }
    }

    public func purchase(productID: String) async throws -> HLLPurchaseSnapshot {
        guard configuration.definition(for: productID) != nil else {
            throw HLLPurchaseError.productUnavailable(productID)
        }
        let products = try await Product.products(for: [productID])
        guard let product = products.first else {
            throw HLLPurchaseError.productUnavailable(productID)
        }
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw HLLPurchaseError.verificationFailed
            }
            await transaction.finish()
            return await refresh()
        case .pending:
            throw HLLPurchaseError.pending
        case .userCancelled:
            throw HLLPurchaseError.userCancelled
        @unknown default:
            throw HLLPurchaseError.verificationFailed
        }
    }

    /// Explicit restore action. StoreKit handles the account prompt and
    /// re-delivers transactions through `Transaction.updates` as needed.
    public func restorePurchases() async throws -> HLLPurchaseSnapshot {
        try await AppStore.sync()
        return await refresh()
    }

    /// Re-evaluates both the latest transaction for every configured product
    /// and current entitlements. The latest transaction catches expiry and
    /// revocation; current entitlements catches active subscription upgrades.
    @discardableResult
    public func refresh() async -> HLLPurchaseSnapshot {
        let cached = await snapshotStore.readBest()
        var states: [String: TransactionState] = [:]
        for definition in configuration.products {
            if let result = await Transaction.latest(for: definition.id),
               case .verified(let transaction) = result {
                states[definition.id] = TransactionState(
                    productID: definition.id,
                    isActive: Self.isActive(transaction, at: .now),
                    expirationDate: transaction.expirationDate,
                    revocationDate: transaction.revocationDate)
            }
        }
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  configuration.definition(for: transaction.productID) != nil else { continue }
            states[transaction.productID] = TransactionState(
                productID: transaction.productID,
                isActive: Self.isActive(transaction, at: .now),
                expirationDate: transaction.expirationDate,
                revocationDate: transaction.revocationDate)
        }
        let next = makeSnapshot(states: states, checkedAt: .now)
        if !next.hasTransactionEvidence,
           let cached, cached.hasActiveEntitlement(at: .now) {
            // Do not replace a valid cached purchase with an empty result when
            // StoreKit is temporarily unable to see the App Store account.
            snapshot = cached
            for continuation in streams.values { continuation.yield(cached) }
            return cached
        }
        await publish(next)
        return next
    }

    private func loadCachedSnapshot() async {
        guard let cached = await snapshotStore.readBest(), cached.checkedAt > snapshot.checkedAt else { return }
        snapshot = cached
        for continuation in streams.values { continuation.yield(cached) }
    }

    private func adoptCachedSnapshot(_ cached: HLLPurchaseSnapshot) {
        guard cached.checkedAt > snapshot.checkedAt else { return }
        // StoreKit is authoritative whenever this process has already seen
        // transaction evidence. A newer cache may fill an offline gap, but it
        // must not briefly downgrade a known active purchase or resurrect a
        // product that StoreKit has just reported as revoked/expired.
        if snapshot.source == .storeKit {
            if snapshot.hasTransactionEvidence {
                let currentActive = HLLPaidFeature.allCases.filter {
                    snapshot.isUnlocked($0, at: .now)
                }
                guard snapshot.hasActiveEntitlement(at: .now),
                      currentActive.allSatisfy({ cached.isUnlocked($0, at: .now) }) else {
                    return
                }
            } else if snapshot.hasActiveEntitlement(at: .now)
                && !cached.hasActiveEntitlement(at: .now) {
                return
            }
        }
        snapshot = cached
        for continuation in streams.values { continuation.yield(cached) }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        // Even revoked transactions are finished after their state has been
        // observed; the next full refresh computes the complete feature map.
        if case .verified(let transaction) = result {
            await transaction.finish()
        }
        _ = await refresh()
    }

    private func makeSnapshot(states: [String: TransactionState], checkedAt: Date) -> HLLPurchaseSnapshot {
        var entitlements: [HLLPaidFeature: HLLFeatureEntitlement] = [:]
        for feature in HLLPaidFeature.allCases {
            let matching = states.values.filter {
                configuration.definition(for: $0.productID)?.features.contains(feature) == true
            }
            let active = matching.filter(\.isActive)
            let products = Set(matching.map(\.productID))
            let expiration = active.compactMap(\.expirationDate).max()
            let revocation = matching.compactMap(\.revocationDate).max()
            entitlements[feature] = HLLFeatureEntitlement(
                feature: feature,
                isUnlocked: !active.isEmpty,
                productIDs: products,
                expirationDate: expiration,
                revocationDate: active.isEmpty ? revocation : nil)
        }
        return HLLPurchaseSnapshot(checkedAt: checkedAt, source: .storeKit,
                                   features: entitlements)
    }

    private func publish(_ next: HLLPurchaseSnapshot) async {
        let changed = !snapshot.hasSameEntitlements(as: next)
        snapshot = next
        if changed {
            for continuation in streams.values { continuation.yield(next) }
            await snapshotStore.persist(next)
        } else {
            // Keep the verification time fresh for offline extension reads
            // without creating an identical CloudKit write every app launch.
            try? snapshotStore.writeLocal(next)
        }
#if canImport(WatchConnectivity)
        if changed { watchBridge?.send(next) }
#endif
    }

    private func removeStream(_ id: UUID) { streams[id] = nil }

    private static func isActive(_ transaction: Transaction, at date: Date) -> Bool {
        transaction.revocationDate == nil &&
            (transaction.expirationDate == nil || transaction.expirationDate! > date)
    }
}

public struct HLLStoreProduct: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: HLLProductKind
    public let features: Set<HLLPaidFeature>
    public let displayName: String
    public let description: String
    public let displayPrice: String

    public init(id: String, kind: HLLProductKind, features: Set<HLLPaidFeature>,
                displayName: String, description: String, displayPrice: String) {
        self.id = id
        self.kind = kind
        self.features = features
        self.displayName = displayName
        self.description = description
        self.displayPrice = displayPrice
    }
}
