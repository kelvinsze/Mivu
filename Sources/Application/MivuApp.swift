import SwiftUI
import CarPlay
import OSLog

private let logger = Logger(subsystem: "com.kold.mivu", category: "MivuApp")

@main
struct MivuApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            #if MIVU_LITE
            MivuLiteTabView()
            #else
            MainTabView()
            #endif
        }
    }
}

/// Custom AppDelegate managing application lifecycle, scene routing (Phone vs CarPlay), and background services.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        logger.info("Mivu launching. Starting the local web upload service.")
        do {
            try UploadedVideoStore.applyBackupPreference()
        } catch {
            logger.error("Unable to apply uploaded video backup preference: \(error.localizedDescription)")
        }
        HTTPServer.shared.start(port: 7890)
        SSDPService.shared.start()

        #if MIVU_PRO
        SMBLocalHTTPProxy.shared.start()
        #endif

        return true
    }

    // Dynamic scene session configuration routing for CarPlay and Phone
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let sceneRole = connectingSceneSession.role
        let isCarPlayTemplateScene = sceneRole == .carTemplateApplication
            || sceneRole.rawValue == "CPTemplateApplicationSceneSessionRoleApplication"
        let isCarPlayWindowScene = sceneRole.rawValue == "UIWindowSceneSessionRoleCarPlay"

        logger.info("Connecting scene with role: \(sceneRole.rawValue, privacy: .public)")

        if isCarPlayTemplateScene {
            logger.info("Connecting CarPlay template scene configuration for role: \(sceneRole.rawValue, privacy: .public)")
            let config = UISceneConfiguration(name: "CarPlay Configuration", sessionRole: connectingSceneSession.role)
            config.sceneClass = CPTemplateApplicationScene.self
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        } else if isCarPlayWindowScene {
            logger.info("Connecting CarPlay window scene configuration for role: \(sceneRole.rawValue, privacy: .public)")
            let config = UISceneConfiguration(name: "CarPlay Window Configuration", sessionRole: sceneRole)
            config.sceneClass = UIWindowScene.self
            config.delegateClass = PhoneSceneDelegate.self
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
        #if MIVU_PRO
        SMBLocalHTTPProxy.shared.stop()
        #endif
    }
}
