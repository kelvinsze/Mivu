import SwiftUI

/// Settings view for configuring the UPnP receiver and accessing Developer Lab.
public struct SettingsView: View {
    @AppStorage("mivu_custom_friendly_name") private var customFriendlyName: String = ""
    @ObservedObject private var playerService = PlayerService.shared

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

                // MARK: - Playback & Audio Preferences
                Section {
                    Picker("恢复播放自动回退", selection: Binding(
                        get: { playerService.rewindOnResumeSeconds },
                        set: { playerService.setRewindOnResumeSeconds($0) }
                    )) {
                        Text("关闭").tag(0)
                        Text("3 秒").tag(3)
                        Text("5 秒").tag(5)
                    }

                    Picker("智能跳过片头", selection: Binding(
                        get: { playerService.skipIntroSeconds },
                        set: { playerService.setSkipIntroSeconds($0) }
                    )) {
                        Text("关闭").tag(0)
                        Text("15 秒").tag(15)
                        Text("30 秒").tag(30)
                        Text("60 秒").tag(60)
                        Text("90 秒").tag(90)
                        Text("120 秒").tag(120)
                    }

                    Picker("智能跳过片尾", selection: Binding(
                        get: { playerService.skipOutroSeconds },
                        set: { playerService.setSkipOutroSeconds($0) }
                    )) {
                        Text("关闭").tag(0)
                        Text("30 秒").tag(30)
                        Text("60 秒").tag(60)
                        Text("90 秒").tag(90)
                        Text("120 秒").tag(120)
                        Text("180 秒").tag(180)
                    }

                    Toggle("默认开启人声增强", isOn: Binding(
                        get: { playerService.isVoiceBoostEnabled },
                        set: { playerService.setVoiceBoost($0) }
                    ))
                    .tint(.orange)
                } header: {
                    Text("播放偏好与增强")
                } footer: {
                    Text("设置回退秒数以便暂停恢复时温习前情；开启片头片尾智能跳过，将在连播时更省心；人声增强可动态平衡对白响度。")
                        .font(.caption2)
                }

                // MARK: - Subtitles & Playback
                Section {
                    Picker("字幕默认大小", selection: Binding(
                        get: { playerService.subtitleUserScale },
                        set: { playerService.setSubtitleUserScale($0) }
                    )) {
                        Text("极小 (75%)").tag(0.75)
                        Text("较小 (85%)").tag(0.85)
                        Text("标准 (100%)").tag(1.0)
                        Text("较大 (120%)").tag(1.20)
                        Text("特大 (140%)").tag(1.40)
                        Text("极大 (160%)").tag(1.60)
                    }

                    Toggle("竖屏适度缩小 (0.85x)", isOn: Binding(
                        get: { playerService.subtitleAutoPortraitScale },
                        set: { playerService.setSubtitleAutoPortraitScale($0) }
                    ))
                    .tint(.orange)
                } header: {
                    Text("字幕设置 (Subtitles)")
                } footer: {
                    Text("开启后，在手机竖屏播放视频时会自动微调字幕比例，避免在小窗口下遮挡画面；在播放器中点击字幕按钮也可实时微调。")
                        .font(.caption2)
                }

                Section {
                    Picker("网络限速", selection: Binding(
                        get: { playerService.playbackRateLimitMbps },
                        set: { playerService.setPlaybackRateLimitMbps($0) }
                    )) {
                        Text("不限速").tag(0)
                        Text("5 Mbps").tag(5)
                        Text("10 Mbps").tag(10)
                        Text("20 Mbps").tag(20)
                        Text("50 Mbps").tag(50)
                    }

                    Picker("缓存上限", selection: Binding(
                        get: { playerService.playbackCacheLimitMB },
                        set: { playerService.setPlaybackCacheLimitMB($0) }
                    )) {
                        Text("32 MB").tag(32)
                        Text("64 MB").tag(64)
                        Text("128 MB").tag(128)
                        Text("256 MB").tag(256)
                        Text("512 MB").tag(512)
                    }
                } header: {
                    Text("播放网络与缓存")
                } footer: {
                    Text("限速用于 HLS 自适应码率选择；缓存上限对 MPV 直接生效，AVPlayer 按等效预读时长请求。设置会保存，并在下一次播放时使用。")
                        .font(.caption2)
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
