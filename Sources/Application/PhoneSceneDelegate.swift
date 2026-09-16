import UIKit
import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.kold.mivu", category: "PhoneSceneDelegate")

/// iPhone scene delegate managing deep linking.
/// The SwiftUI WindowGroup owns the phone window.
public final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {

    public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Handle URL on launch if opened via deep link
        if let url = connectionOptions.urlContexts.first?.url {
            handleIncomingURL(url)
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
