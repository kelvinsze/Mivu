import SwiftUI
import Combine

/// Home dashboard for Mivu.
/// Features a cinematic Hero Continue Watching card, quick media servers rail,
/// recently played posters, casting status pill, and floating mini player.
public struct HomeView: View {
    @ObservedObject private var playerService = PlayerService.shared
    @ObservedObject var history = PlaybackHistory.shared
    @ObservedObject var serverManager = MediaServerManager.shared

    @State private var clipboardURL: URL?
    @State private var errorMessage: String?
    @State private var isShowingErrorAlert = false
    @State private var playbackResolveTask: Task<Void, Never>?
    @State private var playbackResolveID: UUID?

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    // MARK: - 1. Clipboard Detected Banner (Sleek Capsule)
                    if let detected = clipboardURL {
                        clipboardBanner(detected)
                            .padding(.horizontal)
                    }

                    // MARK: - 2. Hero: Continue Watching (正在看 / 继续观看)
                    if let continueItem = history.items.first {
                        heroContinueWatchingSection(continueItem)
                            .padding(.horizontal)
                    }

                    // MARK: - 3. Connected Media Sources Rail
                    mediaSourcesSection
                        .padding(.horizontal)

                    // MARK: - 4. Wi-Fi Uploaded Videos
                    WiFiUploadedVideosSection()
                        .padding(.horizontal)

