import SwiftUI

@main
struct WWAVApp: App {
    @StateObject private var auth: AuthManager
    @StateObject private var library: TrackLibrary
    @StateObject private var player = StemPlayerEngine()
    @StateObject private var nav = AppNavigation()
    @StateObject private var themeManager = ThemeManager()

    // Live Radio pipeline — shared in-process transport bus.
    // To swap in a remote backend: replace `InProcessLiveRadioTransport` with
    // a `RemoteLiveRadioTransport` conforming to `LiveRadioTransport` and
    // update the two lines below. Everything else stays the same.
    @StateObject private var radioTransport = InProcessLiveRadioTransport()
    @StateObject private var broadcaster: LiveRadioBroadcaster
    @StateObject private var listener: LiveRadioListener

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

        // Build the transport first so broadcaster + listener share it.
        let transport = InProcessLiveRadioTransport()
        let broadcaster = LiveRadioBroadcaster(transport: transport)
        let listener = LiveRadioListener(transport: transport, library: library)

        _auth = StateObject(wrappedValue: auth)
        _library = StateObject(wrappedValue: library)
        _radioTransport = StateObject(wrappedValue: transport)
        _broadcaster = StateObject(wrappedValue: broadcaster)
        _listener = StateObject(wrappedValue: listener)
    }

    var body: some Scene {
        WindowGroup {
            RootGate()
                .environmentObject(auth)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(nav)
                .environmentObject(themeManager)
                .environmentObject(broadcaster)
                .environmentObject(listener)
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
