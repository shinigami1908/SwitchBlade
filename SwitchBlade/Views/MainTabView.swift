import SwiftUI

struct MainTabView: View {
    @State private var selection: Tab = .home

    enum Tab: Hashable {
        case home, library, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)

            LibraryView()
                .tabItem { Label("Library", systemImage: "square.stack") }
                .tag(Tab.library)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(.appAccent)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(Color.appSurface, for: .tabBar)
    }
}