                    // MARK: - 5. Recently Played Carousel (2:3 Posters)
                    if !history.items.isEmpty {
                        recentlyPlayedSection
                            .padding(.bottom, 60) // Extra padding for mini-player clearance
                    }
                }
                .padding(.top, 10)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Mivu")
            .safeAreaInset(edge: .bottom) {
                HomeMiniPlayerBar(
                    playerService: playerService
                )
            }
            .navigationDestination(for: MediaItem.self) { item in
                VideoDetailView(item: item)
            }
            .alert("播放错误", isPresented: $isShowingErrorAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "发生未知错误")
            }
        }
    }

    // MARK: - Subviews

    /// Hero Card showcasing the last played item with backdrop and resume progress
    private func heroContinueWatchingSection(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("继续观看")
                .font(.title3.bold())
                .foregroundColor(.primary)

            NavigationLink(value: item) {
                ZStack(alignment: .bottomLeading) {
                    // Backdrop Image or Gradient
                    if let poster = item.backdropUrl ?? item.posterUrl {
                        AsyncImage(url: poster) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            default:
                                fallbackHeroBackdrop
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 190)
                        .clipped()
                    } else {
                        fallbackHeroBackdrop
                            .frame(maxWidth: .infinity)
                            .frame(height: 190)
                    }

                    // Scrim Gradient
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.4), .black.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // Information Overlay
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(sourceLabel(item.sourceType))
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.85))
                                .foregroundColor(.white)
                                .clipShape(Capsule())

                            Spacer()

                            // Circular Play Button
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 38))
                                .foregroundColor(.white)
                                .shadow(radius: 4)
                        }

                        Text(item.title)
                            .font(.title3.bold())
                            .foregroundColor(.white)
                            .lineLimit(1)

                        if let resume = item.resumePosition, let duration = item.duration, duration > 0 {
                            let remain = max(duration - resume, 0)
                            Text("剩余 \(SOAPParser.formatUPnPTime(remain)) · 已看 \(Int((resume / duration) * 100))%")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.white.opacity(0.85))

                            ProgressView(value: min(resume / duration, 1.0))
                                .progressViewStyle(LinearProgressViewStyle(tint: .orange))
                                .scaleEffect(x: 1, y: 1.5, anchor: .center)
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        } else {
                            Text("点击即可从头播放")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
            }
            .buttonStyle(.plain)
        }
    }

    private var fallbackHeroBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [Color.orange.opacity(0.4), Color.purple.opacity(0.3), Color.black.opacity(0.9)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "film")
                .font(.system(size: 50))
                .foregroundColor(.white.opacity(0.15))
        }
    }

    /// Horizontal rail of connected servers (Emby / Jellyfin / SMB / WebDAV)
    private var mediaSourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("媒体库来源")
                    .font(.title3.bold())
                Spacer()
                NavigationLink {
                    ServersView()
                } label: {
                    Text("全部")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if serverManager.savedServers.isEmpty {
                        NavigationLink {
                            ServersView()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("添加个人媒体源")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.primary)
                                    Text("连接 Emby、Jellyfin、NAS")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    } else {
                        ForEach(serverManager.savedServers) { server in
                            NavigationLink {
                                ServerDetailView(serverInfo: server)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: iconForServer(server.serverType))
                                        .font(.title3)
                                        .foregroundColor(.orange)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.name)
                                            .font(.subheadline.bold())
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(server.serverType.rawValue.uppercased())
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
            }
        }
    }

    /// 2:3 vertical posters row for Recently Played
    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近播放")
                    .font(.title3.bold())
                Spacer()
                NavigationLink {
                    HistoryView()
                } label: {
                    Text("查看全部")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(history.items.prefix(8)) { item in
                        NavigationLink(value: item) {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .bottom) {
                                    if let poster = item.posterUrl {
                                        AsyncImage(url: poster) { phase in
                                            switch phase {
                                            case .success(let img):
                                                img.resizable().scaledToFill()
                                            default:
                                                posterPlaceholder(item)
                                            }
                                        }
                                        .frame(width: 110, height: 165)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    } else {
                                        posterPlaceholder(item)
                                            .frame(width: 110, height: 165)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }

                                    // Small bottom progress bar on poster
                                    if let resume = item.resumePosition, let dur = item.duration, dur > 0 {
                                        ProgressView(value: min(resume / dur, 1.0))
                                            .progressViewStyle(LinearProgressViewStyle(tint: .orange))
                                            .scaleEffect(x: 1, y: 2, anchor: .center)
                                            .clipShape(RoundedRectangle(cornerRadius: 2))
                                            .padding(.horizontal, 6)
                                            .padding(.bottom, 4)
                                    }
                                }
                                .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 3)

                                Text(item.title)
                                    .font(.caption.bold())
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .frame(width: 110, alignment: .leading)
                            }
                            .frame(width: 110, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func posterPlaceholder(_ item: MediaItem) -> some View {
        ZStack {
            Color(.secondarySystemBackground)
            VStack(spacing: 6) {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundColor(.secondary.opacity(0.6))
                Text(item.title)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func clipboardBanner(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.title3)
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("剪贴板视频流已捕获")
                    .font(.caption.bold())
                    .foregroundColor(.orange)
                Text(url.absoluteString)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("播放") {
                let item = MediaItem(
                    title: url.lastPathComponent.isEmpty ? "剪贴板视频" : url.lastPathComponent,
                    url: url,
                    sourceType: .directUrl,
                    originator: "Clipboard"
                )
                playerService.loadAndPlay(item: item)
                playerService.isShowingPlayer = true
                clipboardURL = nil
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func sourceLabel(_ source: MediaSourceType) -> String {
        switch source {
        case .personalMedia: return "媒体库"
        case .photoLibrary: return "相册视频"
        case .dlna: return "DLNA"
        case .directUrl: return "网络流"
        case .testStream: return "测试源"
        }
    }

    private func iconForServer(_ type: MediaServerType) -> String {
        switch type {
        case .emby: return "tv.fill"
        case .jellyfin, .fnos: return "play.square.stack.fill"
        case .webDAV: return "externaldrive.connected.to.line.below"
        case .smb: return "folder.badge.gearshape"
        }
    }

    private func checkClipboard() {
        clipboardURL = URLSource.detectPlayableURLInClipboard()
    }

    private func playMediaItem(_ item: MediaItem) {
        guard item.sourceType == .personalMedia,
              let serverID = item.serverID,
              let client = MediaServerManager.shared.getClient(for: serverID) else {
            playerService.loadAndPlay(item: item)
            playerService.isShowingPlayer = true
            return
        }

        playbackResolveTask?.cancel()
        let resolveID = UUID()
        playbackResolveID = resolveID
        playbackResolveTask = Task {
            do {
                let resolved = try await client.resolvePlaybackItem(item)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard playbackResolveID == resolveID else { return }
                    playbackResolveTask = nil
                    playbackResolveID = nil
                    playerService.loadAndPlay(item: resolved)
                    playerService.isShowingPlayer = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard playbackResolveID == resolveID else { return }
                    playbackResolveTask = nil
                    playbackResolveID = nil
                    errorMessage = error.localizedDescription
                    isShowingErrorAlert = true
                }
            }
        }
    }
}

/// Frosted Glass Mini Player at the bottom of Home
private struct HomeMiniPlayerBar: View {
    @ObservedObject var playerService: PlayerService

    var body: some View {
        if playerService.session.currentItem != nil {
            HStack(spacing: 12) {
                Button {
                    playerService.isShowingPlayer = true
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.orange.opacity(0.15))
                                .frame(width: 42, height: 42)

                            Image(systemName: "film.fill")
                                .font(.subheadline)
                                .foregroundColor(.orange)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(playerService.session.currentItem?.title ?? "正在播放")
                                .font(.subheadline.bold())
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            Text("\(SOAPParser.formatUPnPTime(playerService.session.currentTime)) / \(SOAPParser.formatUPnPTime(playerService.session.duration))")
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    playerService.togglePlayPause()
                } label: {
                    Image(systemName: playerService.session.status == .playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundColor(.primary)
                        .padding(6)
                }

                Button {
                    playerService.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                        .padding(6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }
}
