import Foundation
import CarPlay
import Combine
import OSLog

private let logger = Logger(subsystem: "com.kold.mivu", category: "CarPlaySceneDelegate")

/// CarPlay Application Scene Delegate managing automotive lifecycle, vehicle state, and interface controller.
@MainActor
public final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPSessionConfigurationDelegate, ObservableObject {
    public static var shared: CarPlaySceneDelegate?

    public var interfaceController: CPInterfaceController?
    public var rootTemplate: CPListTemplate?
    private var sessionConfiguration: CPSessionConfiguration?
    private var cancellables = Set<AnyCancellable>()
    private var shouldPresentIncomingPlayback = false

    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var isVideoPlaybackAvailable: Bool = false
    @Published public private(set) var isSystemVideoPlaybackAvailable: Bool = false

    private var isPresentingRootTemplate = false
    private var needsRootTemplateRefresh = false

    override public init() {
        super.init()
        CarPlaySceneDelegate.shared = self
    }

    // MARK: - CPTemplateApplicationSceneDelegate

    public func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        logger.info("CarPlay connected to vehicle multimedia unit.")
        self.interfaceController = interfaceController
        self.isConnected = true
        PlayerService.shared.isCarPlayConnected = true
        HTTPServer.shared.start(port: 7890)
        SSDPService.shared.start()
        PlayerService.shared.requireNativePlaybackForExternalPresentation(origin: "CarPlay.didConnect")
        if PlayerService.shared.session.currentItem != nil {
            PlayerService.shared.isShowingPlayer = true
        }

        // Build and present the root template directly
        presentRootTemplate(using: interfaceController)

        SSDPService.shared.recordPlaybackStage("CarPlay 车机连接就绪")
        self.sessionConfiguration = CPSessionConfiguration(delegate: self)
        updateVehicleCapabilities()
        refreshCarPlayUI()

        if PlayerService.shared.session.currentItem?.sourceType == .dlna {
            shouldPresentIncomingPlayback = true
        }

        setupObservers()
    }

    public func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        logger.info("CarPlay disconnected from vehicle.")
        SSDPService.shared.recordPlaybackStage("CarPlay 车机已断开")
        self.interfaceController = nil
        self.rootTemplate = nil
        self.sessionConfiguration = nil
        self.isConnected = false
        self.isSystemVideoPlaybackAvailable = false
        PlayerService.shared.isCarPlayConnected = false
        PlayerService.shared.setCarPlayVideoPlaybackAvailable(false)
        self.isPresentingRootTemplate = false
        self.needsRootTemplateRefresh = false
        self.shouldPresentIncomingPlayback = false
        cancellables.removeAll()
        PlayerService.shared.stop()
        SSDPService.shared.stop()
        // Keep the local HTTP service alive so Wi-Fi uploads remain available on the phone.
    }

    // MARK: - CPSessionConfigurationDelegate

    public func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration, limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        logger.info("CarPlay limited user interfaces changed: \(limitedUserInterfaces.rawValue)")
        updateVehicleCapabilities()
        refreshCarPlayUI()
    }

    // MARK: - Vehicle State Inspection

    private func updateVehicleCapabilities() {
        self.isSystemVideoPlaybackAvailable = CarPlayVideoPresentation.isSystemVideoPlaybackSupported(sessionConfiguration: sessionConfiguration)
        let isAvailable = CarPlayVideoPresentation.isVideoPlaybackSupported(sessionConfiguration: sessionConfiguration)
        self.isVideoPlaybackAvailable = isAvailable
        PlayerService.shared.setCarPlayVideoPlaybackAvailable(isAvailable)
    }

#if DEBUG
    public func refreshVideoPlaybackAvailabilityForTesting() {
        updateVehicleCapabilities()
        refreshCarPlayUI()
    }
#endif

    // MARK: - UI Updates

    private func presentRootTemplate(using interfaceController: CPInterfaceController) {
        let newSections = CarPlayTemplateBuilder.buildRootSections(interfaceController: interfaceController)
        let root = CPListTemplate(title: "Mivu", sections: newSections)
        self.rootTemplate = root
        self.isPresentingRootTemplate = true

        interfaceController.setRootTemplate(root, animated: false) { [weak self] success, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPresentingRootTemplate = false

                if success {
                    self.needsRootTemplateRefresh = false
                    logger.info("CarPlay root template presented successfully (\(newSections.count) sections).")
                } else {
                    logger.error("CarPlay root template presentation failed: \(error?.localizedDescription ?? "unknown error", privacy: .public)")
                }

                if self.needsRootTemplateRefresh {
                    self.needsRootTemplateRefresh = false
                    self.refreshCarPlayUI()
                }
            }
        }
    }

    public func refreshCarPlayUI() {
        guard let interfaceController = interfaceController else { return }

        // If currently in middle of setRootTemplate, queue refresh
        guard !isPresentingRootTemplate else {
            needsRootTemplateRefresh = true
            return
        }

        let newSections = CarPlayTemplateBuilder.buildRootSections(interfaceController: interfaceController)

        if let root = rootTemplate {
            root.updateSections(newSections)
            logger.info("Updated CarPlay root template sections (\(newSections.count) sections).")
        } else {
            presentRootTemplate(using: interfaceController)
        }

        presentPendingIncomingPlayback()
    }

    private func setupObservers() {
        cancellables.removeAll()

        // 1. Observe player session changes (status, currentItem)
        PlayerService.shared.$session
            .map { session in
                "\(session.currentItem?.id.uuidString ?? "none")|\(session.status.rawValue)"
            }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCarPlayUI()
            }
            .store(in: &cancellables)

        // 2. Observe playback history changes (continue watching / recent items)
        // 优化：播放进行中避免因 15 秒定时保存进度而高频刷新 CarPlay 模板树，防止打断车机系统播放器的空闲检测与控制条自隐计时器
        PlaybackHistory.shared.$items
            .map { items in items.map(\.id.uuidString).joined(separator: ",") }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard PlayerService.shared.session.status != .playing else { return }
                self?.refreshCarPlayUI()
            }
            .store(in: &cancellables)

        #if MIVU_PRO
        // 3. Observe personal media servers list changes
        MediaServerManager.shared.$savedServers
            .map { servers in servers.map(\.id.uuidString).joined(separator: ",") }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCarPlayUI()
            }
            .store(in: &cancellables)
        #endif
    }

    /// A DLNA sender does not select the CarPlay list item. Refresh the root
    /// list so the user can select its video-configured playback item; pushing
    /// Now Playing alone only exposes controls and never starts video
    /// presentation.
    public func presentIncomingPlayback() {
        shouldPresentIncomingPlayback = true
        guard interfaceController != nil else {
            SSDPService.shared.recordPlaybackStage("等待 CarPlay 连接")
            return
        }
        let capability = isVideoPlaybackAvailable ? "车机支持视频" : "车机未报告视频能力或当前策略受限"
        SSDPService.shared.recordPlaybackStage("已通知 CarPlay（\(capability)）")
        refreshCarPlayUI()
    }

    private func presentPendingIncomingPlayback() {
        guard shouldPresentIncomingPlayback, interfaceController != nil else { return }
        shouldPresentIncomingPlayback = false

        let capability = isVideoPlaybackAvailable ? "车机支持视频" : "车机未报告视频能力或当前策略受限"
        logger.info("Incoming cast is ready for CarPlay video selection.")
        SSDPService.shared.recordPlaybackStage("CarPlay 已显示可选视频条目（\(capability)）")
    }
}
