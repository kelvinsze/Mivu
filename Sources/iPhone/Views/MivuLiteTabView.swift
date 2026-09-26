import Foundation
import SwiftUI

/// Shared visual vocabulary for both editions. Feature screens may differ, but
/// their hierarchy, spacing, surfaces and primary playback state stay aligned.
public enum MivuSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let s: CGFloat = 12
    public static let m: CGFloat = 16
    public static let l: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48
}

public enum MivuRadius {
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
}

public enum MivuEdition {
    public static var primaryTint: Color {
        return .mivuAccent
    }

    public static var utilityTint: Color {
        return .mivuAccent
    }

    /// Kept separate from Amber: this identifies the Pro edition and must not
    /// become a second primary interaction color.
    public static var proIdentityTint: Color {
        .mivuProTitanium
    }

    public static var secondarySurface: Color {
        return .mivuSurface
    }
}

public extension Color {
    static let mivuOnAccent = Color(red: 23 / 255, green: 23 / 255, blue: 25 / 255)
    static let mivuAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 240 / 255, green: 164 / 255, blue: 58 / 255, alpha: 1)
            : UIColor(red: 232 / 255, green: 154 / 255, blue: 50 / 255, alpha: 1)
    })
    static let mivuBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 17 / 255, green: 17 / 255, blue: 19 / 255, alpha: 1)
            : UIColor(red: 245 / 255, green: 244 / 255, blue: 241 / 255, alpha: 1)
    })
    static let mivuSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
            : .white
    })
    static let mivuSurfaceSecondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 41 / 255, green: 41 / 255, blue: 44 / 255, alpha: 1)
            : UIColor(red: 236 / 255, green: 234 / 255, blue: 230 / 255, alpha: 1)
    })
    static let mivuProTitanium = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 210 / 255, green: 179 / 255, blue: 113 / 255, alpha: 1)
            : UIColor(red: 143 / 255, green: 111 / 255, blue: 56 / 255, alpha: 1)
    })
}

/// A restrained edition marker for membership and upgrade surfaces only.
public struct MivuProBadge: View {
    public init() {}

    public var body: some View {
        Label("Pro", systemImage: "crown.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(MivuEdition.proIdentityTint)
            .padding(.horizontal, MivuSpacing.xs)
            .padding(.vertical, MivuSpacing.xxs)
            .background(
                MivuEdition.proIdentityTint.opacity(0.12),
                in: Capsule()
            )
    }
}

public struct MivuSurface<Content: View>: View {
    private let radius: CGFloat
    private let content: Content

    public init(radius: CGFloat = MivuRadius.l, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    public var body: some View {
        content
            .background(Color.mivuSurface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

public extension View {
    func mivuSurface(radius: CGFloat = MivuRadius.l) -> some View {
        MivuSurface(radius: radius) { self }
    }
}

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
            MivuReceiverHomeView(isCarPlayWindow: isCarPlayWindow)
                .tabItem {
                    Label("投屏", systemImage: "rectangle.connected.to.line.below")
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
        .tint(Color.mivuAccent)
        .fullScreenCover(isPresented: $playerService.isShowingPlayer) {
            if isCarPlayWindow {
                if playerService.isCarPlayVideoPlaybackAvailable {
                    PlayerView()
                } else {
                    CarPlayRemoteControlView()
                }
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
        VStack(spacing: MivuSpacing.xl) {
            Spacer()

            Image(systemName: "car.play.fill")
                .font(.system(size: 54))
                .foregroundStyle(Color.mivuAccent)

            VStack(spacing: MivuSpacing.xs) {
                Text("正在 CarPlay 播放")
                    .font(.title2.bold())
                Text(verbatim: playerService.session.currentItem?.title ?? String(localized: "等待视频"))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(playerService.isCarPlayVideoPlaybackAvailable
                    ? "视频仅显示在车机屏幕，手机作为遥控器使用"
                    : "车辆行驶中，已切换为仅音频播放")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: MivuSpacing.s) {
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

            HStack(spacing: MivuSpacing.xl) {
                remoteButton(systemImage: "gobackward.15") {
                    playerService.seek(by: -15, origin: "CarPlayRemote.rewind")
                }

                Button {
                    playerService.togglePlayPause()
                } label: {
                    Image(systemName: playerService.session.status == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 31, weight: .semibold))
                        .frame(width: 78, height: 78)
                        .background(Color.mivuAccent, in: Circle())
                        .foregroundStyle(.white)
                }

                remoteButton(systemImage: "goforward.15") {
                    playerService.seek(by: 15, origin: "CarPlayRemote.forward")
                }
            }

            HStack(spacing: MivuSpacing.s) {
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
        .padding(MivuSpacing.l)
        .interactiveDismissDisabled()
        .background(Color.mivuBackground)
    }

    private func remoteButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(Color.mivuSurfaceSecondary, in: Circle())
        }
        .foregroundStyle(.primary)
    }

    private func timeText(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "00:00" }
        let seconds = Int(time)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
