import SwiftUI

struct MediaBrowseSnapshot {
    var server: SavedServerInfo
    var libraries: [MediaLibrary] = []
    var recentlyAdded: [MediaItem] = []
    var isLoadingLibraries = false
    var isLoadingRecentlyAdded = false
    var librariesLoaded = false
    var recentItemsLoaded = false
    var libraryError: String?
    var recentItemsError: String?
}

@MainActor
final class MediaBrowseModel: ObservableObject {
    static let shared = MediaBrowseModel()

    @Published private(set) var snapshots: [UUID: MediaBrowseSnapshot] = [:]
    private var requests: [UUID: UUID] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func loadIfNeeded(servers: [SavedServerInfo]) {
        removeMissingServers(servers)
        for server in servers {
            let snapshot = snapshots[server.id]
            if snapshot != nil, snapshot?.server != server {
                tasks[server.id]?.cancel()
                tasks[server.id] = nil
                requests[server.id] = nil
                startRefresh(server: server, client: nil)
                continue
            }
            let isUnfinished = (snapshot?.librariesLoaded != true && snapshot?.libraryError == nil)
                || (snapshot?.recentItemsLoaded != true && snapshot?.recentItemsError == nil)
            if tasks[server.id] != nil { continue }
            if snapshot == nil || snapshot?.server != server || isUnfinished {
                startRefresh(server: server, client: nil)
            }
        }
    }

    func refresh(servers: [SavedServerInfo], clients: [UUID: any MediaServerProtocol]? = nil, force: Bool = true) async {
        removeMissingServers(servers)
        var pending: [Task<Void, Never>] = []
        for server in servers {
            if !force, tasks[server.id] != nil { continue }
            if !force, let snapshot = snapshots[server.id], snapshot.server == server,
               snapshot.librariesLoaded, snapshot.recentItemsLoaded { continue }
            startRefresh(server: server, client: clients?[server.id])
            if let task = tasks[server.id] { pending.append(task) }
        }
        await withTaskGroup(of: Void.self) { group in
            for task in pending {
                group.addTask { await task.value }
            }
        }
    }

    private func removeMissingServers(_ servers: [SavedServerInfo]) {
        let serverIDs = Set(servers.map(\.id))
        for id in Array(snapshots.keys) where !serverIDs.contains(id) {
            tasks[id]?.cancel()
            tasks[id] = nil
            requests[id] = nil
            snapshots[id] = nil
        }
    }

    func refresh(server: SavedServerInfo, client suppliedClient: (any MediaServerProtocol)? = nil) {
        startRefresh(server: server, client: suppliedClient)
    }

