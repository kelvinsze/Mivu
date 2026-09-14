import SwiftUI
import UIKit

/// Shows media libraries and video items inside a connected Emby / Jellyfin server.
public struct ServerDetailView: View {
    public let serverInfo: SavedServerInfo
    @ObservedObject var playerService = PlayerService.shared

    @State private var libraries: [MediaLibrary] = []
    @State private var selectedLibrary: MediaLibrary?
    @State private var libraryItems: [MediaItem] = []
    @State private var searchText = ""
    @State private var searchResults: [MediaItem] = []
    @State private var continueWatching: [MediaItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isShowingPlayer = false
    @State private var playbackResolveTask: Task<Void, Never>?
    @State private var playbackResolveID: UUID?

    private let libraryColumns = [
        GridItem(.adaptive(minimum: 105, maximum: 140), spacing: 14)
    ]

    public init(serverInfo: SavedServerInfo) {
        self.serverInfo = serverInfo
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                // 1. Library Filter Pills
                if !libraries.isEmpty {
                    libraryPicker
                }

                // 2. Continue Watching Horizontal Rail
                if !continueWatching.isEmpty {
                    posterRow(title: "继续观看", items: continueWatching, showsProgress: true)
                }

                // 3. Search Results or Selected Library Items
                if !searchText.isEmpty {
                    if !searchResults.isEmpty {
                        posterGrid(title: "搜索结果", items: searchResults)
                    } else if !isLoading {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 40)
                    }
                } else {
                    mediaLibrary
                }

                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
        .navigationTitle(serverInfo.name)
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            loadLibraries()
            loadContinueWatching()
        }
        .searchable(text: $searchText, prompt: "搜索影视、剧集")
        .fullScreenCover(isPresented: $isShowingPlayer) {
            PlayerView()
        }
    }

    private var libraryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(libraries) { library in
                    Button {
                        selectedLibrary = library
                        libraryItems = []
                        loadItems(for: library)
                    } label: {
                        Label(library.name, systemImage: iconForCollection(library.collectionType))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedLibrary?.id == library.id ? .orange : .secondary)
                    .buttonBorderShape(.capsule)
                }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var mediaLibrary: some View {
        if isLoading && libraryItems.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                    .tint(.orange)
                    .padding(.top, 60)
                Spacer()
            }
        } else if let selectedLibrary, !libraryItems.isEmpty {
            posterGrid(title: selectedLibrary.name, items: libraryItems)
        } else if !isLoading && selectedLibrary != nil {
            ContentUnavailableView("暂无视频内容", systemImage: "film", description: Text("该分类媒体库下未检索到可播放的影视文件。"))
                .padding(.top, 48)
        }
    }

    private func posterRow(title: String, items: [MediaItem], showsProgress: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink {
                            VideoDetailView(item: item)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .bottom) {
                                    PosterArtwork(item: item)
                                        .frame(width: 125, height: 187)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)

                                    if showsProgress, let progress = progress(for: item) {
                                        ProgressView(value: progress)
                                            .progressViewStyle(LinearProgressViewStyle(tint: .orange))
                                            .scaleEffect(x: 1, y: 2, anchor: .center)
                                            .clipShape(RoundedRectangle(cornerRadius: 2))
                                            .padding(.horizontal, 8)
                                            .padding(.bottom, 6)
                                    }
                                }

                                Text(item.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(width: 125, alignment: .leading)

                                if showsProgress, let remaining = remainingTime(for: item) {
                                    Text("剩余 \(SOAPParser.formatUPnPTime(remaining))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 125, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func posterGrid(title: String, items: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(title)
            LazyVGrid(columns: libraryColumns, spacing: 16) {
                ForEach(items) { item in
                    NavigationLink {
                        VideoDetailView(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack(alignment: .topTrailing) {
                                PosterArtwork(item: item)
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(2 / 3, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 3)

                                // Quality or container badge if available
                                if let hint = item.videoCodecHint ?? item.containerHint {
                                    Text(hint.uppercased())
                                        .font(.system(size: 8, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.black.opacity(0.75))
                                        .foregroundColor(.white)
                                        .cornerRadius(4)
                                        .padding(6)
                                }
                            }

                            Text(item.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2, reservesSpace: true)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.title3.bold()).padding(.horizontal)
    }

    private func progress(for item: MediaItem) -> Double? {
        guard let duration = item.duration, duration > 0,
              let position = item.resumePosition, position > 0 else { return nil }
        return min(position / duration, 1)
    }

    private func remainingTime(for item: MediaItem) -> TimeInterval? {
        guard let duration = item.duration, let position = item.resumePosition else { return nil }
        return max(duration - position, 0)
    }

    // MARK: - Networking

    private func loadLibraries() {
        guard let client = MediaServerManager.shared.getClient(for: serverInfo.id) else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let fetched = try await client.fetchLibraries()
                await MainActor.run {
                    self.libraries = fetched
                    self.isLoading = false
                    if let first = fetched.first {
                        self.selectedLibrary = first
                        loadItems(for: first)
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func loadContinueWatching() {
        guard let client = MediaServerManager.shared.getClient(for: serverInfo.id) else { return }
        Task {
            let items = (try? await client.fetchContinueWatching(limit: 10)) ?? []
            await MainActor.run { continueWatching = items }
        }
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let client = MediaServerManager.shared.getClient(for: serverInfo.id) else {
            searchResults = []
            return
        }
        Task {
            let items = (try? await client.search(query: query, limit: 30)) ?? []
            await MainActor.run { searchResults = items }
        }
    }

    private func play(_ item: MediaItem) {
        guard let client = MediaServerManager.shared.getClient(for: serverInfo.id) else { return }
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
                    errorMessage = nil
                    playerService.loadAndPlay(item: resolved)
                    isShowingPlayer = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                SSDPService.shared.recordPlaybackDebug("RESOLVE failed server=\(serverInfo.name) item=\(item.serverItemID ?? "unknown") error=\(error.localizedDescription)")
                await MainActor.run {
                    guard playbackResolveID == resolveID else { return }
                    playbackResolveTask = nil
                    playbackResolveID = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadItems(for library: MediaLibrary) {
        guard let client = MediaServerManager.shared.getClient(for: serverInfo.id) else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let items = try await client.fetchItems(libraryId: library.id, startIndex: 0, limit: 50)
                await MainActor.run {
                    self.libraryItems = items
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func iconForCollection(_ type: String?) -> String {
        switch type?.lowercased() {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        default: return "play.square.stack"
        }
    }
}

private struct PosterArtwork: View {
    let item: MediaItem
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .clipped()
        .task(id: item.posterUrl) {
            guard let url = item.posterUrl else { return }
            var request = URLRequest(url: url)
            item.headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let loaded = UIImage(data: data),
                  !Task.isCancelled else { return }
            image = loaded
        }
    }
}
