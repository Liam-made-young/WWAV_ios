import SwiftUI

@main
struct WWAVApp: App {
    @StateObject private var auth: AuthManager
    @StateObject private var library: TrackLibrary
    @StateObject private var player = StemPlayerEngine()
    @StateObject private var nav = AppNavigation()
    @StateObject private var themeManager = ThemeManager()

    init() {
        // Generous URLCache so covers + thumbnails are read from disk on
        // re-entry instead of re-downloading every time a feed cell scrolls
        // into view. CachedAsyncImage layers an NSCache on top for
        // already-decoded UIImages.
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,    // 32 MB
            diskCapacity:  256 * 1024 * 1024,    // 256 MB
            diskPath: "wwav-image-cache"
        )

        let auth = AuthManager()
        let provider: MiWwavStemService.TokenProvider = { [weak auth] in
            auth?.token
        }
        let separator = MiWwavStemService(tokenProvider: provider)
        let library = TrackLibrary(separator: separator)

        _auth = StateObject(wrappedValue: auth)
        _library = StateObject(wrappedValue: library)
    }

    var body: some Scene {
        WindowGroup {
            RootGate()
                .environmentObject(auth)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(nav)
                .environmentObject(themeManager)
                .environment(\.theme, themeManager.palette)
                .preferredColorScheme(.light)
                .tint(themeManager.palette.ink)
        }
    }
}

private struct RootGate: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var library: TrackLibrary

    var body: some View {
        Group {
            if auth.isLoggedIn {
                RootTabView()
            } else {
                LoginView()
            }
        }
        .task { await auth.restoreSession() }
        // Mirror the signed-in user's identity into the local profile so
        // uploads carry the right artist name and the profile screen matches.
        .onChange(of: auth.user) { _, new in
            if let user = new { library.syncProfile(from: user) }
        }
    }
}
