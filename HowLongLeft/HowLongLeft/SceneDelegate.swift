import CoreData
import EventKit
import SwiftUI
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var model: HLLAppModel?
    private var observers: [NSObjectProtocol] = []

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let model = HLLAppModel()
        self.model = model
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ContentView(model: model))
        self.window = window
        window.makeKeyAndVisible()
        model.start()

        // External edits, CloudKit imports, and clock changes invalidate the same pipeline.
        for name in [Notification.Name.EKEventStoreChanged,
                     .NSPersistentStoreRemoteChange,
                     UIApplication.significantTimeChangeNotification,
                     NSNotification.Name.NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak model] _ in
                    Task { @MainActor in model?.sourceChanged() }
                })
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) { model?.sourceChanged() }

    func sceneDidDisconnect(_ scene: UIScene) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        model = nil
        window = nil
    }
}
