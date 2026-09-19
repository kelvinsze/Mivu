import SwiftUI

/// View for managing personal media servers, network shares, and cloud drives.
public struct ServersView: View {
    @ObservedObject var serverManager = MediaServerManager.shared
    @State private var isShowingAddServerSheet = false
    @State private var isShowingAddMenu = false
    @State private var selectedServiceForAdd: ServiceMenuOption = .jellyfin

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
                            .tint(.orange)
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
                                            Text(server.name)
                                                .font(.headline)
                                                .foregroundColor(.primary)

                                            Text(brand.title)
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                        }

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
            .navigationTitle("资源库")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            isShowingAddMenu.toggle()
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(isShowingAddMenu ? .white : .orange)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(isShowingAddMenu ? Color.orange : Color.orange.opacity(0.12))
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
                            Text(selectedService.title)
                                .font(.headline.bold())
                            Text(selectedService.category.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Picker("", selection: $selectedService) {
                            ForEach(ServiceMenuOption.allCases) { opt in
                                Text(opt.title).tag(opt)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .padding(.vertical, 4)

                    if let hint = selectedService.guidanceHint {
                        Text(hint)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section("连接信息") {
                    TextField("服务器名称 (如: \(selectedService.defaultServerName))", text: $serverName)

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
            .onChange(of: selectedService) { _, newService in
                serverType = newService.targetServerType
                if serverName.isEmpty || ServiceMenuOption.allCases.contains(where: { $0.defaultServerName == serverName }) {
                    serverName = newService.defaultServerName
                }
                if serverUrlStr.isEmpty || ServiceMenuOption.allCases.contains(where: { $0.defaultURLPlaceholder == serverUrlStr }) {
                    serverUrlStr = newService.defaultURLPlaceholder
                }
            }
            .navigationTitle("添加 \(selectedService.title)")
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
                    client = try SMBMediaClient(serverName: name, serverBaseURL: cleanURL, username: normalizedUsername)
                    userID = nil
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
