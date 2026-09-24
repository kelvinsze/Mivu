import SwiftUI

/// Playback history and watchlist view.
public struct HistoryView: View {
    @ObservedObject var history = PlaybackHistory.shared
    @ObservedObject var playerService = PlayerService.shared
    @State private var searchText = ""
    @State private var isConfirmingClear = false
    @State private var playbackResolveTask: Task<Void, Never>?
    @State private var playbackResolveID: UUID?
    @State private var errorMessage: String?
    @State private var isShowingErrorAlert = false

    public init() {}

    private var filteredItems: [MediaItem] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return history.items
        }
        return history.items.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    public var body: some View {
        NavigationStack {
            Group {
                if history.items.isEmpty {
                    emptyStateView
                } else {
                    List {
                        ForEach(filteredItems) { item in
                            historyRow(item)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation {
                                            history.remove(item: item)
                                        }
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    #if MIVU_LITE
                    .scrollContentBackground(.hidden)
                    .background(Color.mivuBackground)
                    #endif
                    .searchable(text: $searchText, prompt: "搜索观看历史")
                }
            }
            .navigationTitle("播放历史")
            .toolbar {
                if !history.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            isConfirmingClear = true
                        } label: {
                            Text("清空")
                                .font(.subheadline)
                                .foregroundColor(.red.opacity(0.85))
                        }
                    }
                }
            }
            #if MIVU_PRO
            .navigationDestination(for: MediaItem.self) { item in
                VideoDetailView(item: item)
            }
            #endif
            .confirmationDialog("清空所有播放历史？", isPresented: $isConfirmingClear) {
                Button("清空历史", role: .destructive) {
                    withAnimation { history.clear() }
                }
            }
            .alert("播放错误", isPresented: $isShowingErrorAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "无法解析该媒体，请检查服务器连接")
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 56))
                .foregroundColor(.secondary.opacity(0.6))

            Text("暂无播放记录")
                .font(.title3.bold())
                .foregroundColor(.primary)

            Text("你在 iPhone 或 CarPlay 播放的视频将在此自动同步记录播放进度。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if MIVU_LITE
        .background(Color.mivuBackground)
        #endif
    }

    private func historyRow(_ item: MediaItem) -> some View {
        #if MIVU_PRO
        NavigationLink(value: item) {
            historyRowContent(item)
        }
        #else
        Button {
            playHistoryItem(item)
        } label: {
            historyRowContent(item)
        }
        .buttonStyle(.plain)
        #endif
    }

    @ViewBuilder
    private func historyRowContent(_ item: MediaItem) -> some View {
        HStack(spacing: MivuSpacing.s) {
                // Video thumbnail or placeholder
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemFill))
                        .frame(width: 100, height: 62)

                    if let poster = item.posterUrl {
                        AsyncImage(url: poster) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                fallbackIcon(for: item)
                            }
                        }
                        .frame(width: 100, height: 62)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: MivuRadius.s, style: .continuous))
                    } else {
                        fallbackIcon(for: item)
                    }

                    // Play icon overlay
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())

                    // Resume progress bar if available
                    if let resume = item.resumePosition, let dur = item.duration, dur > 0 {
                        VStack {
                            Spacer()
                            ProgressView(value: min(max(resume / dur, 0), 1.0))
                                .progressViewStyle(LinearProgressViewStyle(tint: MivuEdition.primaryTint))
                                .scaleEffect(x: 1, y: 1.5, anchor: .center)
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)
                    }
                }
                .frame(width: 100, height: 62)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                    .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        #if MIVU_PRO
                        sourceBadge(item.sourceType)
                        #endif

                        if let resume = item.resumePosition, resume > 0 {
                            Text("已看至 \(SOAPParser.formatUPnPTime(resume))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else if let dur = item.duration, dur > 0 {
                            Text("时长 \(SOAPParser.formatUPnPTime(dur))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    #if MIVU_PRO
                    Text(item.url.lastPathComponent)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1)
                    #endif
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(historyRowPadding)
            .background(historyRowBackground, in: RoundedRectangle(cornerRadius: MivuRadius.m, style: .continuous))
        }

    private func fallbackIcon(for item: MediaItem) -> some View {
        Image(systemName: item.sourceType == .personalMedia ? "film" : "antenna.radiowaves.left.and.right")
            .font(.title3)
            .foregroundColor(.secondary)
    }

    private func sourceBadge(_ source: MediaSourceType) -> some View {
        Text(badgeText(for: source))
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeBackground(for: source), in: RoundedRectangle(cornerRadius: MivuRadius.s, style: .continuous))
            .foregroundColor(badgeForeground(for: source))
    }

    private func badgeText(for source: MediaSourceType) -> String {
        switch source {
        case .personalMedia: return "媒体库"
        case .photoLibrary: return "相册视频"
        case .dlna: return "DLNA 投送"
        case .directUrl: return "网络流"
        case .testStream: return "测试源"
        }
    }

    private var historyRowPadding: CGFloat {
        #if MIVU_LITE
        return MivuSpacing.s
        #else
        return 10
        #endif
    }

    private var historyRowBackground: Color {
        #if MIVU_LITE
        return .mivuSurface
        #else
        return Color(.secondarySystemBackground)
        #endif
    }

    private func badgeBackground(for source: MediaSourceType) -> Color {
        #if MIVU_LITE
        return .mivuSurfaceSecondary
        #else
        return badgeColor(for: source).opacity(0.15)
        #endif
    }

    private func badgeForeground(for source: MediaSourceType) -> Color {
        #if MIVU_LITE
        return .secondary
        #else
        return badgeColor(for: source)
        #endif
    }

    private func badgeColor(for source: MediaSourceType) -> Color {
        switch source {
        case .personalMedia: return .orange
        case .photoLibrary: return .pink
        case .dlna: return .cyan
        case .directUrl: return .purple
        case .testStream: return .blue
        }
    }

    private func playHistoryItem(_ item: MediaItem) {
        #if !MIVU_PRO
        playerService.loadAndPlay(item: item)
        playerService.isShowingPlayer = true
        return
        #else
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
        #endif
    }
}
