import SwiftUI

/// Categories for services shown in the add-service menu.
public enum ServiceCategory: String, CaseIterable, Sendable {
    case networkProtocol = "协议存储"
    case mediaServer = "媒体服务器"
    case cloudDrive = "网盘存储"
}

/// All services supported in the add-service dropdown menu, matching the visual screenshot.
public enum ServiceMenuOption: String, CaseIterable, Identifiable, Sendable {
    // Group 1: 协议存储
    case webDAV
    case smb
    case ftp

    // Group 2: 媒体服务器
    case emby
    case jellyfin
    case plex
    case fnos

    // Group 3: 网盘存储
    case pan115
    case pan123
    case guangya
    case baidu
    case aliyun

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .webDAV: return "WebDAV"
        case .smb: return "SMB"
        case .ftp: return "FTP"
        case .emby: return "Emby"
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        case .fnos: return "飞牛影视"
        case .pan115: return "115网盘"
        case .pan123: return "123云盘"
        case .guangya: return "光鸭云盘"
        case .baidu: return "百度网盘"
        case .aliyun: return "阿里网盘"
        }
    }

    public var category: ServiceCategory {
        switch self {
        case .webDAV, .smb, .ftp:
            return .networkProtocol
        case .emby, .jellyfin, .plex, .fnos:
            return .mediaServer
        case .pan115, .pan123, .guangya, .baidu, .aliyun:
            return .cloudDrive
        }
    }

    public var defaultURLPlaceholder: String {
        switch self {
        case .webDAV: return "http://192.168.1.100:5005"
        case .smb: return "smb://192.168.1.100/video"
        case .ftp: return "ftp://192.168.1.100:21"
        case .emby: return "http://192.168.1.100:8096"
        case .jellyfin: return "http://192.168.1.100:8096"
        case .plex: return "http://192.168.1.100:32400"
        case .fnos: return "http://192.168.1.100:5600/dav"
        case .pan115: return "http://192.168.1.100:5244/dav/115"
        case .pan123: return "http://192.168.1.100:5244/dav/123"
        case .guangya: return "http://192.168.1.100:5244/dav/guangya"
        case .baidu: return "http://192.168.1.100:5244/dav/baidu"
        case .aliyun: return "http://192.168.1.100:5244/dav/aliyun"
        }
    }

    public var defaultServerName: String {
        switch self {
        case .webDAV: return "我的 WebDAV"
        case .smb: return "局域网共享 (SMB)"
        case .ftp: return "FTP 存储"
        case .emby: return "客厅 Emby"
        case .jellyfin: return "Jellyfin 影视库"
        case .plex: return "Plex 影视中心"
        case .fnos: return "飞牛私有云"
        case .pan115: return "我的 115网盘"
        case .pan123: return "我的 123云盘"
        case .guangya: return "我的 光鸭云盘"
        case .baidu: return "我的 百度网盘"
        case .aliyun: return "我的 阿里网盘"
        }
    }

    public var targetServerType: MediaServerType {
        switch self {
        case .emby: return .emby
        case .jellyfin: return .jellyfin
        case .webDAV: return .webDAV
        case .smb: return .smb
        case .fnos: return .fnos
        case .ftp: return .smb
        case .plex: return .emby
        case .pan115, .pan123, .guangya, .baidu, .aliyun: return .webDAV
        }
    }

    public var guidanceHint: String? {
        switch self {
        case .fnos:
            return "飞牛私有云 (fnOS) 推荐使用内置 WebDAV 协议进行高速挂载与流媒体直链播放。"
        case .pan115, .pan123, .guangya, .baidu, .aliyun:
            return "支持通过 WebDAV / AList 挂载服务连接，填入挂载端地址与账号密码即可流畅播放原画影视。"
        case .plex:
            return "支持连接 Plex Media Server 进行媒体发现与直接流媒体串流。"
        case .ftp:
            return "支持连接局域网 FTP 共享服务器。"
        case .smb:
            return "支持直接输入 IP 地址（如 192.168.1.100）或完整路径（如 smb://192.168.1.100/video）。未指定共享名时将自动列出所有共享文件夹。"
        default:
            return nil
        }
    }

    public static func detect(name: String, type: MediaServerType) -> ServiceMenuOption {
        let lower = name.lowercased()
        if lower.contains("115") { return .pan115 }
        if lower.contains("123") { return .pan123 }
        if lower.contains("光鸭") || lower.contains("guangya") || lower.contains("pikpak") { return .guangya }
        if lower.contains("百度") || lower.contains("baidu") { return .baidu }
        if lower.contains("阿里") || lower.contains("aliyun") || lower.contains("alipan") { return .aliyun }
        if lower.contains("plex") { return .plex }
        if lower.contains("ftp") { return .ftp }
        if lower.contains("飞牛") || lower.contains("fnos") { return .fnos }

        switch type {
        case .emby: return .emby
        case .jellyfin: return .jellyfin
        case .webDAV: return .webDAV
        case .smb: return .smb
        case .fnos: return .fnos
        }
    }
}

