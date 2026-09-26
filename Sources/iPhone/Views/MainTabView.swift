import SwiftUI

/// Main TabView for Mivu:
/// [Home, Library, History, Settings]
public struct MainTabView: View {
    @ObservedObject private var playerService = PlayerService.shared
    private let isCarPlayWindow: Bool

    public init(isCarPlayWindow: Bool = false) {
        self.isCarPlayWindow = isCarPlayWindow
    }

    public var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }

            ServersView()
                .tabItem {
                    Label("资源库", systemImage: "rectangle.stack.fill")
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
        .tint(MivuEdition.primaryTint)
        .fullScreenCover(isPresented: $playerService.isShowingPlayer) {
            if isCarPlayWindow {
                PlayerView()
            } else {
                MivuPlaybackPresentation()
            }
        }
    }
}
