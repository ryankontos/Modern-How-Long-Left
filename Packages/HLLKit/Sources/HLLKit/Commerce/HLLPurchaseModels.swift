import Foundation

/// A capability that can be enabled by one or more StoreKit products.
///
/// The event engine does not depend on these capabilities. Gating happens at
/// the boundary that renders or schedules a paid surface, which keeps the
/// normal app event path useful on every device.
public enum HLLPaidFeature: String, CaseIterable, Codable, Hashable, Sendable {
    case widgets
    case complications
    case liveActivities
    case notifications
}

/// StoreKit product kinds are metadata for UI and diagnostics. Entitlement
/// evaluation always comes from verified StoreKit transactions, so changing a
/// product from a lifetime purchase to a subscription only changes this map.
public enum HLLProductKind: String, Codable, Hashable, Sendable {
    case nonConsumable
    case autoRenewableSubscription
    case nonRenewingSubscription
}

/// Product-to-capability mapping. Product identifiers are deliberately
/// configuration data rather than being spread through views and extensions.
public struct HLLProductDefinition: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: HLLProductKind
    public let features: Set<HLLPaidFeature>

    public init(id: String, kind: HLLProductKind, features: Set<HLLPaidFeature>) {
        self.id = id
        self.kind = kind
        self.features = features
    }
}

/// The shipping catalog keeps the product IDs already used by the original
/// product while allowing the App Store setup to replace them later. The
/// widget product unlocks extension surfaces that share the same iPhone
/// extension entitlement; the complication product is watch-face specific.
public struct HLLPurchaseConfiguration: Sendable {
    public let products: [HLLProductDefinition]

    public init(products: [HLLProductDefinition]) {
        self.products = products
    }

    public var productIDs: Set<String> { Set(products.map(\.id)) }

    public func definition(for productID: String) -> HLLProductDefinition? {
        products.first { $0.id == productID }
    }

    public static let shipping = HLLPurchaseConfiguration(products: [
        HLLProductDefinition(
            id: "HLLWidget",
            kind: .nonConsumable,
            features: [.widgets, .liveActivities, .notifications]),
        HLLProductDefinition(
            id: "ComplicationIAPHLL",
            kind: .nonConsumable,
            features: [.complications])
    ])
}

public enum HLLPurchaseSnapshotSource: String, Codable, Hashable, Sendable {
    case storeKit
    case cloudKitCache
    case watchConnectivityCache
}

/// The effective state of one paid capability at a point in time.
public struct HLLFeatureEntitlement: Codable, Hashable, Sendable {
    public let feature: HLLPaidFeature
    public let isUnlocked: Bool
    public let productIDs: Set<String>
    public let expirationDate: Date?
    public let revocationDate: Date?

    public init(feature: HLLPaidFeature, isUnlocked: Bool, productIDs: Set<String> = [],
                expirationDate: Date? = nil, revocationDate: Date? = nil) {
        self.feature = feature
        self.isUnlocked = isUnlocked
        self.productIDs = productIDs
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
    }

    public func isActive(at date: Date = .now) -> Bool {
        isUnlocked && revocationDate == nil &&
            (expirationDate == nil || expirationDate! > date)
    }
}

/// A small, replaceable entitlement projection shared between app processes.
/// `source` describes how this copy was obtained; only `.storeKit` is a fresh
/// authority. Cached copies are bounded by the dates inside each entitlement.
public struct HLLPurchaseSnapshot: Codable, Hashable, Sendable {
    public let revision: UUID
    public let checkedAt: Date
    public let source: HLLPurchaseSnapshotSource
    public let features: [HLLPaidFeature: HLLFeatureEntitlement]

    public init(revision: UUID = UUID(), checkedAt: Date = .now,
                source: HLLPurchaseSnapshotSource = .storeKit,
                features: [HLLPaidFeature: HLLFeatureEntitlement]) {
        self.revision = revision
        self.checkedAt = checkedAt
        self.source = source
        self.features = features
    }

    public static func locked(configuration: HLLPurchaseConfiguration,
                              checkedAt: Date = .now,
                              source: HLLPurchaseSnapshotSource = .storeKit) -> Self {
        let values = Dictionary(uniqueKeysWithValues: HLLPaidFeature.allCases.map {
            ($0, HLLFeatureEntitlement(feature: $0, isUnlocked: false))
        })
        return Self(checkedAt: checkedAt, source: source, features: values)
    }

    public func entitlement(for feature: HLLPaidFeature) -> HLLFeatureEntitlement {
        features[feature] ?? HLLFeatureEntitlement(feature: feature, isUnlocked: false)
    }

    /// True when StoreKit (or a cached StoreKit projection) has seen at least
    /// one configured product. An empty StoreKit response can otherwise be
    /// indistinguishable from a temporarily unavailable App Store account.
    public var hasTransactionEvidence: Bool {
        features.values.contains { !$0.productIDs.isEmpty }
    }

    public func hasActiveEntitlement(at date: Date = .now) -> Bool {
        HLLPaidFeature.allCases.contains { isUnlocked($0, at: date) }
    }

    public func isUnlocked(_ feature: HLLPaidFeature, at date: Date = .now) -> Bool {
        entitlement(for: feature).isActive(at: date)
    }

    public func replacing(source: HLLPurchaseSnapshotSource) -> Self {
        Self(revision: revision, checkedAt: checkedAt, source: source, features: features)
    }
}

public enum HLLPurchaseError: LocalizedError, Sendable {
    case productUnavailable(String)
    case verificationFailed
    case pending
    case userCancelled

    public var errorDescription: String? {
        switch self {
        case .productUnavailable(let id): "The purchase is not available right now (\(id))."
        case .verificationFailed: "Apple could not verify this purchase."
        case .pending: "The purchase is waiting for approval."
        case .userCancelled: "The purchase was cancelled."
        }
    }
}