// MARK: - Brand Icons

/// Vector brand icon for network folder protocols (WebDAV, SMB, FTP).
/// Matches screenshot style: Apple-style colored folder shape on silver device rack base.
struct NetworkFolderIconView: View {
    let folderColor: Color

    var body: some View {
        ZStack(alignment: .bottom) {
            // Silver server tray base
            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.72), Color(white: 0.48)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 22, height: 5)

                    // Indicator slit
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 8, height: 1.2)
                }
            }
            .frame(height: 24)

            // Folder
            Image(systemName: "folder.fill")
                .font(.system(size: 19))
                .foregroundStyle(folderColor.gradient)
                .offset(y: -3)
                .shadow(color: folderColor.opacity(0.35), radius: 1, x: 0, y: 1)
        }
        .frame(width: 26, height: 26)
    }
}

/// Emby brand icon: Green diamond with play triangle
struct EmbyIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(red: 0.32, green: 0.71, blue: 0.29))
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(45))

            Image(systemName: "play.fill")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(.white)
                .offset(x: 0.5)
        }
        .frame(width: 26, height: 26)
    }
}

/// Jellyfin brand icon: Purple/violet layered gradient triangular shape
struct JellyfinIconView: View {
    var body: some View {
        ZStack {
            Image(systemName: "triangle")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.70, green: 0.38, blue: 0.88),
                            Color(red: 0.0, green: 0.65, blue: 0.88)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .frame(width: 26, height: 26)
    }
}

/// Plex brand icon: Dark circular badge with golden chevron
struct PlexIconView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.15, green: 0.15, blue: 0.17))
                .frame(width: 24, height: 24)

            Image(systemName: "chevron.right")
                .font(.system(size: 12.5, weight: .heavy))
                .foregroundColor(Color(red: 0.90, green: 0.63, blue: 0.05))
                .offset(x: 0.5)
        }
        .frame(width: 26, height: 26)
    }
}

/// fnOS (飞牛影视) brand icon: Blue square with winged 'f'
struct FnosIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.20, green: 0.55, blue: 0.98), Color(red: 0.10, green: 0.42, blue: 0.90)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 24, height: 24)

            ZStack {
                Text("f")
                    .font(.system(size: 16, weight: .heavy, design: .serif))
                    .italic()
                    .foregroundColor(.white)
                    .offset(x: -1, y: -0.5)

                Circle()
                    .fill(Color.white)
                    .frame(width: 3, height: 3)
                    .offset(x: 4, y: -4.5)
            }
        }
        .frame(width: 26, height: 26)
    }
}

/// 115网盘 icon: Stylized blue '5'
struct Pan115IconView: View {
    var body: some View {
        ZStack {
            Text("5")
                .font(.system(size: 21, weight: .heavy, design: .rounded))
                .italic()
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.18, green: 0.52, blue: 0.92), Color(red: 0.10, green: 0.35, blue: 0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .frame(width: 26, height: 26)
    }
}

/// 123云盘 icon: Blue rounded square with "123"
struct Pan123IconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(red: 0.09, green: 0.45, blue: 0.92))
                .frame(width: 24, height: 24)

            Text("123")
                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(width: 26, height: 26)
    }
}

