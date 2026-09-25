import SwiftUI

/// Categories for services shown in the add-service menu.
public enum ServiceCategory: String, CaseIterable, Sendable {
    case networkProtocol = "协议存储"
    case mediaServer = "媒体服务器"

    public var title: String {
        String(localized: rawValue)
    }
}

/// All services supported in the add-service dropdown menu.
public enum ServiceMenuOption: String, CaseIterable, Identifiable, Sendable {
    // Group 1: 协议存储
    case webDAV
    case smb

    // Group 2: 媒体服务器
    case emby
    case jellyfin
    case fnos

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .webDAV: return "WebDAV"
        case .smb: return "SMB"
        case .emby: return "Emby"
        case .jellyfin: return "Jellyfin"
        case .fnos: return String(localized: "飞牛影视")
        }
    }

    public var category: ServiceCategory {
        switch self {
        case .webDAV, .smb:
            return .networkProtocol
        case .emby, .jellyfin, .fnos:
            return .mediaServer
        }
    }

    public var defaultURLPlaceholder: String {
        switch self {
        case .webDAV: return "http://192.168.1.100:5005"
        case .smb: return "smb://192.168.1.100/video"
        case .emby: return "http://192.168.1.100:8096"
        case .jellyfin: return "http://192.168.1.100:8096"
        case .fnos: return "http://192.168.1.100:5600/dav"
        }
    }

    public var defaultServerName: String {
        switch self {
        case .webDAV: return String(localized: "我的 WebDAV")
        case .smb: return String(localized: "局域网共享 (SMB)")
        case .emby: return String(localized: "客厅 Emby")
        case .jellyfin: return String(localized: "Jellyfin 影视库")
        case .fnos: return String(localized: "飞牛私有云")
        }
    }

    public var targetServerType: MediaServerType {
        switch self {
        case .emby: return .emby
        case .jellyfin: return .jellyfin
        case .webDAV: return .webDAV
        case .smb: return .smb
        case .fnos: return .fnos
        }
    }

    public var guidanceHint: String? {
        switch self {
        case .fnos:
            return String(localized: "飞牛私有云 (fnOS) 推荐使用内置 WebDAV 协议进行高速挂载与流媒体直链播放。")
        case .smb:
            return String(localized: "支持直接输入 IP 地址（如 192.168.1.100）或完整路径（如 smb://192.168.1.100/video）。未指定共享名时将自动列出所有共享文件夹。")
        default:
            return nil
        }
    }

    public static func detect(name: String, type: MediaServerType) -> ServiceMenuOption {
        let lower = name.lowercased()
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
        case .emby:
            EmbyIconView()
        case .jellyfin:
            JellyfinIconView()
        case .fnos:
            FnosIconView()
        }
    }
}

// MARK: - Dropdown Menu View

/// The floating dropdown menu for adding services, meticulously styled after the screenshot.
public struct AddServiceDropdownMenuView: View {
    public let onSelect: (ServiceMenuOption) -> Void

    private let protocols: [ServiceMenuOption] = [.webDAV, .smb]
    private let mediaServers: [ServiceMenuOption] = [.emby, .jellyfin, .fnos]

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
