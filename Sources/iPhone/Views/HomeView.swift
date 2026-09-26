import SwiftUI
import Combine

/// Home dashboard for Mivu.
/// Features a cinematic Hero Continue Watching card, quick media servers rail,
/// recently played posters, casting status pill, and floating mini player.
public struct HomeView: View {
    @ObservedObject private var playerService = PlayerService.shared
    @ObservedObject var history = PlaybackHistory.shared
    @ObservedObject var serverManager = MediaServerManager.shared
    @ObservedObject private var browseModel = MediaBrowseModel.shared

    @State private var clipboardURL: URL?
    @State private var errorMessage: String?
    @State private var isShowingErrorAlert = false
    @State private var playbackResolveTask: Task<Void, Never>?
    @State private var playbackResolveID: UUID?

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MivuSpacing.l) {
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

                    // MARK: - 3. Recently Added
                    recentlyAddedSection

                    // MARK: - 4. Media Categories
                    mediaCategoriesSection
                        .padding(.horizontal)

                    // MARK: - 5. Wi-Fi Uploaded Videos
                    WiFiUploadedVideosSection()
                        .padding(.horizontal)

                    // MARK: - 6. Recently Played Carousel (2:3 Posters)
                    if !history.items.isEmpty {
                        recentlyPlayedSection
                            .padding(.bottom, 60) // Extra padding for mini-player clearance
                    }
                }
                .padding(.top, 10)
            }
            .background(Color.mivuBackground)
            .navigationTitle("Mivu")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ServerSourcesManagementView()
                    } label: {
                        Image(systemName: "server.rack")
                            .foregroundStyle(Color.mivuAccent)
                    }
                    .accessibilityLabel("管理媒体源")
                }
            }
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
                Text(verbatim: errorMessage ?? String(localized: "发生未知错误"))
            }
            .onAppear {
                browseModel.loadIfNeeded(servers: serverManager.savedServers)
            }
            .onChange(of: serverManager.savedServers) { _, servers in
                browseModel.loadIfNeeded(servers: servers)
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
                            Text(verbatim: sourceLabel(item.sourceType))
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(MivuEdition.primaryTint.opacity(0.9))
                                .foregroundColor(.white)
                                .clipShape(Capsule())

                            Spacer()

                            // Circular Play Button
                            Image(systemName: "play.fill")
                                .font(.title3.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                                .foregroundColor(.white)
                        }

                        Text(item.title)
                            .font(.title3.bold())
                            .foregroundColor(.white)
                            .lineLimit(2, reservesSpace: true)

                        if let resume = item.resumePosition, let duration = item.duration, duration > 0 {
                            let remain = max(duration - resume, 0)
                            Text(verbatim: String.localizedStringWithFormat(String(localized: "剩余 %@ · 已看 %d%%"), SOAPParser.formatUPnPTime(remain), Int((resume / duration) * 100)))
                                .font(.caption.weight(.medium))
                                .foregroundColor(.white.opacity(0.85))

                            ProgressView(value: min(resume / duration, 1.0))
                                .progressViewStyle(LinearProgressViewStyle(tint: MivuEdition.primaryTint))
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
                .clipShape(RoundedRectangle(cornerRadius: MivuRadius.l, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var fallbackHeroBackdrop: some View {
        ZStack {
            Color.mivuSurfaceSecondary
            Image(systemName: "film")
                .font(.system(size: 50))
                .foregroundColor(.secondary.opacity(0.45))
        }
    }

    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !serverManager.savedServers.isEmpty {
                Text("最近添加")
                    .font(.title3.bold())
                    .padding(.horizontal)
                ForEach(serverManager.savedServers) { server in
                    recentlyAddedRow(server)
                }
            }
        }
    }

    @ViewBuilder
    private func recentlyAddedRow(_ server: SavedServerInfo) -> some View {
        let snapshot = browseModel.snapshots[server.id]
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "\(server.name) · \(server.serverType.rawValue.uppercased())")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if let snapshot, !snapshot.recentlyAdded.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(snapshot.recentlyAdded) { item in
                            NavigationLink(value: item) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Group {
                                        if let poster = item.posterUrl {
                                            AsyncItemArtwork(url: poster, headers: item.headers)
                                                .scaledToFill()
                                        } else {
                                            posterPlaceholder(item)
                                        }
                                    }
                                    .frame(width: 110, height: 165)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: MivuRadius.s, style: .continuous))
                                    Text(item.title)
                .font(.caption.bold())
                                        .foregroundStyle(.primary)
                                        .lineLimit(2, reservesSpace: true)
                                        .frame(width: 110, alignment: .leading)
                                }
                                .frame(width: 110, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            if let error = snapshot?.recentItemsError {
                HStack(spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Button("重试") { browseModel.refresh(server: server) }
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal)
            } else if snapshot?.isLoadingRecentlyAdded == true || snapshot == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载最近添加").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            } else if snapshot?.recentItemsLoaded == true && snapshot?.recentlyAdded.isEmpty == true {
                Text("暂无最近添加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
    }

    private var mediaCategoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("媒体分类")
                    .font(.title3.bold())
                Spacer()
                NavigationLink {
                    ServersView(wrapsInNavigationStack: false)
                } label: {
                    Text("浏览全部")
                        .font(.subheadline)
                        .foregroundStyle(Color.mivuAccent)
                }
            }

            if serverManager.savedServers.isEmpty {
                NavigationLink {
                    ServerSourcesManagementView()
                } label: {
                    Label("添加媒体源", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.mivuSurface, in: RoundedRectangle(cornerRadius: MivuRadius.m, style: .continuous))
                }
                .foregroundStyle(.primary)
            } else {
                ForEach(serverManager.savedServers) { server in
                    let snapshot = browseModel.snapshots[server.id]
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: "\(server.name) · \(server.serverType.rawValue.uppercased())")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if let snapshot, !snapshot.libraries.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(snapshot.libraries) { library in
                                        NavigationLink {
                                            ServerDetailView(serverInfo: server, initialLibraryID: library.id)
                                        } label: {
                                            Label {
                                                Text(verbatim: library.name)
                                            } icon: {
                                                Image(systemName: categoryIcon(library.collectionType))
                                            }
                                                .font(.subheadline.weight(.semibold))
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .background(Color.mivuSurface, in: RoundedRectangle(cornerRadius: MivuRadius.m, style: .continuous))
                                        }
                                        .foregroundStyle(.primary)
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            if let error = snapshot.libraryError {
                                HStack(spacing: 8) {
                                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Button("重试") { browseModel.refresh(server: server) }
                                        .font(.caption.weight(.semibold))
                                }
                            }
                        } else if snapshot?.isLoadingLibraries == true || snapshot == nil {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在加载媒体分类").font(.caption).foregroundStyle(.secondary)
                            }
                        } else if let error = snapshot?.libraryError {
                            HStack(spacing: 8) {
                                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Button("重试") { browseModel.refresh(server: server) }
                                    .font(.caption.weight(.semibold))
                            }
                        } else if snapshot?.librariesLoaded == true {
                            Text("此媒体源暂无媒体分类")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func categoryIcon(_ type: String?) -> String {
        switch type?.lowercased() {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        default: return "play.square.stack"
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
                        .foregroundColor(MivuEdition.primaryTint)
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
                                        .clipShape(RoundedRectangle(cornerRadius: MivuRadius.s, style: .continuous))
                                        .contentShape(RoundedRectangle(cornerRadius: MivuRadius.s, style: .continuous))
                                    } else {
                                        posterPlaceholder(item)
                                            .frame(width: 110, height: 165)
                                            .clipShape(RoundedRectangle(cornerRadius: MivuRadius.s, style: .continuous))
                                            .contentShape(RoundedRectangle(cornerRadius: MivuRadius.s, style: .continuous))
                                    }

                                    // Small bottom progress bar on poster
                                    if let resume = item.resumePosition, let dur = item.duration, dur > 0 {
                                        ProgressView(value: min(resume / dur, 1.0))
                                            .progressViewStyle(LinearProgressViewStyle(tint: MivuEdition.primaryTint))
                                            .scaleEffect(x: 1, y: 2, anchor: .center)
                                            .clipShape(RoundedRectangle(cornerRadius: 2))
                                            .padding(.horizontal, 6)
                                            .padding(.bottom, 4)
                                    }
                                }
                                Text(item.title)
                                    .font(.caption.bold())
                                    .foregroundColor(.primary)
                                    .lineLimit(2, reservesSpace: true)
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
            Color.mivuSurfaceSecondary
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
                .foregroundColor(MivuEdition.primaryTint)

            VStack(alignment: .leading, spacing: 2) {
                Text("剪贴板视频流已捕获")
                    .font(.caption.bold())
                    .foregroundColor(MivuEdition.primaryTint)
                Text(url.absoluteString)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(String(localized: "播放")) {
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
            .tint(MivuEdition.primaryTint)
            .controlSize(.small)
        }
        .padding(12)
        .background(MivuEdition.primaryTint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: MivuRadius.m, style: .continuous))
    }

    // MARK: - Helpers

    private func sourceLabel(_ source: MediaSourceType) -> String {
        switch source {
        case .personalMedia: return String(localized: "媒体库")
        case .photoLibrary: return String(localized: "相册视频")
        case .dlna: return "DLNA"
        case .directUrl: return String(localized: "网络流")
        case .testStream: return String(localized: "测试源")
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
                                .fill(MivuEdition.primaryTint.opacity(0.15))
                                .frame(width: 42, height: 42)

                            Image(systemName: "film.fill")
                                .font(.subheadline)
                                .foregroundColor(MivuEdition.primaryTint)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: playerService.session.currentItem?.title ?? String(localized: "正在播放"))
                                .font(.subheadline.bold())
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            Text("\(SOAPParser.formatUPnPTime(playerService.session.currentTime)) / \(SOAPParser.formatUPnPTime(playerService.session.duration))")
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开播放器：\(playerService.session.currentItem?.title ?? String(localized: "正在播放"))")

                Spacer()

                Button {
                    playerService.togglePlayPause()
                } label: {
                    Image(systemName: playerService.session.status == .playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(playerService.session.status == .playing ? "暂停播放" : "继续播放")

                Button {
                    playerService.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("停止播放")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: MivuRadius.l, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }
}