/// 光鸭云盘 icon: Orange circle with duck / spiral silhouette
struct GuangyaIconView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.48, blue: 0.05), Color(red: 1.0, green: 0.36, blue: 0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 24, height: 24)

            Image(systemName: "record.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .overlay(
                    Circle()
                        .fill(Color(red: 1.0, green: 0.42, blue: 0.0))
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -2)
                )
        }
        .frame(width: 26, height: 26)
    }
}

/// 百度网盘 icon: Baidu 4-petal clover (red, cyan, blue)
struct BaiduPanIconView: View {
    var body: some View {
        ZStack {
            VStack(spacing: 1.5) {
                HStack(spacing: 1.5) {
                    Circle().fill(Color(red: 0.95, green: 0.25, blue: 0.25)).frame(width: 7.5, height: 7.5)
                    Circle().fill(Color(red: 0.15, green: 0.75, blue: 0.95)).frame(width: 7.5, height: 7.5)
                }
                HStack(spacing: 1.5) {
                    Circle().fill(Color(red: 0.12, green: 0.52, blue: 0.95)).frame(width: 7.5, height: 7.5)
                    Circle().fill(Color(red: 0.05, green: 0.35, blue: 0.85)).frame(width: 7.5, height: 7.5)
                }
            }
        }
        .frame(width: 26, height: 26)
    }
}

/// 阿里网盘 icon: Blue gradient mobius loop
struct AliyunPanIconView: View {
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            Color(red: 0.15, green: 0.50, blue: 0.95),
                            Color(red: 0.40, green: 0.75, blue: 1.0),
                            Color(red: 0.20, green: 0.55, blue: 0.98),
                            Color(red: 0.15, green: 0.50, blue: 0.95)
                        ],
                        center: .center
                    ),
                    lineWidth: 3.5
                )
                .frame(width: 19, height: 19)
        }
        .frame(width: 26, height: 26)
    }
}

/// High-fidelity brand icon resolver.
public struct ServiceBrandIconView: View {
    public let service: ServiceMenuOption

    public init(service: ServiceMenuOption) {
        self.service = service
    }

    public var body: some View {
        switch service {
        case .webDAV:
            NetworkFolderIconView(folderColor: Color(red: 0.20, green: 0.78, blue: 0.35))
        case .smb:
            NetworkFolderIconView(folderColor: Color(red: 1.0, green: 0.22, blue: 0.37))
        case .ftp:
            NetworkFolderIconView(folderColor: Color(red: 1.0, green: 0.62, blue: 0.04))
        case .emby:
            EmbyIconView()
        case .jellyfin:
            JellyfinIconView()
        case .plex:
            PlexIconView()
        case .fnos:
            FnosIconView()
        case .pan115:
            Pan115IconView()
        case .pan123:
            Pan123IconView()
        case .guangya:
            GuangyaIconView()
        case .baidu:
            BaiduPanIconView()
        case .aliyun:
            AliyunPanIconView()
        }
    }
}

// MARK: - Dropdown Menu View

/// The floating dropdown menu for adding services, meticulously styled after the screenshot.
public struct AddServiceDropdownMenuView: View {
    public let onSelect: (ServiceMenuOption) -> Void

    private let protocols: [ServiceMenuOption] = [.webDAV, .smb, .ftp]
    private let mediaServers: [ServiceMenuOption] = [.emby, .jellyfin, .plex, .fnos]
    private let cloudDrives: [ServiceMenuOption] = [.pan115, .pan123, .guangya, .baidu, .aliyun]

    public init(onSelect: @escaping (ServiceMenuOption) -> Void) {
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group 1: 协议存储
            ForEach(protocols) { item in
                menuRow(item)
            }

            dividerView

            // Group 2: 媒体服务器
            ForEach(mediaServers) { item in
                menuRow(item)
            }

            dividerView

            // Group 3: 网盘存储
            ForEach(cloudDrives) { item in
                menuRow(item)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 236)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.75))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.6)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
    }

    private func menuRow(_ item: ServiceMenuOption) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSelect(item)
        } label: {
            HStack(spacing: 14) {
                ServiceBrandIconView(service: item)
                    .frame(width: 26, height: 26)

                Text(item.title)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(.white)

                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 41)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    private var dividerView: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(height: 0.6)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Color.white.opacity(0.12) : Color.clear)
                    .padding(.horizontal, 6)
            )
    }
}