    private func startRefresh(server: SavedServerInfo, client suppliedClient: (any MediaServerProtocol)?) {
        tasks[server.id]?.cancel()
        tasks[server.id] = nil
        let requestID = UUID()
        requests[server.id] = requestID

        var snapshot = snapshots[server.id] ?? MediaBrowseSnapshot(server: server)
        snapshot.server = server
        snapshot.isLoadingLibraries = true
        snapshot.isLoadingRecentlyAdded = true
        snapshot.libraryError = nil
        snapshot.recentItemsError = nil
        snapshots[server.id] = snapshot

        guard let client = suppliedClient ?? MediaServerManager.shared.getClient(for: server.id) else {
            update(server.id, requestID: requestID) {
                $0.isLoadingLibraries = false
                $0.isLoadingRecentlyAdded = false
                $0.libraryError = String(localized: "无法连接此媒体源")
                $0.recentItemsError = String(localized: "无法连接此媒体源")
            }
            return
        }

        tasks[server.id] = Task { [weak self] in
            do {
                let libraries = try await client.fetchLibraries()
                guard !Task.isCancelled else { return }
                self?.update(server.id, requestID: requestID) {
                    $0.libraries = libraries
                    $0.librariesLoaded = true
                    $0.isLoadingLibraries = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.update(server.id, requestID: requestID) {
                    $0.libraryError = error.localizedDescription
                    $0.isLoadingLibraries = false
                }
            }

            do {
                let items = try await client.fetchRecentlyAdded(limit: 12)
                guard !Task.isCancelled else { return }
                self?.update(server.id, requestID: requestID) {
                    $0.recentlyAdded = items
                    $0.recentItemsLoaded = true
                    $0.isLoadingRecentlyAdded = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.update(server.id, requestID: requestID) {
                    $0.recentItemsError = error.localizedDescription
                    $0.isLoadingRecentlyAdded = false
                }
            }

            guard !Task.isCancelled, self?.requests[server.id] == requestID else { return }
            self?.tasks[server.id] = nil
            self?.requests[server.id] = nil
        }
    }

    private func update(_ id: UUID, requestID: UUID, _ change: (inout MediaBrowseSnapshot) -> Void) {
        guard requests[id] == requestID, var snapshot = snapshots[id] else { return }
        change(&snapshot)
        snapshots[id] = snapshot
    }
}

/// Media browsing tab: server libraries are grouped by their source.
public struct ServersView: View {
    @ObservedObject private var serverManager = MediaServerManager.shared
    @ObservedObject private var browseModel = MediaBrowseModel.shared
    private let wrapsInNavigationStack: Bool

    public init(wrapsInNavigationStack: Bool = true) {
        self.wrapsInNavigationStack = wrapsInNavigationStack
    }

    public var body: some View {
        Group {
            if wrapsInNavigationStack {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    private var content: some View {
        List {
                if serverManager.savedServers.isEmpty {
                    ContentUnavailableView("尚未添加媒体源", systemImage: "rectangle.stack", description: Text("添加 Emby、Jellyfin 或网络共享后，媒体分类会显示在这里。"))
                    NavigationLink {
                        ServerSourcesManagementView()
                    } label: {
                        Label("管理媒体源", systemImage: "plus.circle")
                    }
                } else {
                    ForEach(serverManager.savedServers) { server in
                        let snapshot = browseModel.snapshots[server.id]
                        Section {
                            if let snapshot, !snapshot.libraries.isEmpty {
                                ForEach(snapshot.libraries) { library in
                                    NavigationLink {
                                        ServerDetailView(serverInfo: server, initialLibraryID: library.id)
                                    } label: {
                                        Label {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(verbatim: library.name)
                                                Text(verbatim: "\(server.name) · \(server.serverType.rawValue.uppercased())")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        } icon: {
                                            Image(systemName: browseIcon(for: library.collectionType))
                                                .foregroundStyle(Color.mivuAccent)
                                        }
                                    }
                                }
                                if let error = snapshot.libraryError {
                                    browseError(error, server: server)
                                }
                            } else if let snapshot, snapshot.isLoadingLibraries {
                                Label("正在加载媒体分类", systemImage: "hourglass")
                                    .foregroundStyle(.secondary)
                            } else if let snapshot, let error = snapshot.libraryError {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label(error, systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.secondary)
                                    retryButton(server)
                                }
                            } else if let snapshot, snapshot.librariesLoaded {
                                Label("此媒体源暂无媒体分类", systemImage: "film")
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("加载媒体分类") { browseModel.refresh(server: server) }
                            }
                        } header: {
                            Text(verbatim: "\(server.name) · \(server.serverType.rawValue.uppercased())")
                        }
                    }
                    Section {
                        NavigationLink {
                            ServerSourcesManagementView()
                        } label: {
                            Label("管理媒体源", systemImage: "server.rack")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.mivuBackground)
            .navigationTitle("资源库")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ServerSourcesManagementView()
                    } label: {
                        Image(systemName: "server.rack")
                            .foregroundStyle(Color.mivuAccent)
                    }
                    .accessibilityLabel("管理媒体源")
                }
            }
            .refreshable {
                await browseModel.refresh(servers: serverManager.savedServers, force: true)
            }
            .onAppear {
                browseModel.loadIfNeeded(servers: serverManager.savedServers)
            }
            .onChange(of: serverManager.savedServers) { _, servers in
                browseModel.loadIfNeeded(servers: servers)
            }
    }

    @ViewBuilder
    private func browseError(_ error: String, server: SavedServerInfo) -> some View {
        HStack {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            retryButton(server)
        }
    }

    private func retryButton(_ server: SavedServerInfo) -> some View {
        Button("重试") { browseModel.refresh(server: server) }
            .font(.caption.weight(.semibold))
    }

    private func browseIcon(for type: String?) -> String {
        switch type?.lowercased() {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        default: return "play.square.stack"
        }
    }
}

/// Full server connection management screen.
public struct ServerSourcesManagementView: View {
    @ObservedObject var serverManager = MediaServerManager.shared
    @State private var isShowingAddServerSheet = false
    @State private var isShowingAddMenu = false
    @State private var selectedServiceForAdd: ServiceMenuOption = .jellyfin

    public init() {}

    public var body: some View {
        Group {
            List {
                if serverManager.savedServers.isEmpty {
                    Section {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(MivuEdition.primaryTint.opacity(0.12))
                                    .frame(width: 80, height: 80)
                                Image(systemName: "server.rack")
                                    .font(.system(size: 38))
                                    .foregroundColor(MivuEdition.primaryTint)
                            }
                            .padding(.top, 20)

                            Text("尚未连接媒体服务器")
                                .font(.title3.bold())

                            Text("支持连接 Emby、Jellyfin、WebDAV、SMB 局域网共享及飞牛私有云，畅享高清视频串流。")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)

                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    isShowingAddMenu.toggle()
                                }
                            } label: {
                                Label("添加服务", systemImage: "plus.circle.fill")
                                    .font(.subheadline.bold())
                                    .padding(.horizontal, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MivuEdition.primaryTint)
                            .padding(.bottom, 20)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    Section("已连接的服务器") {
                        ForEach(serverManager.savedServers) { server in
                            let brand = ServiceMenuOption.detect(name: server.name, type: server.serverType)
                            NavigationLink {
                                ServerDetailView(serverInfo: server)
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color(white: 0.15).opacity(0.08))
                                            .frame(width: 44, height: 44)
                                        ServiceBrandIconView(service: brand)
                                            .frame(width: 28, height: 28)
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(verbatim: server.name)
                                                .font(.headline)
                                                .foregroundColor(.primary)

                                            Text(verbatim: brand.title)
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                        }

                                        Text(verbatim: server.url.absoluteString)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let id = serverManager.savedServers[index].id
                                serverManager.removeServer(id: id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("管理媒体源")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            isShowingAddMenu.toggle()
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(isShowingAddMenu ? .white : MivuEdition.primaryTint)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(isShowingAddMenu ? MivuEdition.primaryTint : MivuEdition.primaryTint.opacity(0.12))
                            )
                    }
                }
            }
            .sheet(isPresented: $isShowingAddServerSheet) {
                AddServerView(initialService: selectedServiceForAdd)
            }
        }
        .overlay {
            if isShowingAddMenu {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.38)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                isShowingAddMenu = false
                            }
                        }

                    AddServiceDropdownMenuView { service in
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                            isShowingAddMenu = false
                        }
                        selectedServiceForAdd = service
                        isShowingAddServerSheet = true
                    }
                    .padding(.top, 54)
                    .padding(.trailing, 16)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.86, anchor: .topTrailing).combined(with: .opacity),
                            removal: .scale(scale: 0.88, anchor: .topTrailing).combined(with: .opacity)
                        )
                    )
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isShowingAddMenu)
    }
}

