import SwiftUI

/// Main TabView for Mivu:
/// [Home, Servers, History, Settings]
public struct MainTabView: View {
    public init() {}

    public var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("首页", systemImage: "sparkles.tv")
                }

            ServersView()
                .tabItem {
                    Label("媒体库", systemImage: "film.stack.fill")
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
        .tint(.orange)
    }
}
