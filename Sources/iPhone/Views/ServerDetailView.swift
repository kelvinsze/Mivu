import SwiftUI
import UIKit

/// Shows media libraries and video items inside a connected Emby / Jellyfin server.
public struct ServerDetailView: View {
    public let serverInfo: SavedServerInfo
    @ObservedObject var playerService = PlayerService.shared

    @State private var libraries: [MediaLibrary] = []
    @State private var selectedLibrary: MediaLibrary?
    @State private var itemsByLibrary: [String: [MediaItem]] = [:]
    @State private var searchText = ""
    @State private var searchResults: [MediaItem] = []
    @State private var isSearchLoading = false
    @State private var searchErrorMessage: String?
    @State private var searchRequestID: UUID?
    @State private var continueWatching: [MediaItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isLibraryError = false
    @State private var playbackResolveTask: Task<Void, Never>?
    @State private var playbackResolveID: UUID?
    @State private var initialLibraryApplied = false
    @State private var libraryLoadID: UUID?
    @State private var itemsLoadID: UUID?
    @State private var searchTask: Task<Void, Never>?
    @State private var libraryTask: Task<Void, Never>?
    @State private var itemsTask: Task<Void, Never>?
    @State private var continueTask: Task<Void, Never>?
    private let initialLibraryID: String?

    private let libraryColumns = [
        GridItem(.adaptive(minimum: 105, maximum: 140), spacing: 14)
    ]

    public init(serverInfo: SavedServerInfo, initialLibraryID: String? = nil) {
        self.serverInfo = serverInfo
        self.initialLibraryID = initialLibraryID
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                // 1. Library Filter Pills
                if !libraries.isEmpty {
                    libraryPicker
                }

                if libraries.isEmpty {
                    libraryLoadState
                }

                // 2. Continue Watching Horizontal Rail
                if !continueWatching.isEmpty {
                    posterRow(title: String(localized: "继续观看"), items: continueWatching, showsProgress: true)
                }

                // 3. Search Results or Selected Library Items
                if !searchText.isEmpty {
                    if !searchResults.isEmpty {
                        posterGrid(title: String(localized: "搜索结果"), items: searchResults)
                    } else if isSearchLoading {
                        ProgressView().tint(Color.mivuAccent).frame(maxWidth: .infinity).padding(.top, 48)
                    } else if let searchErrorMessage {
                        VStack(spacing: 12) {
                            ContentUnavailableView("搜索失败", systemImage: "exclamationmark.triangle", description: Text(verbatim: searchErrorMessage))
                            Button("重试") { search() }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.mivuAccent)
                        }
                        .padding(.top, 40)
                    } else {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 40)
                    }
                } else {
                    mediaLibrary
                }

