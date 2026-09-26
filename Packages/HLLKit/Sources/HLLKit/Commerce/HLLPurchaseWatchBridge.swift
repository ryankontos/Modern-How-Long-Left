#if canImport(WatchConnectivity)
import Foundation
import WatchConnectivity

/// Sends the latest StoreKit-derived projection to the paired device.
///
/// WatchConnectivity is a delivery aid, never the purchase authority. The
/// receiver stores the projection as a cache and still asks StoreKit for the
/// current entitlement whenever it can.
public final class HLLPurchaseWatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let session: WCSession
    private let store: HLLPurchaseSnapshotStore
    private let lock = NSLock()
    private var pendingData: Data?

    public init(session: WCSession = .default, store: HLLPurchaseSnapshotStore) {
        self.session = session
        self.store = store
        super.init()
    }

    public func start() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    public func send(_ snapshot: HLLPurchaseSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        lock.lock()
        pendingData = data
        lock.unlock()
        flushIfPossible()
    }

    private func flushIfPossible() {
        guard session.activationState == .activated else { return }
        lock.lock()
        let data = pendingData
        pendingData = nil
        lock.unlock()
        guard let data else { return }
        do {
            try session.updateApplicationContext(["hll.purchase.snapshot": data])
        } catch {
            lock.lock()
            pendingData = data
            lock.unlock()
        }
    }

    public func session(_ session: WCSession,
                        activationDidCompleteWith activationState: WCSessionActivationState,
                        error: Error?) {
        guard error == nil, activationState == .activated else { return }
        flushIfPossible()
    }

    public func session(_ session: WCSession,
                        didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["hll.purchase.snapshot"] as? Data,
              let snapshot = try? JSONDecoder().decode(HLLPurchaseSnapshot.self, from: data) else {
            return
        }
        try? store.writeLocal(snapshot.replacing(source: .watchConnectivityCache))
    }

#if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
#endif
}
#endif
