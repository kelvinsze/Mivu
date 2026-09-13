import SwiftUI

/// View for managing personal media servers and network shares.
public struct ServersView: View {
    @ObservedObject var serverManager = MediaServerManager.shared
    @State private var isShowingAddServerSheet = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                if serverManager.savedServers.isEmpty {
                    Section {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.orange.opacity(0.12))
                                    .frame(width: 80, height: 80)
                                Image(systemName: "server.rack")
                                    .font(.system(size: 38))
                                    .foregroundColor(.orange)
                            }
                            .padding(.top, 20)

                            Text("尚未连接媒体服务器")
                                .font(.title3.bold())

                            Text("支持连接 Emby、Jellyfin、WebDAV、SMB 局域网共享与飞牛私有云，在 iPhone 和 CarPlay 上流畅播放海量个人影视。")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)

                            Button {
                                isShowingAddServerSheet = true
                            } label: {
                                Label("添加媒体源", systemImage: "plus.circle.fill")
                                    .font(.subheadline.bold())
                                    .padding(.horizontal, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .padding(.bottom, 20)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    Section("已连接的服务器") {
                        ForEach(serverManager.savedServers) { server in
                            NavigationLink {
                                ServerDetailView(serverInfo: server)
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.orange.opacity(0.12))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: icon(for: server.serverType))
                                            .font(.title3)
                                            .foregroundColor(.orange)
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(server.name)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Text(server.url.absoluteString)
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
            .navigationTitle("媒体库")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingAddServerSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundColor(.orange)
                    }
                }
            }
            .sheet(isPresented: $isShowingAddServerSheet) {
                AddServerView()
            }
        }
    }

    private func icon(for type: MediaServerType) -> String {
        switch type {
        case .emby: return "tv.fill"
        case .jellyfin, .fnos: return "play.square.stack.fill"
        case .webDAV: return "externaldrive.connected.to.line.below"
        case .smb: return "folder.badge.gearshape"
        }
    }
}

// MARK: - Add Server Sheet

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var serverName = ""
    @State private var serverUrlStr = ""
    @State private var serverType: MediaServerType = .jellyfin
    @State private var username = ""
    @State private var password = ""
    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器类型与连接") {
                    Picker("服务器类型", selection: $serverType) {
                        Text("Jellyfin").tag(MediaServerType.jellyfin)
                        Text("Emby").tag(MediaServerType.emby)
                        Text("WebDAV").tag(MediaServerType.webDAV)
                        Text("SMB (局域网共享)").tag(MediaServerType.smb)
                        Text("fnOS (飞牛 WebDAV)").tag(MediaServerType.fnos)
                    }

                    TextField("名称 (如: 客厅 NAS)", text: $serverName)

                    TextField(serverType == .smb ? "smb://192.168.1.100/video" : "http://192.168.1.100:8096", text: $serverUrlStr)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }

                Section("身份凭据") {
                    TextField("用户名", text: $username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    SecureField("密码", text: $password)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
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
                    .tint(.orange)
                }
            }
            .navigationTitle("添加媒体源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func authenticateAndSave() {
        guard let url = URL(string: serverUrlStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "输入的服务器地址不合法"
            return
        }
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        isAuthenticating = true
        errorMessage = nil

        let name = serverName.isEmpty ? (url.host ?? "Media Server") : serverName

        Task {
            do {
                let client: MediaServerProtocol
                let userID: String?
                switch serverType {
                case .emby:
                    let emby = EmbyClient(serverName: name, serverBaseURL: url)
                    client = emby
                    userID = emby.userId
                case .jellyfin:
                    let jellyfin = JellyfinClient(serverName: name, serverBaseURL: url)
                    client = jellyfin
                    userID = jellyfin.userId
                case .webDAV, .fnos:
                    client = WebDAVClient(serverName: name, serverBaseURL: url, username: normalizedUsername)
                    userID = nil
                case .smb:
                    client = try SMBMediaClient(serverName: name, serverBaseURL: url, username: normalizedUsername)
                    userID = nil
                }

                let token = try await client.authenticate(username: normalizedUsername, password: password)
                let resolvedUserID: String? = {
                    if let emby = client as? EmbyClient { return emby.userId }
                    if let jellyfin = client as? JellyfinClient { return jellyfin.userId }
                    return userID
                }()

                await MainActor.run {
                    MediaServerManager.shared.addServer(
                        name: name,
                        url: url,
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
