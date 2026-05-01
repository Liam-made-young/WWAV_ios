import SwiftUI

struct RootTabView: View {
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.sand.ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    switch nav.active {
                    case .home:    HomeView()
                    case .search:  SearchView()
                    case .play:    PlayView()
                    case .plus:    UploadView()
                    case .profile: ProfileView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !nav.hidesTabBar {
                    TabBar(active: $nav.active)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: nav.hidesTabBar)
        .sheet(item: $nav.publicProfile) { route in
            PublicProfileSheet(route: route)
        }
    }
}
