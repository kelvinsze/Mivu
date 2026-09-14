import SwiftUI

/// Developer and casting diagnostic lab, housing all MVP debug tools,
/// direct URL stream tester, sample benchmarks, and raw UPnP/CarPlay telemetry.
public struct DeveloperLabView: View {
    @ObservedObject var playerService = PlayerService.shared
    @State private var inputUrlText: String = ""
    @State private var clipboardURL: URL?
    @State private var isShowingPlayerSheet = false
    @State private var errorMessage: String?
    @State private var isShowingErrorAlert = false

    public init() {}

    public var body: some View {
        List {
            // MARK: - 1. Receiver & Casting Status
            Section {
                ReceiverStatusView()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } header: {
                Label("投送接收端监控", systemImage: "antenna.radiowaves.left.and.right")
            }

            // MARK: - 2. Direct Stream URL Tester
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("输入 HTTP / HTTPS 直链或 HLS (.m3u8) 进行临时测试：")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        TextField("https://example.com/stream.m3u8", text: $inputUrlText)
                            .font(.callout.monospaced())
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)

                        Button {
                            playInputUrl()
                        } label: {
                            Image(systemName: "play.fill")
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .disabled(inputUrlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Button("从剪贴板读取", systemImage: "doc.on.clipboard") {
                        clipboardURL = URLSource.detectPlayableURLInClipboard()
                    }
                    .buttonStyle(.bordered)

                    if let detected = clipboardURL {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("剪贴板已捕获流地址")
                                    .font(.caption2.bold())
                                    .foregroundColor(.orange)
                                Text(detected.absoluteString)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("填入") {
                                inputUrlText = detected.absoluteString
                                clipboardURL = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(8)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Label("自定义 URL 播放测试", systemImage: "play.rectangle")
            }

            // MARK: - 3. Sample Benchmark Streams
            Section {
                ForEach(MediaItem.sampleStreams) { sample in
                    NavigationLink(destination: VideoDetailView(item: sample)) {
                        HStack(spacing: 12) {
                            Image(systemName: sample.mimeType?.contains("mpegURL") == true ? "antenna.radiowaves.left.and.right" : "film")
                                .font(.headline)
                                .foregroundColor(.orange)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(sample.title)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.primary)
                                Text(sample.url.absoluteString)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Label("内置基准测试视频 (Phase 1 验证)", systemImage: "flame.fill")
            } footer: {
                Text("包含 Apple 官方 HLS 多码率流、MP4 高清测试视频，用于验证播放引擎渲染与 CarPlay 投送稳定性。")
                    .font(.caption2)
            }

            // MARK: - 4. Deep Telemetry & Network Diagnostics
            Section {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("网络链路与投屏深度诊断")
                                    .font(.subheadline.bold())
                                Text("查看组播、活跃网卡接口、Web Remote 与详细日志")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "waveform.path.ecg")
                                .foregroundColor(.cyan)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Label("系统诊断中心", systemImage: "stethoscope")
            }
        }
        .navigationTitle("开发者与实验室")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isShowingPlayerSheet) {
            PlayerView()
        }
        .alert("播放错误", isPresented: $isShowingErrorAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "发生未知错误")
        }
    }

    private func playInputUrl() {
        let trimmed = inputUrlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            errorMessage = "输入的视频地址无效，必须为 HTTP 或 HTTPS 直链。"
            isShowingErrorAlert = true
            return
        }

        let item = MediaItem(
            title: url.lastPathComponent.isEmpty ? "Direct Stream" : url.lastPathComponent,
            url: url,
            sourceType: .directUrl,
            originator: "Lab URL Input"
        )
        playerService.loadAndPlay(item: item)
        isShowingPlayerSheet = true
        inputUrlText = ""
    }
}