                if searchText.isEmpty,
                   let error = errorMessage,
                   let selectedLibrary,
                   let items = itemsByLibrary[selectedLibrary.id],
                   !items.isEmpty {
                    HStack(spacing: 12) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Spacer()
                        if !isLibraryError {
                            Button("重试") { loadItems(for: selectedLibrary) }
                            .font(.footnote.weight(.semibold))
                        } else {
                            Button("重试") { loadLibraries() }
                                .font(.footnote.weight(.semibold))
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color.mivuBackground)
        .tint(Color.mivuAccent)
        .navigationTitle(serverInfo.name)
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            loadLibraries()
            loadContinueWatching()
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                search()
            }
        }
        .onDisappear {
            libraryTask?.cancel()
            itemsTask?.cancel()
            searchTask?.cancel()
            continueTask?.cancel()
            playbackResolveTask?.cancel()
            libraryLoadID = nil
            itemsLoadID = nil
            searchRequestID = nil
            isLoading = false
            isSearchLoading = false
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    loadLibraries(forceRefresh: true)
                    loadContinueWatching()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新媒体库")
            }
        }
        .searchable(text: $searchText, prompt: "搜索影视、剧集")
        .onChange(of: searchText) { _, _ in
            search()
        }
        .onSubmit(of: .search) {
            search()
        }
    }

    private var libraryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(libraries) { library in
                    Button {
                        selectedLibrary = library
                        loadItems(for: library)
                    } label: {
                        Label {
                            Text(verbatim: library.name)
                        } icon: {
                            Image(systemName: iconForCollection(library.collectionType))
                        }
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedLibrary?.id == library.id ? Color.mivuAccent : .secondary)
                    .buttonBorderShape(.capsule)
                }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var mediaLibrary: some View {
        if let selectedLibrary, isLoading && (itemsByLibrary[selectedLibrary.id]?.isEmpty ?? true) {
            HStack {
                Spacer()
                ProgressView()
                    .tint(Color.mivuAccent)
                    .padding(.top, 60)
                Spacer()
            }
        } else if let selectedLibrary {
            let items = itemsByLibrary[selectedLibrary.id] ?? []
            if !items.isEmpty {
                posterGrid(title: selectedLibrary.name, items: items)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        isLibraryError ? "媒体分类刷新失败" : "媒体内容加载失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(verbatim: errorMessage)
                    )
                    Button("重试") {
                        if isLibraryError {
                            loadLibraries()
                        } else {
                            loadItems(for: selectedLibrary)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.mivuAccent)
                }
                .padding(.top, 40)
            } else if !isLoading {
                ContentUnavailableView("暂无视频内容", systemImage: "film", description: Text("该分类媒体库下未检索到可播放的影视文件。"))
                    .padding(.top, 48)
            }
        }
    }

    @ViewBuilder
    private var libraryLoadState: some View {
        if isLoading {
            HStack { Spacer(); ProgressView().tint(Color.mivuAccent); Spacer() }
                .padding(.top, 60)
        } else if let errorMessage {
            VStack(spacing: 12) {
                ContentUnavailableView("媒体分类加载失败", systemImage: "exclamationmark.triangle", description: Text(verbatim: errorMessage))
                Button("重试") { loadLibraries() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.mivuAccent)
            }
            .padding(.top, 40)
        } else {
            ContentUnavailableView("暂无媒体分类", systemImage: "film", description: Text("此媒体源没有可浏览的媒体库。"))
                .padding(.top, 40)
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
                                        .clipShape(RoundedRectangle(cornerRadius: MivuRadius.m, style: .continuous))
                                        .contentShape(RoundedRectangle(cornerRadius: MivuRadius.m, style: .continuous))

                                    if showsProgress, let progress = progress(for: item) {
                                        ProgressView(value: progress)
                                            .progressViewStyle(LinearProgressViewStyle(tint: Color.mivuAccent))
                                            .scaleEffect(x: 1, y: 2, anchor: .center)
                                            .clipShape(RoundedRectangle(cornerRadius: 2))
                                            .padding(.horizontal, 8)
                                            .padding(.bottom, 6)
                                    }
                                }

                                Text(item.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2, reservesSpace: true)
                                    .frame(width: 125, alignment: .leading)

                                if showsProgress, let remaining = remainingTime(for: item) {
                                    Text(verbatim: String.localizedStringWithFormat(String(localized: "剩余 %@"), SOAPParser.formatUPnPTime(remaining)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 125, alignment: .leading)
                                }
                            }
                            .frame(width: 125, alignment: .leading)
                            .contentShape(Rectangle())
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
                                    .aspectRatio(2 / 3, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: MivuRadius.m, style: .continuous))
                                    .contentShape(RoundedRectangle(cornerRadius: MivuRadius.m, style: .continuous))

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
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2, reservesSpace: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(verbatim: title).font(.title3.bold()).padding(.horizontal)
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

    private func loadLibraries(forceRefresh: Bool = false) {
        guard let client = MediaServerManager.shared.getClient(for: serverInfo.id) else {
            errorMessage = String(localized: "无法连接此媒体源")
            isLibraryError = true
            isLoading = false
            return
        }
        libraryTask?.cancel()
        let requestID = UUID()
        libraryLoadID = requestID
        isLoading = true
        isLibraryError = false
        errorMessage = nil

        libraryTask = Task {
            do {
                let fetched = try await client.fetchLibraries()
                guard !Task.isCancelled, libraryLoadID == requestID else { return }
                libraries = fetched
                isLoading = false
                let previousID = selectedLibrary?.id
                let preferred: MediaLibrary? = {
                    if let previousID, let selected = fetched.first(where: { $0.id == previousID }) { return selected }
                    if !initialLibraryApplied, let initialLibraryID,
                       let initial = fetched.first(where: { $0.id == initialLibraryID }) { return initial }
                    return fetched.first
                }
                initialLibraryApplied = true
                selectedLibrary = preferred
                if let preferred, forceRefresh || previousID != preferred.id || itemsByLibrary[preferred.id] == nil {
                    loadItems(for: preferred)
                }
            } catch {
                guard !Task.isCancelled, libraryLoadID == requestID else { return }
                errorMessage = error.localizedDescription
                isLibraryError = true
                isLoading = false
            }
        }
    }

    private func loadContinueWatching() {
        guard let client = MediaServerManager.shared.getClient(for: serverInfo.id) else {
            continueWatching = []
            return
        }
        continueTask?.cancel()
        continueTask = Task {
            let result = try? await client.fetchContinueWatching(limit: 10)
            guard !Task.isCancelled else { return }
            continueWatching = result ?? []
        }
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        searchResults = []
        searchErrorMessage = nil
        guard !query.isEmpty, let client = MediaServerManager.shared.getClient(for: serverInfo.id) else {
            isSearchLoading = false
            searchRequestID = nil
            if !query.isEmpty {
                searchErrorMessage = String(localized: "无法连接此媒体源")
            }
            return
        }
        let requestID = UUID()
        searchRequestID = requestID
        isSearchLoading = true
        searchTask = Task {
            do {
                let items = try await client.search(query: query, limit: 30)
                guard !Task.isCancelled, searchRequestID == requestID,
                      query == searchText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                searchResults = items
                isSearchLoading = false
            } catch {
                guard !Task.isCancelled, searchRequestID == requestID,
                      query == searchText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                searchErrorMessage = error.localizedDescription
                isSearchLoading = false
            }
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
                    playerService.isShowingPlayer = true
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
        guard let client = MediaServerManager.shared.getClient(for: serverInfo.id) else {
            errorMessage = String(localized: "无法连接此媒体源")
            isLibraryError = false
            isLoading = false
            return
        }
        itemsTask?.cancel()
        let requestID = UUID()
        itemsLoadID = requestID
        isLoading = true
        isLibraryError = false
        errorMessage = nil

        itemsTask = Task {
            do {
                let items = try await client.fetchItems(libraryId: library.id, startIndex: 0, limit: 50)
                guard !Task.isCancelled, itemsLoadID == requestID, selectedLibrary?.id == library.id else { return }
                itemsByLibrary[library.id] = items
                isLoading = false
            } catch {
                guard !Task.isCancelled, itemsLoadID == requestID, selectedLibrary?.id == library.id else { return }
                errorMessage = error.localizedDescription
                isLoading = false
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
        Color(.tertiarySystemFill)
            .overlay {
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
            .contentShape(Rectangle())
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
