import SwiftUI

/// Settings view for configuring the UPnP receiver and accessing Developer Lab.
public struct SettingsView: View {
    @AppStorage("mivu_custom_friendly_name") private var customFriendlyName: String = ""

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                // MARK: - Receiver & Network Casting
                Section("车载投送 (CarPlay & DLNA)") {
                    HStack {
                        Label("车机显示名称", systemImage: "car.fill")
                            .foregroundColor(.orange)
                        Spacer()
                        TextField("Mivu Car", text: $customFriendlyName)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .onChange(of: customFriendlyName) { _, newValue in
                                if !newValue.isEmpty {
                                    UPnPDevice.shared.friendlyName = newValue
                                }
                            }
                    }

                    HStack {
                        Label("投送服务端口", systemImage: "network")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(HTTPServer.shared.port)")
                            .font(.subheadline.monospaced())
                            .foregroundColor(.secondary)
                    }
                }

                // MARK: - Developer & Casting Lab
                Section {
                    NavigationLink {
                        DeveloperLabView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "flask.fill")
                                .font(.title3)
                                .foregroundColor(.purple)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("开发者与实验室")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.primary)
                                Text("投屏监控端点、测试基准源、URL 播放器与诊断日志")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("实验室与调试工具")
                } footer: {
                    Text("包含 DLNA 服务监控、Apple HLS / MP4 测试流、自定义 URL 播放器及系统网络诊断。")
                        .font(.caption2)
                }

                // MARK: - Entitlements Status
                Section("系统权限与能力状态") {
                    HStack {
                        Label("CarPlay Video in Car", systemImage: "car.side.fill")
                        Spacer()
                        Text("以签名包为准")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Label("组播网络 (Multicast)", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text("以签名包为准")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // MARK: - About
                Section("关于 Mivu") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("渲染内核")
                        Spacer()
                        Text("Native AVPlayer + MPV Core")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }

                    Link("用户隐私政策", destination: URL(string: "https://mivu.app/privacy")!)
                }
            }
            .navigationTitle("设置")
        }
    }
}
