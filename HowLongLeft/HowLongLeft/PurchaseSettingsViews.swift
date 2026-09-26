import HLLKit
import SwiftUI

/// StoreKit UI stays in the app target. HLLKit exposes verified purchase
/// snapshots and product metadata without depending on SwiftUI.
struct PurchaseSettingsView: View {
    let model: HLLAppModel

    var body: some View {
        List {
            Section("Feature access") {
                PurchaseFeatureRow(title: "Widgets", feature: .widgets,
                                   snapshot: model.purchaseSnapshot)
                PurchaseFeatureRow(title: "Apple Watch complications", feature: .complications,
                                   snapshot: model.purchaseSnapshot)
                PurchaseFeatureRow(title: "Live Activities", feature: .liveActivities,
                                   snapshot: model.purchaseSnapshot)
                PurchaseFeatureRow(title: "Notifications", feature: .notifications,
                                   snapshot: model.purchaseSnapshot)
            }
            Section("Available purchases") {
                if model.purchaseProducts.isEmpty {
                    Text("Products will appear when the App Store is available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.purchaseProducts) { product in
                        Button { model.purchase(productID: product.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(product.displayName)
                                    Spacer()
                                    Text(product.displayPrice).fontWeight(.semibold)
                                }
                                Text(product.description)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Restore Purchases", systemImage: "arrow.clockwise") {
                    model.restorePurchases()
                }
            }
            Section {
                Text("StoreKit is the source of truth. HLLKit mirrors verified status to the private iCloud database, the App Group, and the paired watch so extensions can stay current even when the app is not open.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Premium Access")
        .task { model.loadPurchaseProducts() }
        .alert("Purchase update failed", isPresented: Binding(
            get: { model.purchaseErrorMessage != nil },
            set: { if !$0 { model.purchaseErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.purchaseErrorMessage = nil }
        } message: {
            Text(model.purchaseErrorMessage ?? "")
        }
    }
}

private struct PurchaseFeatureRow: View {
    let title: String
    let feature: HLLPaidFeature
    let snapshot: HLLPurchaseSnapshot

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: snapshot.isUnlocked(feature) ? "checkmark.circle.fill" : "lock.circle")
                .foregroundStyle(snapshot.isUnlocked(feature) ? .green : .secondary)
        }
    }
}
