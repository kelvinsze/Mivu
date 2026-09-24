import Foundation
import SwiftUI

/// Main TabView for Mivu (Standard / Lite Casting Edition)
/// Structure: [投屏 (Receiver), 历史 (History), 设置 (Settings)]
public struct MivuLiteTabView: View {
    @ObservedObject private var playerService = PlayerService.shared
    private let isCarPlayWindow: Bool

    public init(isCarPlayWindow: Bool = false) {
        self.isCarPlayWindow = isCarPlayWindow
    }

    public var body: some View {
        TabView {
            MivuReceiverHomeView()
                .tabItem {
                    Label("投屏", systemImage: "antenna.radiowaves.left.and.right")
                }

            HistoryView()
                .tabItem {
                    Label("历史", systemImage: "clock.arrow.circlepath")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
        }
        .tint(.blue)
        .fullScreenCover(isPresented: $playerService.isShowingPlayer) {
            if isCarPlayWindow {
                PlayerView()
            } else {
                MivuPlaybackPresentation()
            }
        }
    }
}

/// Uses the phone as a remote while CarPlay owns video presentation.
public struct MivuPlaybackPresentation: View {
    @ObservedObject private var playerService = PlayerService.shared

    public init() {}

    public var body: some View {
        if playerService.isCarPlayConnected {
            CarPlayRemoteControlView()
        } else {
            PlayerView()
        }
    }
}

/// A video-free playback control surface for the phone during CarPlay playback.
public struct CarPlayRemoteControlView: View {
    @ObservedObject private var playerService = PlayerService.shared
    @State private var isSeeking = false

    public init() {}

    public var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "car.play.fill")
                .font(.system(size: 54))
                .foregroundStyle(.blue)

            VStack(spacing: 8) {
                Text("正在 CarPlay 播放")
                    .font(.title2.bold())
                Text(playerService.session.currentItem?.title ?? "等待视频")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("视频仅显示在车机屏幕，手机作为遥控器使用")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { playerService.session.currentTime },
                        set: { playerService.seek(to: $0, origin: "CarPlayRemote.slider") }
                    ),
                    in: 0...max(playerService.session.duration, 1),
                    onEditingChanged: { isSeeking = $0 }
                )
                .disabled(playerService.session.duration <= 0)

                HStack {
                    Text(timeText(playerService.session.currentTime))
                    Spacer()
                    Text(timeText(playerService.session.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 34) {
                remoteButton(systemImage: "gobackward.15") {
                    playerService.seek(by: -15, origin: "CarPlayRemote.rewind")
                }

                Button {
                    playerService.togglePlayPause()
                } label: {
                    Image(systemName: playerService.session.status == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 31, weight: .semibold))
                        .frame(width: 78, height: 78)
                        .background(Color.blue, in: Circle())
                        .foregroundStyle(.white)
                }

                remoteButton(systemImage: "goforward.15") {
                    playerService.seek(by: 15, origin: "CarPlayRemote.forward")
                }
            }

            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(playerService.session.volume) },
                        set: { playerService.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                playerService.stop()
            } label: {
                Label("停止播放", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(28)
        .interactiveDismissDisabled()
        .background(Color(.systemGroupedBackground))
    }

    private func remoteButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())
        }
        .foregroundStyle(.primary)
    }

    private func timeText(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "00:00" }
        let seconds = Int(time)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
