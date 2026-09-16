import SwiftUI
import CarPlay
import OSLog

private let logger = Logger(subsystem: "com.kold.mivu", category: "MivuApp")

@main
struct MivuApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}

/// Custom AppDelegate managing application lifecycle, scene routing (Phone vs CarPlay), and background services.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        logger.info("Mivu launching. Initializing DLNA HTTP Server and SSDP Discovery...")

        // Start UPnP HTTP Server on port 7890
        HTTPServer.shared.start(port: 7890)
        SMBLocalHTTPProxy.shared.start()

        // Start SSDP Multicast discovery service on 239.255.255.250:1900
        SSDPService.shared.start()

        return true
    }

    // Dynamic scene session configuration routing for CarPlay and Phone
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let sceneRole = connectingSceneSession.role
        let isCarPlayScene = sceneRole == .carTemplateApplication
            || sceneRole.rawValue == "CPTemplateApplicationSceneSessionRoleApplication"

        logger.info("Connecting scene with role: \(sceneRole.rawValue, privacy: .public)")

        if isCarPlayScene {
            logger.info("Connecting CarPlay scene configuration for role: \(sceneRole.rawValue, privacy: .public)")
            let config = UISceneConfiguration(name: "CarPlay Configuration", sessionRole: connectingSceneSession.role)
            config.sceneClass = CPTemplateApplicationScene.self
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        } else {
            logger.info("Connecting Phone UIWindowScene configuration...")
            let config = UISceneConfiguration(name: "Phone Configuration", sessionRole: connectingSceneSession.role)
            config.delegateClass = PhoneSceneDelegate.self
            return config
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        logger.info("Mivu terminating. Stopping services...")
        SSDPService.shared.stop()
        HTTPServer.shared.stop()
        SMBLocalHTTPProxy.shared.stop()
    }
}
