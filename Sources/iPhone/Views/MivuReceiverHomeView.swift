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
    private let isCarPlayWindow: Bool
    @State private var errorMessage: String?
    @State private var isShowingErrorAlert = false
    @State private var isShowingExternalCastHelp = false
    @State private var selectedPhotoVideo: PhotosPickerItem?
    @State private var isPreparingPhotoVideo = false

    public init(isCarPlayWindow: Bool = false) {
        self.isCarPlayWindow = isCarPlayWindow
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MivuSpacing.l) {
                    // MARK: - 1. Live Receiver Status Card
                    receiverStatusCard
                        .padding(.horizontal)

                    // MARK: - 2. Primary casting sources
                    castingContentSection
                        .padding(.horizontal)

                    // MARK: - 3. Active Casting Session (if playing)
                    if let current = playerService.session.currentItem {
                        activePlaybackCard(current)
                            .padding(.horizontal)
                    }

                    // MARK: - 4. Casting Tutorial Guide
                    castingGuideCard
                        .padding(.horizontal)

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
        }
    }

    // MARK: - 1. Receiver Status Card
    private var receiverStatusCard: some View {
        let isReceiverActive = playerService.isCarPlayConnected

        return VStack(spacing: MivuSpacing.s) {
            ZStack {
                Circle()
                    .fill(Color.mivuAccent.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundColor(Color.mivuAccent)
            }

            HStack(spacing: 6) {
                Text(verbatim: isReceiverActive ? String(localized: "投屏服务已就绪") : String(localized: "等待连接 CarPlay"))
                    .font(.headline)
                    .foregroundColor(.primary)
                Circle()
                    .fill(isReceiverActive ? Color.green : Color.secondary)
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

            GeometryReader { geometry in
                let cardWidth = (geometry.size.width - (MivuSpacing.s * 2)) / 3
                HStack(spacing: MivuSpacing.s) {
                    localVideoSource
                        .frame(width: cardWidth)
                    photoVideoSource
                        .frame(width: cardWidth)
                    externalAppSource
                        .frame(width: cardWidth)
                }
                .disabled(!playerService.isCarPlayConnected || isPreparingPhotoVideo)
                .opacity(playerService.isCarPlayConnected ? 1 : 0.45)
            }
            .frame(height: 136)
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
                icon: "photo.on.rectangle.angled",
                usesMulticolorSymbol: true
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
        icon: String,
        usesMulticolorSymbol: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: MivuSpacing.xs) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .symbolRenderingMode(usesMulticolorSymbol ? .multicolor : .monochrome)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.mivuAccent)
                    .frame(width: 44, height: 44)
                    .background(Color.mivuSurface, in: RoundedRectangle(cornerRadius: MivuRadius.m, style: .continuous))

                Spacer(minLength: MivuSpacing.xs)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, MivuSpacing.xs)
            }

            Spacer(minLength: MivuSpacing.xxs)

            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(MivuSpacing.xs)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .leading)
        .background(Color.mivuSurfaceSecondary, in: RoundedRectangle(cornerRadius: MivuRadius.l, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: MivuRadius.l, style: .continuous))
    }

    // MARK: - 2. Active Playback Card
    private func activePlaybackCard(_ item: MediaItem) -> some View {
        let isPlaying = playerService.session.status == .playing

        return VStack(alignment: .leading, spacing: MivuSpacing.s) {
            HStack {
                Label("正在 CarPlay 播放", systemImage: "car.play.fill")
                    .font(.caption.bold())
                    .foregroundColor(Color.mivuAccent)
                Spacer()
            Text(verbatim: isPlaying ? String(localized: "播放中") : String(localized: "已暂停"))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isPlaying ? Color.green.opacity(0.15) : Color.mivuSurfaceSecondary)
                    .foregroundColor(isPlaying ? .green : .orange)
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
                        Text(verbatim: isPlaying ? String(localized: "暂停") : String(localized: "继续"))
                    } icon: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill))
                    .cornerRadius(8)
                }

                Button {
                    playerService.isShowingPlayer = true
                } label: {
                    Label("打开遥控器", systemImage: "switch.2")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    .background(Color.mivuAccent)
                        .foregroundColor(.white)
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
            Label("如何在 CarPlay 投屏？", systemImage: "questionmark.circle.fill")
                .font(.headline)
                .foregroundColor(.primary)

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
                } footer: {
                    Text("请在 App 内打开分享或投屏菜单，并选择 Mivu 作为播放设备。")
                }

                Section {
                    Label("先连接 CarPlay", systemImage: "car.fill")
                    Label("在视频 App 中打开分享或投屏菜单", systemImage: "square.and.arrow.up")
                    Label("选择 Mivu 作为播放设备", systemImage: "rectangle.connected.to.line.below")
                } header: {
                    Text("从其他 App 投屏")
                } footer: {
                    Text("Mivu 会在 CarPlay 连接后自动作为局域网投屏设备出现。")
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

private enum PhotoLibraryVideoError: LocalizedError {
    case carPlayDisconnected

    var errorDescription: String? {
        switch self {
        case .carPlayDisconnected:
            return String(localized: "请先连接 CarPlay，再选择视频。")
        }
    }
}
