import SwiftUI
import CoreTransferable
import PhotosUI
import UniformTypeIdentifiers

/// Dedicated Home view for Mivu (Standard / Lite Edition).
/// Focuses purely on UPnP/DLNA casting reception, live endpoint status,
/// and casting tutorials.
public struct MivuReceiverHomeView: View {
    @ObservedObject private var playerService = PlayerService.shared
    @State private var serverIP: String = HTTPServer.shared.localIPAddress
    @State private var errorMessage: String?
    @State private var isShowingErrorAlert = false
    @State private var isEditingDeviceName = false
    @State private var selectedPhotoVideo: PhotosPickerItem?
    @State private var isPreparingPhotoVideo = false
    @AppStorage("mivu_custom_friendly_name") private var customFriendlyName: String = ""

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MivuSpacing.l) {
                    // MARK: - 1. Live Receiver Status Card (Hero)
                    receiverStatusCard
                        .padding(.horizontal)

                    photoVideoPickerCard
                        .padding(.horizontal)

                    // MARK: - 2. Wi-Fi Uploaded Videos
                    WiFiUploadedVideosSection()
                        .padding(.horizontal)

                    // MARK: - 3. Active Casting Session (if playing)
                    if let current = playerService.session.currentItem {
                        activePlaybackCard(current)
                            .padding(.horizontal)
                    }

                    // MARK: - 4. Casting Tutorial Guide
                    castingGuideCard
                        .padding(.horizontal)

                    // MARK: - 5. Mivu Pro Upgrade Hint
                    mivuProPromoBanner
                        .padding(.horizontal)
                        .padding(.bottom, 30)
                }
                .padding(.top, MivuSpacing.xs)
            }
            .background(Color.mivuBackground)
            .navigationTitle("Mivu 投屏")
            .onAppear {
                serverIP = HTTPServer.shared.localIPAddress
            }
            .alert("播放错误", isPresented: $isShowingErrorAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "无法解析或播放所选视频流")
            }
            .sheet(isPresented: $isEditingDeviceName) {
                deviceNameSheet
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

        return VStack(spacing: MivuSpacing.m) {
            HStack(alignment: .center, spacing: MivuSpacing.s) {
                ZStack {
                    Circle()
                        .fill(Color.mivuAccent.opacity(0.12))
                        .frame(width: 50, height: 50)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundColor(.mivuAccent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(isReceiverActive ? "投屏服务已就绪" : "等待连接 CarPlay")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Circle()
                            .fill(isReceiverActive ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                    }

                    Text(isReceiverActive ? "等待来自局域网设备的媒体投送" : "连接 CarPlay 后自动开启投屏服务")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    isEditingDeviceName = true
                } label: {
                    Image(systemName: "pencil.circle")
                        .font(.title3)
                        .foregroundColor(.mivuAccent)
                }
            }

            Divider()

            VStack(spacing: MivuSpacing.xs) {
                HStack {
                    Text("设备名称")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(UPnPDevice.shared.friendlyName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                }

                HStack {
                    Text(isReceiverActive ? "局域网 IP" : "局域网 IP（CarPlay 连接后可用）")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(isReceiverActive ? serverIP : "未启用")
                        .font(.subheadline.monospaced())
                        .foregroundColor(.primary)
                }

                HStack {
                    Text(isReceiverActive ? "HTTP 服务端口" : "HTTP 服务端口（CarPlay 连接后启用）")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(isReceiverActive ? "\(HTTPServer.shared.port)" : "未启用")
                        .font(.subheadline.monospaced())
                        .foregroundColor(.primary)
                }
            }
        }
        .padding(MivuSpacing.m)
        .mivuSurface()
    }

    private var photoVideoPickerCard: some View {
        VStack(alignment: .leading, spacing: MivuSpacing.s) {
            Label("播放相册视频", systemImage: "photo.on.rectangle.angled")
                .font(.headline)

            Text("从手机相册选择本地视频，将在 CarPlay 车机屏幕播放，手机作为遥控器使用。")
                .font(.caption)
                .foregroundStyle(.secondary)

            PhotosPicker(selection: $selectedPhotoVideo, matching: .videos) {
                Label(
                    isPreparingPhotoVideo ? "正在准备视频…" : "从相册选择视频",
                    systemImage: "play.rectangle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mivuAccent)
            .disabled(!playerService.isCarPlayConnected || isPreparingPhotoVideo)

            if !playerService.isCarPlayConnected {
                Text("请先连接 CarPlay，再选择视频。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(MivuSpacing.m)
        .mivuSurface()
    }

    // MARK: - 2. Active Playback Card
    private func activePlaybackCard(_ item: MediaItem) -> some View {
        let isPlaying = playerService.session.status == .playing

        return VStack(alignment: .leading, spacing: MivuSpacing.s) {
            HStack {
                Label("正在 CarPlay 播放", systemImage: "car.play.fill")
                    .font(.caption.bold())
                    .foregroundColor(.mivuAccent)
                Spacer()
                Text(isPlaying ? "播放中" : "已暂停")
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
                    Label(
                        isPlaying ? "暂停" : "继续",
                        systemImage: isPlaying ? "pause.fill" : "play.fill"
                    )
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
                    detail: "上传视频、从相册选择，或从支持的视频 App 投屏。"
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

    private func guideStepRow(index: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: MivuSpacing.s) {
            ZStack {
                Circle()
                    .fill(Color.mivuAccent)
                    .frame(width: 22, height: 22)
                Text(index)
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
                    .foregroundColor(.mivuAccent)
                Text("探索 Mivu Pro")
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                Spacer()
                Text("专业版")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.mivuSurfaceSecondary, in: RoundedRectangle(cornerRadius: MivuRadius.s, style: .continuous))
                    .foregroundColor(.secondary)
            }

            Text("需要连接个人私有云或家庭影院？Mivu Pro 支持 Emby、Jellyfin、SMB、WebDAV 媒体库挂载，提供影院级海报墙与元数据刮削。")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineSpacing(2)
        }
        .padding(MivuSpacing.m)
        .mivuSurface()
    }

    // MARK: - Device Name Sheet
    private var deviceNameSheet: some View {
        NavigationStack {
            Form {
                Section("修改投屏设备名称") {
                    TextField("输入设备显示名称", text: $customFriendlyName)
                }

                Section {
                    Text("修改后，在其他设备投屏时将显示此名称。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("设备名称")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isEditingDeviceName = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if !customFriendlyName.trimmingCharacters(in: .whitespaces).isEmpty {
                            UPnPDevice.shared.friendlyName = customFriendlyName
                        }
                        isEditingDeviceName = false
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.35)])
    }

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
            return "请先连接 CarPlay，再选择视频。"
        }
    }
}
