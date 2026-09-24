import UIKit
import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.kold.mivu", category: "PhoneSceneDelegate")

/// iPhone scene delegate managing deep linking.
/// The SwiftUI WindowGroup owns the phone window.
public final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    private var carPlayWindow: UIWindow?

    public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if session.role.rawValue == "UIWindowSceneSessionRoleCarPlay",
           let windowScene = scene as? UIWindowScene {
            logger.info("Connecting CarPlay UIWindowScene window.")
            PlayerService.shared.isCarPlayConnected = true
            let window = UIWindow(windowScene: windowScene)
            #if MIVU_LITE
            window.rootViewController = UIHostingController(rootView: MivuLiteTabView(isCarPlayWindow: true))
            #else
            window.rootViewController = UIHostingController(rootView: MainTabView(isCarPlayWindow: true))
            #endif
            carPlayWindow = window
            window.makeKeyAndVisible()
        }

        // Handle URL on launch if opened via deep link
        if let url = connectionOptions.urlContexts.first?.url {
            handleIncomingURL(url)
        }
    }

    public func sceneDidDisconnect(_ scene: UIScene) {
        if scene.session.role.rawValue == "UIWindowSceneSessionRoleCarPlay" {
            logger.info("CarPlay UIWindowScene disconnected.")
            carPlayWindow = nil
            PlayerService.shared.isCarPlayConnected = false
        }
    }

    public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url {
            handleIncomingURL(url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        logger.info("Opening incoming URL: \(url.absoluteString)")
        if let item = URLSource.parseDeepLink(url: url) {
            Task { @MainActor in
                PlayerService.shared.loadAndPlay(item: item)
            }
        }
    }
}