// MARK: - Add Server Sheet

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedService: ServiceMenuOption
    @State private var serverName: String
    @State private var serverUrlStr: String
    @State private var serverType: MediaServerType
    @State private var username = ""
    @State private var password = ""
    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    init(initialService: ServiceMenuOption = .jellyfin) {
        _selectedService = State(initialValue: initialService)
        _serverType = State(initialValue: initialService.targetServerType)
        _serverName = State(initialValue: initialService.defaultServerName)
        _serverUrlStr = State(initialValue: initialService.defaultURLPlaceholder)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(white: 0.15).opacity(0.1))
                                .frame(width: 48, height: 48)
                            ServiceBrandIconView(service: selectedService)
                                .frame(width: 32, height: 32)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: selectedService.title)
                                .font(.headline.bold())
                            Text(verbatim: selectedService.category.title)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Picker("", selection: $selectedService) {
                            ForEach(ServiceMenuOption.allCases) { opt in
                                Text(verbatim: opt.title).tag(opt)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .padding(.vertical, 4)

                    if let hint = selectedService.guidanceHint {
                        Text(verbatim: hint)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section("连接信息") {
                    TextField(
                        String.localizedStringWithFormat(String(localized: "服务器名称（例如 %@）"), selectedService.defaultServerName),
                        text: $serverName
                    )

                    TextField(selectedService.defaultURLPlaceholder, text: $serverUrlStr)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }

                Section("身份凭据") {
                    TextField("用户名", text: $username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    SecureField("密码 / 访问令牌", text: $password)
                }

                if let error = errorMessage {
                    Section {
                        Text(verbatim: error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button {
                        authenticateAndSave()
                    } label: {
                        HStack {
                            Spacer()
                            if isAuthenticating {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text("连接并保存")
                                .bold()
                            Spacer()
                        }
                    }
                    .disabled(isAuthenticating || serverUrlStr.isEmpty)
                    .tint(MivuEdition.primaryTint)
                }
            }
            .onChange(of: selectedService) { _, newService in
                serverType = newService.targetServerType
                if serverName.isEmpty || ServiceMenuOption.allCases.contains(where: { $0.defaultServerName == serverName }) {
                    serverName = newService.defaultServerName
                }
                if serverUrlStr.isEmpty || ServiceMenuOption.allCases.contains(where: { $0.defaultURLPlaceholder == serverUrlStr }) {
                    serverUrlStr = newService.defaultURLPlaceholder
                }
            }
            .navigationTitle(String.localizedStringWithFormat(String(localized: "添加 %@"), selectedService.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func authenticateAndSave() {
        guard let url = serverType.normalize(urlString: serverUrlStr) else {
            errorMessage = "输入的服务器地址不合法"
            return
        }
        var normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var inputPassword = password

        // If user embedded credentials in URL, extract them
        if normalizedUsername.isEmpty, let user = url.user, !user.isEmpty {
            normalizedUsername = user
        }
        if inputPassword.isEmpty, let pass = url.password, !pass.isEmpty {
            inputPassword = pass
        }

        // Clean user/pass from URL so we don't store plain credentials in url
        var cleanURL = url
        if url.user != nil || url.password != nil {
            var comp = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comp?.user = nil
            comp?.password = nil
            cleanURL = comp?.url ?? url
        }

        isAuthenticating = true
        errorMessage = nil

        let name = serverName.isEmpty ? (cleanURL.host ?? selectedService.title) : serverName

        Task {
            do {
                let client: MediaServerProtocol
                let userID: String?
                switch serverType {
                case .emby:
                    let emby = EmbyClient(serverName: name, serverBaseURL: cleanURL)
                    client = emby
                    userID = emby.userId
                case .jellyfin:
                    let jellyfin = JellyfinClient(serverName: name, serverBaseURL: cleanURL)
                    client = jellyfin
                    userID = jellyfin.userId
                case .webDAV, .fnos:
                    client = WebDAVClient(serverName: name, serverBaseURL: cleanURL, username: normalizedUsername)
                    userID = nil
                case .smb:
                    #if MIVU_PRO
                    client = try SMBMediaClient(serverName: name, serverBaseURL: cleanURL, username: normalizedUsername)
                    userID = nil
                    #else
                    throw NSError(domain: "MivuLite", code: 1, userInfo: [NSLocalizedDescriptionKey: "SMB media libraries are available in Mivu Pro"])
                    #endif
                }

                let token = try await client.authenticate(username: normalizedUsername, password: inputPassword)
                let resolvedUserID: String? = {
                    if let emby = client as? EmbyClient { return emby.userId }
                    if let jellyfin = client as? JellyfinClient { return jellyfin.userId }
                    return userID
                }()

                await MainActor.run {
                    MediaServerManager.shared.addServer(
                        name: name,
                        url: cleanURL,
                        type: serverType,
                        username: normalizedUsername,
                        token: token,
                        userId: resolvedUserID
                    )
                    self.isAuthenticating = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.isAuthenticating = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
