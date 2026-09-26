import SwiftUI
import CoreTransferable
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// Dedicated Home view for Mivu (Standard / Lite Edition).
/// Focuses purely on UPnP/DLNA casting reception, live endpoint status,
/// and casting tutorials.
public struct MivuReceiverHomeView: View {
    @ObservedObject private var playerService = PlayerService.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let isCarPlayWindow: Bool
    @State private var errorMessage: String?
    @State private var isShowingErrorAlert = false
    @State private var isShowingExternalCastHelp = false
    @State private var selectedPhotoVideo: PhotosPickerItem?
    @State private var isPreparingPhotoVideo = false
    @State private var isCastingGuideExpanded = true
    @AppStorage("mivu.receiver.didSuccessfullyPlay") private var didSuccessfullyPlay = false

    public init(isCarPlayWindow: Bool = false) {
        self.isCarPlayWindow = isCarPlayWindow
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MivuSpacing.l) {
                    if let current = pinnedPlaybackItem {
                        activePlaybackCard(current)
                            .padding(.horizontal)
                    }

                    if playerService.isCarPlayConnected {
                        receiverStatusCard
                            .padding(.horizontal)
                        if !isCarPlayWindow {
                            castingContentSection
                                .padding(.horizontal)
                        }
                    } else {
                        receiverStatusCard
                            .padding(.horizontal)
                        if !isCarPlayWindow {
                            castingGuideCard
                                .padding(.horizontal)
                        }
                    }

                    if let current = inactivePlaybackItem {
                        activePlaybackCard(current)
                            .padding(.horizontal)
                    }

                    if playerService.isCarPlayConnected && !isCarPlayWindow {
                        castingGuideCard
                        .padding(.horizontal)
                    }

                    if !isCarPlayWindow {
                        // MARK: - 5. Mivu Pro Upgrade Hint
                        mivuProPromoBanner
                            .padding(.horizontal)
                            .padding(.bottom, 30)
                    }
                }
                .padding(.top, MivuSpacing.xs)
            }
            .background(Color.mivuBackground)
            .navigationTitle("Mivu")
            .alert("播放错误", isPresented: $isShowingErrorAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(verbatim: errorMessage ?? String(localized: "无法解析或播放所选视频流"))
            }
            .sheet(isPresented: $isShowingExternalCastHelp) {
                externalCastHelpSheet
            }
            .onChange(of: selectedPhotoVideo) { _, selection in
                guard let selection else { return }
                Task {
                    await playPhotoVideo(selection)
                }
            }
            .onAppear {
                if didSuccessfullyPlay {
                    isCastingGuideExpanded = false
                } else if playerService.isCarPlayConnected && playerService.session.status == .playing {
                    didSuccessfullyPlay = true
                    isCastingGuideExpanded = false
                }
            }
            .onChange(of: playerService.session.status) { _, status in
                collapseGuideAfterFirstCarPlayPlayback(status: status)
            }
            .onChange(of: playerService.isCarPlayConnected) { _, isConnected in
                guard isConnected else { return }
                collapseGuideAfterFirstCarPlayPlayback(status: playerService.session.status)
            }
        }
    }

    // MARK: - 1. Receiver Status Card
    private var pinnedPlaybackItem: MediaItem? {
        guard let item = playerService.session.currentItem else { return nil }
        switch playerService.session.status {
        case .loading, .playing, .paused, .failed: return item
        case .idle, .stopped: return nil
        }
    }

    private var inactivePlaybackItem: MediaItem? {
        guard let item = playerService.session.currentItem else { return nil }
        return playerService.session.status == .idle || playerService.session.status == .stopped ? item : nil
    }

    private var receiverStatusSummary: some View {
        HStack(spacing: MivuSpacing.s) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.mivuAccent)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("投屏服务已就绪")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(UPnPDevice.shared.friendlyName)
                    .font(.caption)
                    .foregroundColor(Color.mivuAccent)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Circle()
                .fill(Color.mivuAccent)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, MivuSpacing.m)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .mivuSurface()
        .accessibilityElement(children: .combine)
    }

    // MARK: - 1. Live Receiver Status Card
    private var receiverStatusCard: some View {
        let isReceiverActive = playerService.isCarPlayConnected
        // Ribbon faces overlap, so their base tint must be opaque to hide the back edges.
        let statusTint: Color = isReceiverActive ? .mivuAccent : Color(uiColor: .systemGray)

        return VStack(spacing: MivuSpacing.s) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.12))
                    .frame(width: 56, height: 56)
                MivuConnectionMark(tint: statusTint)
                    .frame(width: 38, height: 38 * 525.2 / 779)
            }

            HStack(spacing: 6) {
                Text(verbatim: isReceiverActive ? String(localized: "投屏服务已就绪") : String(localized: "等待连接 CarPlay"))
                    .font(.headline)
                    .foregroundColor(.primary)
                Circle()
                    .fill(statusTint)
                    .frame(width: 8, height: 8)
            }

            if isReceiverActive {
                Text(UPnPDevice.shared.friendlyName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Color.mivuAccent)
            }

            Text(verbatim: isReceiverActive ? String(localized: "等待来自局域网设备的媒体投送") : String(localized: "连接 CarPlay 后自动开启投屏服务"))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(MivuSpacing.m)
        .mivuSurface()
    }

    private var castingContentSection: some View {
        VStack(alignment: .leading, spacing: MivuSpacing.m) {
            Label("选择投屏内容", systemImage: "rectangle.connected.to.line.below")
                .font(.title3.bold())

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: MivuSpacing.s), count: 3),
                spacing: MivuSpacing.s
            ) {
                localVideoSource
                photoVideoSource
                externalAppSource
            }
            .disabled(!playerService.isCarPlayConnected || isPreparingPhotoVideo)
        }
        .padding(MivuSpacing.m)
        .mivuSurface(radius: MivuRadius.xl)
    }

    private var localVideoSource: some View {
        NavigationLink {
            LocalVideoLibraryView()
        } label: {
            castingSourceCard(
                title: "本地视频",
                icon: "film.stack.fill"
            )
        }
        .buttonStyle(.plain)
    }

    private var photoVideoSource: some View {
        PhotosPicker(selection: $selectedPhotoVideo, matching: .videos) {
            castingSourceCard(
                title: isPreparingPhotoVideo ? "正在准备视频…" : "相册视频",
                icon: "photo.on.rectangle.angled"
            )
        }
        .buttonStyle(.plain)
        .disabled(!playerService.isCarPlayConnected || isPreparingPhotoVideo)
    }

    private var externalAppSource: some View {
        Button {
            isShowingExternalCastHelp = true
        } label: {
            castingSourceCard(
                title: "视频 App",
                icon: "play.fill"
            )
        }
        .buttonStyle(.plain)
    }

    private func castingSourceCard(
        title: LocalizedStringKey,
        icon: String
    ) -> some View {
        let isAvailable = playerService.isCarPlayConnected && !isPreparingPhotoVideo
        let iconTint: Color = isAvailable ? .mivuAccent : Color(uiColor: .systemGray)
        let contentOpacity = playerService.isCarPlayConnected ? 1.0 : 0.45

        return VStack(spacing: MivuSpacing.xs) {
            Image(systemName: icon)
                .symbolRenderingMode(.monochrome)
                .font(.title3.weight(.semibold))
                .foregroundStyle(iconTint)
                .frame(width: 36, height: 36)
                .background(Color.mivuSurface.opacity(contentOpacity), in: RoundedRectangle(cornerRadius: MivuRadius.m, style: .continuous))
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .opacity(contentOpacity)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MivuSpacing.xs)
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(Color.mivuSurfaceSecondary.opacity(contentOpacity), in: RoundedRectangle(cornerRadius: MivuRadius.l, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: MivuRadius.l, style: .continuous))
    }

    private func collapseGuideAfterFirstCarPlayPlayback(status: PlaybackStatus) {
        guard !didSuccessfullyPlay, playerService.isCarPlayConnected, status == .playing else { return }
        didSuccessfullyPlay = true
        withAnimation(.easeInOut(duration: 0.2)) {
            isCastingGuideExpanded = false
        }
    }

    // MARK: - 2. Active Playback Card
    private func activePlaybackCard(_ item: MediaItem) -> some View {
        let status = playerService.session.status
        let canTogglePlayback = status == .playing || status == .paused
        let statusTitle: String
        let statusColor: Color
        switch status {
        case .loading:
            statusTitle = String(localized: "正在缓冲")
            statusColor = .orange
        case .playing:
            statusTitle = String(localized: "播放中")
            statusColor = .green
        case .paused:
            statusTitle = String(localized: "已暂停")
            statusColor = .orange
        case .failed:
            statusTitle = String(localized: "播放失败")
            statusColor = .red
        case .stopped:
            statusTitle = String(localized: "已停止")
            statusColor = .secondary
        case .idle:
            statusTitle = String(localized: "未播放")
            statusColor = .secondary
        }
        let playbackControlTitle = status == .playing
            ? String(localized: "暂停")
            : (status == .paused ? String(localized: "继续") : statusTitle)
        let playbackControlIcon: String
        switch status {
        case .playing: playbackControlIcon = "pause.fill"
        case .paused: playbackControlIcon = "play.fill"
        case .loading: playbackControlIcon = "hourglass"
        case .failed: playbackControlIcon = "exclamationmark.triangle.fill"
        case .stopped: playbackControlIcon = "stop.fill"
        case .idle: playbackControlIcon = "play.circle"
        }

        return VStack(alignment: .leading, spacing: MivuSpacing.s) {
            HStack {
                Label("CarPlay 播放", systemImage: "car.play.fill")
                    .font(.caption.bold())
                    .foregroundColor(Color.mivuAccent)
                Spacer()
            Text(verbatim: statusTitle)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.15))
                    .foregroundColor(statusColor)
                    .cornerRadius(6)
            }

            Text(item.title)
                .font(.subheadline.bold())
                .lineLimit(2)
                .foregroundColor(.primary)

            HStack(spacing: MivuSpacing.s) {
                Button {
                    playerService.togglePlayPause()
                } label: {
                    Label {
                        Text(verbatim: playbackControlTitle)
                    } icon: {
                        Image(systemName: playbackControlIcon)
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill))
                    .cornerRadius(8)
                }
                .disabled(!canTogglePlayback)

                Button {
                    playerService.isShowingPlayer = true
                } label: {
                    Label("打开遥控器", systemImage: "switch.2")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    .background(Color.mivuAccent)
                        .foregroundColor(.mivuOnAccent)
                        .cornerRadius(8)
                }
            }
        }
        .padding(MivuSpacing.m)
        .mivuSurface()
    }

    // MARK: - 3. Casting Guide Card
    private var castingGuideCard: some View {
        VStack(alignment: .leading, spacing: MivuSpacing.s) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCastingGuideExpanded.toggle()
                }
            } label: {
                HStack {
                    Label(isCastingGuideExpanded ? "收起投屏帮助" : "投屏帮助", systemImage: isCastingGuideExpanded ? "chevron.up" : "questionmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isCastingGuideExpanded ? "已展开" : "已收起")

            if isCastingGuideExpanded {
                VStack(spacing: MivuSpacing.s) {
                    guideStepRow(
                        index: "1",
                        title: "连接 CarPlay",
                        detail: "连接后，Mivu 将自动开启投屏服务。"
                    )

                    guideStepRow(
                        index: "2",
                        title: "选择视频",
                        detail: "从本地视频列表、相册选择，或从支持的视频 App 投屏。"
                    )

                    guideStepRow(
                        index: "3",
                        title: "在 CarPlay 播放",
                        detail: "视频将在车机屏幕播放，并可通过 iPhone 控制。"
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(MivuSpacing.m)
        .mivuSurface()
    }

    private func guideStepRow(index: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: MivuSpacing.s) {
            ZStack {
                Circle()
                    .fill(Color.mivuAccent)
                    .frame(width: 22, height: 22)
                Text(verbatim: index)
                    .font(.caption2.bold())
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - 4. Mivu Pro Promo Banner
    private var mivuProPromoBanner: some View {
        VStack(alignment: .leading, spacing: MivuSpacing.s) {
            HStack {
                Image(systemName: "crown.fill")
                    .foregroundColor(MivuEdition.proIdentityTint)
                Text("敬请期待Mivu Pro")
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                Spacer()
                MivuProBadge()
            }

            Text("需要连接个人私有云或家庭影院？Mivu Pro 支持 Emby、Jellyfin、SMB、WebDAV 媒体库挂载，提供影院级海报墙与元数据刮削。")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineSpacing(2)
        }
        .padding(MivuSpacing.m)
        .mivuSurface()
    }

    private var externalCastHelpSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Self.supportedVideoApps) { app in
                        let isInstalled = UIApplication.shared.canOpenURL(app.url)

                        Button {
                            UIApplication.shared.open(app.url)
                        } label: {
                            HStack(spacing: MivuSpacing.s) {
                                Image(systemName: app.icon)
                                    .foregroundStyle(isInstalled ? Color.mivuAccent : .secondary)
                                    .frame(width: 28)

                                Text(app.name)

                                Spacer()

                                if isInstalled {
                                    Image(systemName: "arrow.up.right")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("未安装")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!isInstalled)
                    }
                } header: {
                    Text("支持投屏的视频 App")
                }
            }
            .navigationTitle("视频 App 投屏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isShowingExternalCastHelp = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private static let supportedVideoApps = [
        SupportedVideoApp(name: "Bilibili", scheme: "bilibili://", icon: "play.rectangle.fill"),
        SupportedVideoApp(name: "腾讯视频", scheme: "tenvideo2://", icon: "play.tv.fill"),
        SupportedVideoApp(name: "优酷", scheme: "youku://", icon: "play.square.fill"),
        SupportedVideoApp(name: "夸克", scheme: "quark://", icon: "play.circle.fill")
    ]

    private func playPhotoVideo(_ selection: PhotosPickerItem) async {
        isPreparingPhotoVideo = true
        defer {
            isPreparingPhotoVideo = false
            selectedPhotoVideo = nil
        }

        do {
            guard playerService.isCarPlayConnected else {
                throw PhotoLibraryVideoError.carPlayDisconnected
            }
            guard let selectedVideo = try await selection.loadTransferable(type: PhotoLibraryVideo.self) else {
                return
            }

            let item = MediaItem(
                title: selectedVideo.title,
                url: selectedVideo.url,
                sourceType: .photoLibrary,
                mimeType: selectedVideo.mimeType,
                originator: "Photo Library",
                fileName: selectedVideo.url.lastPathComponent
            )
            playerService.loadAndPlay(
                item: item,
                origin: "PhotoLibraryPicker",
                recordHistory: false,
                requiresNativePlayback: true
            )
            CarPlaySceneDelegate.shared?.presentIncomingPlayback()
        } catch {
            errorMessage = error.localizedDescription
            isShowingErrorAlert = true
        }
    }
}

private struct SupportedVideoApp: Identifiable {
    let name: String
    let scheme: String
    let icon: String

    var id: String { scheme }
    var url: URL { URL(string: scheme)! }
}

private struct PhotoLibraryVideo: Transferable {
    let url: URL
    let title: String
    let mimeType: String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let sourceURL = received.file
            let extensionName = sourceURL.pathExtension
            let destinationURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mivu-photo-video-\(UUID().uuidString)")
                .appendingPathExtension(extensionName)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let title = sourceURL.deletingPathExtension().lastPathComponent
            return PhotoLibraryVideo(
                url: destinationURL,
                title: title.isEmpty ? "相册视频" : title,
                mimeType: UTType(filenameExtension: extensionName)?.preferredMIMEType
            )
        }
    }
}

/// The four ribbon paths from docs/branding/Mivu-M.svg, shaded with the current status tint.
private struct MivuConnectionMark: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            var context = context
            context.scaleBy(x: size.width / 779, y: size.height / 525.2)
            context.translateBy(x: -236.6, y: -363.1)

            for surface in Self.surfaces {
                context.fill(surface.path, with: .color(tint))
                context.fill(
                    surface.path,
                    with: .linearGradient(
                        surface.shading,
                        startPoint: surface.start,
                        endPoint: surface.end
                    )
                )
            }
        }
        .accessibilityHidden(true)
    }

    private struct Surface {
        let path: Path
        let start: CGPoint
        let end: CGPoint
        let shading: Gradient
    }

    private static let legShading = Gradient(stops: [
        .init(color: .black.opacity(0.55), location: 0),
        .init(color: .black.opacity(0.12), location: 0.38),
        .init(color: .clear, location: 0.65),
        .init(color: .white.opacity(0.22), location: 1)
    ])

    private static let surfaces: [Surface] = [
        Surface(
            path: Path { path in
                path.move(to: CGPoint(x: 236.6, y: 474.6))
                path.addLine(to: CGPoint(x: 428.7, y: 474.6))
                path.addLine(to: CGPoint(x: 428.7, y: 791.7))
                path.addCurve(to: CGPoint(x: 332.6, y: 888.3), control1: CGPoint(x: 428.7, y: 845.1), control2: CGPoint(x: 385.7, y: 888.3))
                path.addCurve(to: CGPoint(x: 236.6, y: 791.7), control1: CGPoint(x: 279.6, y: 888.3), control2: CGPoint(x: 236.6, y: 845.1))
                path.closeSubpath()
            },
            start: CGPoint(x: 411.550, y: 579.993),
            end: CGPoint(x: 237.017, y: 836.329),
            shading: legShading
        ),
        Surface(
            path: Path { path in
                path.move(to: CGPoint(x: 824.3, y: 473.9))
                path.addLine(to: CGPoint(x: 1015.6, y: 473.9))
                path.addLine(to: CGPoint(x: 1015.6, y: 791.8))
                path.addCurve(to: CGPoint(x: 920, y: 888.3), control1: CGPoint(x: 1015.6, y: 845), control2: CGPoint(x: 972.8, y: 888.3))
                path.addCurve(to: CGPoint(x: 824.3, y: 791.8), control1: CGPoint(x: 867.1, y: 888.3), control2: CGPoint(x: 824.3, y: 845))
                path.closeSubpath()
            },
            start: CGPoint(x: 843.630, y: 571.690),
            end: CGPoint(x: 1010.785, y: 841.811),
            shading: legShading
        ),
        Surface(
            path: Path { path in
                path.move(to: CGPoint(x: 625.8, y: 553.2))
                path.addLine(to: CGPoint(x: 832.9, y: 387.3))
                path.addCurve(to: CGPoint(x: 904, y: 363.1), control1: CGPoint(x: 852.9, y: 371.2), control2: CGPoint(x: 877.6, y: 363.1))
                path.addCurve(to: CGPoint(x: 1015.6, y: 473.9), control1: CGPoint(x: 965.7, y: 363.1), control2: CGPoint(x: 1015.6, y: 406.6))
                path.addLine(to: CGPoint(x: 1015.6, y: 566))
                path.addCurve(to: CGPoint(x: 955.8, y: 508.7), control1: CGPoint(x: 1015.6, y: 533.1), control2: CGPoint(x: 988.8, y: 508.7))
                path.addCurve(to: CGPoint(x: 904.7, y: 529.6), control1: CGPoint(x: 938.1, y: 508.7), control2: CGPoint(x: 922.4, y: 515))
                path.addLine(to: CGPoint(x: 779.5, y: 633.5))
                path.addLine(to: CGPoint(x: 726, y: 676))
                path.addLine(to: CGPoint(x: 600, y: 570))
                path.closeSubpath()
            },
            start: CGPoint(x: 927.125, y: 359.401),
            end: CGPoint(x: 737.239, y: 633.121),
            shading: Gradient(stops: [
                .init(color: .white.opacity(0.25), location: 0),
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.32), location: 1)
            ])
        ),
        Surface(
            path: Path { path in
                path.move(to: CGPoint(x: 236.6, y: 565.5))
                path.addLine(to: CGPoint(x: 236.6, y: 474.6))
                path.addCurve(to: CGPoint(x: 347.6, y: 363.1), control1: CGPoint(x: 236.6, y: 409), control2: CGPoint(x: 286.1, y: 363.1))
                path.addCurve(to: CGPoint(x: 419.7, y: 385.5), control1: CGPoint(x: 374.3, y: 363.1), control2: CGPoint(x: 398.9, y: 371.4))
                path.addLine(to: CGPoint(x: 710.9, y: 622.3))
                path.addCurve(to: CGPoint(x: 779.5, y: 633.5), control1: CGPoint(x: 733.7, y: 640), control2: CGPoint(x: 759, y: 648.7))
                path.addLine(to: CGPoint(x: 685.2, y: 714.5))
                path.addCurve(to: CGPoint(x: 569.2, y: 717.7), control1: CGPoint(x: 649.6, y: 746.5), control2: CGPoint(x: 607.4, y: 747.5))
                path.addLine(to: CGPoint(x: 349.1, y: 531))
                path.addCurve(to: CGPoint(x: 297.3, y: 508.5), control1: CGPoint(x: 332.5, y: 517.6), control2: CGPoint(x: 317, y: 508.5))
                path.addCurve(to: CGPoint(x: 236.6, y: 565.5), control1: CGPoint(x: 265.1, y: 508.5), control2: CGPoint(x: 238.2, y: 532.6))
                path.closeSubpath()
            },
            start: CGPoint(x: 322.137, y: 354.249),
            end: CGPoint(x: 647.883, y: 739.036),
            shading: Gradient(stops: [
                .init(color: .white.opacity(0.3), location: 0),
                .init(color: .clear, location: 0.65),
                .init(color: .black.opacity(0.06), location: 1)
            ])
        )
    ]
}

private enum PhotoLibraryVideoError: LocalizedError {
    case carPlayDisconnected

    var errorDescription: String? {
        switch self {
        case .carPlayDisconnected:
            return String(localized: "请先连接 CarPlay，再选择视频。")
        }
    }
}
