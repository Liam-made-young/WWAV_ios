import SwiftUI

struct PlayView: View {
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var listener: LiveRadioListener
    @Environment(\.theme) private var theme
    @State private var showingComments = false
    @State private var showingRemix: Bool = false

    private var currentMusicTrack: Track? {
        guard let current = player.currentTrack else { return nil }
        return library.feed.first(where: { $0.id == current.id })
            ?? library.myTracks.first(where: { $0.id == current.id })
            ?? current
    }

    private var playbackQueue: [Track] {
        var seen: Set<UUID> = []
        return (library.feed + library.myTracks).filter { track in
            guard track.kind == .music else { return false }
            guard seen.insert(track.id).inserted else { return false }
            if case .ready = track.status { return true }
            return false
        }
    }

    var body: some View {
        Group {
            if nav.tunedInSessionId != nil {
                // Live-listener mode — show either the talk visualizer or the
                // locked-down stem player. No pause / seek / skip allowed.
                liveListenerBody
            } else if let post = nav.activePost, post.kind == .video {
                VideoPostPlayer(post: post)
                    .id(post.id)
            } else {
                stemBody
                    .overlay {
                        if player.preparingTrack != nil {
                            PreparingOverlay(
                                track: player.preparingTrack,
                                progress: player.preparingProgress
                            )
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: player.preparingTrack?.id)
            }
        }
        .onAppear { autoLoadIfNeeded() }
        .onChange(of: library.myTracks) { _, _ in autoLoadIfNeeded() }
        .fullScreenCover(isPresented: $showingRemix) {
            if let track = player.currentTrack {
                RemixSheet(track: track)
            }
        }
    }

    // MARK: – Live listener body

    @ViewBuilder
    private var liveListenerBody: some View {
        ZStack {
            theme.centerRadial.ignoresSafeArea()
            VStack(spacing: 0) {
                liveListenerHeader
                    .padding(.horizontal, 28)
                    .padding(.top, 8)

                switch listener.mode {
                case .talk:
                    LiveTalkVisualizer(
                        level: listener.talkLevel,
                        sessionTitle: liveSessionTitle
                    )
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)

                case .song(let track):
                    liveListenerSongView(track: track)
                }

                // Volume is fine; pause / seek / skip are not available in
                // live mode (the experience is unpausable by design).
                liveListenerVolumeRow
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
    }

    private var liveListenerHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("live radio").wwavLabel()
                Text(liveSessionTitle)
                    .wwavTitle(size: 22)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                listener.tuneOut()
                nav.leaveLive()
            } label: {
                Text("leave")
                    .font(.wwav(11, weight: .medium, italic: true))
                    .tracking(1.4)
                    .foregroundStyle(theme.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(theme.sand.opacity(0.6)))
                    .overlay(Capsule().stroke(theme.muted.opacity(0.22), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func liveListenerSongView(track: Track) -> some View {
        VStack(spacing: 12) {
            // Song info header (no controls).
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(track.title)
                        .wwavTitle(size: 36)
                        .lineLimit(1)
                    Spacer()
                }
                Text("\(track.artist.lowercased()) — live")
                    .wwavLabel(size: 12, tracking: 1.4)
                    .foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 28)

            // Re-use the circular waveform but disable seeking.
            let canvas = UIScreen.main.bounds.width - 40
            let sphereVisualRadius = canvas * 0.755 / 2
            ZStack {
                StemPlayerWidget(engine: player, size: canvas)
                CircularWaveform(
                    peaks: player.peaks,
                    progress: 0,          // Position locked — driven by DJ.
                    canvasSize: canvas,
                    innerRadius: sphereVisualRadius,
                    maxBarHeight: (canvas / 2) - sphereVisualRadius - 2,
                    onSeek: { _ in }      // Seeking disabled in live mode.
                )
            }
            .frame(width: UIScreen.main.bounds.width - 10,
                   height: UIScreen.main.bounds.width - 10)

            Text("synced to DJ clock")
                .font(.wwav(11, weight: .light, italic: true))
                .tracking(1.2)
                .foregroundStyle(theme.muted)
        }
        .padding(.vertical, 8)
    }

    private var liveListenerVolumeRow: some View {
        // A simple mute toggle — real volume slider omitted for brevity.
        // The listener can still adjust system volume with hardware buttons.
        HStack {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 14))
                .foregroundStyle(theme.muted)
            Text("system volume controls audio")
                .font(.wwav(11, weight: .light, italic: true))
                .tracking(1)
                .foregroundStyle(theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 8)
    }

    private var liveSessionTitle: String {
        guard let sid = nav.tunedInSessionId else { return "live" }
        let session = library.radioSessions.first { $0.id == sid }
        return session?.title ?? "live"
    }

    private var stemBody: some View {
        ZStack {
            theme.centerRadial.ignoresSafeArea()
            VStack(spacing: 12) {
                header.padding(.horizontal, 28)
                titleBlock.padding(.horizontal, 28)
                if let track = currentMusicTrack {
                    musicSocialPanel(track)
                        .padding(.horizontal, 28)
                }
                Spacer(minLength: 8)
                stemStage
                Spacer(minLength: 8)
                if player.currentTrack != nil {
                    transportControls.padding(.horizontal, 28)
                } else {
                    Text("tap a music track to load four stems into the player.")
                        .font(.wwav(13, weight: .light, italic: true))
                        .foregroundStyle(theme.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    /// The 3-D widget centered inside the circular waveform, full-bleed.
    ///
    /// The SCN scene is configured so the sphere fills ~75.5% of its view
    /// (camera z=4.2, FOV 35°, sphere radius 1.0). With the SCN canvas equal
    /// to the wave canvas, the sphere's silhouette lands exactly on the
    /// waveform's inner radius — the bars look like they're emanating from
    /// the coin itself. The waveform is also the scrub bar — taps and drags
    /// on the ring seek the engine.
    private var stemStage: some View {
        let progress: Double = player.duration > 0
            ? min(1, player.elapsed / player.duration)
            : 0

        return GeometryReader { geo in
            let canvas = geo.size.width - 10
            let sphereVisualRadius = canvas * 0.755 / 2

            ZStack {
                StemPlayerWidget(engine: player, size: canvas)
                CircularWaveform(
                    peaks: player.peaks,
                    progress: progress,
                    canvasSize: canvas,
                    innerRadius: sphereVisualRadius,
                    maxBarHeight: (canvas / 2) - sphereVisualRadius - 2,
                    onSeek: { fraction in
                        guard player.duration > 0 else { return }
                        player.seek(to: fraction * player.duration)
                    }
                )
            }
            .frame(width: geo.size.width, height: geo.size.width, alignment: .center)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var timeLabels: some View {
        HStack {
            Text(formatTime(player.elapsed))
            Spacer()
            Text(formatTime(player.duration))
        }
        .font(.wwav(11, weight: .light))
        .tracking(1.5)
        .foregroundStyle(theme.muted)
    }

    private var transportControls: some View {
        HStack(spacing: 18) {
            skipButton(icon: "backward.end.fill", direction: -1)
            timeLabels
            skipButton(icon: "forward.end.fill", direction: 1)
        }
    }

    private func skipButton(icon: String, direction: Int) -> some View {
        Button {
            skipTrack(by: direction)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(playbackQueue.count > 1 ? theme.ink : theme.muted.opacity(0.45))
                .frame(width: 38, height: 38)
                .background(Circle().fill(theme.sand.opacity(0.70)))
                .overlay(Circle().stroke(theme.muted.opacity(0.20), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(playbackQueue.count < 2)
    }

    private var header: some View {
        HStack {
            Text("now playing").wwavLabel()
            Spacer()
            if let track = currentMusicTrack {
                Text(positionLabel(for: track))
                    .font(.wwav(11, weight: .light))
                    .tracking(2)
                    .foregroundStyle(theme.muted)
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(currentMusicTrack?.title ?? "no track loaded")
                    .wwavTitle(size: 46)
                    .lineLimit(1)
                Spacer()
            }
            if let track = currentMusicTrack {
                HStack(spacing: 8) {
                    Text("\(track.artist.lowercased()) — \(track.bio.isEmpty ? "stems ready" : "stems")")
                        .wwavLabel(size: 13, tracking: 1.5)
                        .foregroundStyle(theme.muted)

                    if track.isRemix {
                        Text("remix")
                            .font(.wwav(9, weight: .medium))
                            .tracking(1.2)
                            .foregroundStyle(theme.glow)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.accent))

                        if let parent = library.parentTrack(of: track) {
                            Button {
                                nav.openPost(parent, in: library, with: player)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.up.left.circle")
                                        .font(.system(size: 10, weight: .regular))
                                    Text("source")
                                        .font(.wwav(9, weight: .light))
                                        .tracking(1.0)
                                }
                                .foregroundStyle(theme.muted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.muted.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func musicSocialPanel(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    nav.openProfile(for: track)
                } label: {
                    HStack(spacing: 8) {
                        ProfileAvatar(url: track.authorProfilePictureURL, size: 30)
                        Text("@\(track.handle)")
                            .font(.wwav(11, weight: .light))
                            .tracking(1)
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)

                if library.canFollow(track) {
                    Button {
                        Task { await library.toggleFollow(track: track, token: auth.token) }
                    } label: {
                        let following = library.isFollowing(track)
                        HStack(spacing: 5) {
                            Image(systemName: following ? "checkmark" : "plus")
                                .font(.system(size: 10, weight: .bold))
                            Text(following ? "following" : "follow")
                                .font(.wwav(10, weight: .medium, italic: true))
                                .tracking(1.2)
                        }
                        .foregroundStyle(following ? theme.ink : theme.glow)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(following ? theme.muted.opacity(0.12) : theme.accent))
                        .overlay(Capsule().stroke(theme.muted.opacity(following ? 0.18 : 0), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                musicAction(
                    icon: track.liked ? "heart.fill" : "heart",
                    label: short(track.loves),
                    active: track.liked,
                    activeColor: Color.red.opacity(0.85)
                ) {
                    Task { await library.toggleLike(track: track, token: auth.token) }
                }

                musicAction(
                    icon: showingComments ? "bubble.left.fill" : "bubble.left",
                    label: track.comments > 0 ? short(track.comments) : "reply",
                    active: showingComments,
                    activeColor: theme.accent
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showingComments.toggle()
                    }
                }

                musicAction(
                    icon: "arrow.2.squarepath",
                    label: short(track.reposts),
                    active: track.reposted,
                    activeColor: theme.accent
                ) {
                    library.toggleRepost(track: track)
                }

                Button {
                    showingRemix = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform.badge.plus")
                            .font(.system(size: 13, weight: .regular))
                        Text("remix")
                            .font(.wwav(10, weight: .light))
                            .tracking(1)
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("\(short(track.plays)) plays")
                    .font(.wwav(10, weight: .light))
                    .tracking(1.2)
                    .foregroundStyle(theme.muted)

                Spacer(minLength: 0)
            }

            if showingComments {
                CommentsThread(track: track)
                    .frame(maxHeight: 220)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func musicAction(
        icon: String,
        label: String,
        active: Bool,
        activeColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                Text(label)
                    .font(.wwav(10, weight: .light))
                    .tracking(1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(active ? activeColor : theme.muted)
            .padding(.vertical, 6)
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func positionLabel(for track: Track) -> String {
        let musicTracks = library.myTracks.filter { $0.kind == .music }
        guard let idx = musicTracks.firstIndex(where: { $0.id == track.id }) else { return "" }
        let total = musicTracks.count
        return String(format: "%02d / %02d", idx + 1, total)
    }

    private func formatTime(_ s: Double) -> String {
        let total = max(0, Int(s))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func skipTrack(by direction: Int) {
        guard let current = currentMusicTrack else { return }
        let queue = playbackQueue
        guard queue.count > 1,
              let index = queue.firstIndex(where: { $0.id == current.id }) else { return }
        let nextIndex = (index + direction + queue.count) % queue.count
        nav.openPost(queue[nextIndex], in: library, with: player)
    }

    private func short(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
        return "\(n)"
    }

    private func autoLoadIfNeeded() {
        // Don't auto-load music when a video post is the active focus,
        // or when we're already in the middle of preparing one.
        if let post = nav.activePost, post.kind == .video { return }
        if player.preparingTrack != nil { return }
        guard player.currentTrack == nil else { return }
        let ready = library.myTracks.first { track in
            guard track.kind == .music else { return false }
            if case .ready = track.status, track.stems != nil { return true }
            return false
        }
        if let t = ready { player.load(t) }
    }
}

/// Loading overlay shown while a track's stems are downloading. Sits over
/// the stem stage with a translucent backdrop so the user sees something is
/// happening, plus a determinate progress bar that fills as each of the
/// four stems arrives. Frosted backdrop dims the stale waveform/sphere
/// behind it without nuking layout, so when the bar hits 100% the new
/// track snaps into place under the dissolving overlay.
private struct PreparingOverlay: View {
    let track: Track?
    let progress: Double
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.sand.opacity(0.78).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("loading")
                    .wwavLabel(size: 11, tracking: 2.5)

                ZStack {
                    Circle()
                        .stroke(theme.muted.opacity(0.25), lineWidth: 2)
                        .frame(width: 84, height: 84)
                    Circle()
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(
                            LinearGradient(colors: [theme.accent, theme.clayDeep],
                                           startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 84, height: 84)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.25), value: progress)
                    Text("\(Int(progress * 100))")
                        .font(.wwav(18, weight: .light, italic: true))
                        .foregroundStyle(theme.ink)
                }

                if let title = track?.title {
                    Text(title)
                        .wwavTitle(size: 22)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .lineLimit(2)
                }

                Text("fetching stems · \(stepLabel)")
                    .font(.wwav(11, weight: .light, italic: true))
                    .tracking(1.2)
                    .foregroundStyle(theme.muted)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.muted.opacity(0.20))
                        Capsule()
                            .fill(LinearGradient(colors: [theme.accent, theme.clayDeep],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, geo.size.width * progress))
                            .animation(.easeInOut(duration: 0.25), value: progress)
                    }
                }
                .frame(width: 220, height: 3)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 22).fill(
                    LinearGradient(colors: [theme.sand, theme.sandDeep.opacity(0.85)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(theme.muted.opacity(0.20), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
            .frame(maxWidth: 320)
        }
    }

    private var stepLabel: String {
        // Four stems → break the bar into named milestones so the user
        // sees concrete progress instead of a generic "loading…".
        switch progress {
        case ..<0.26: return "vocals"
        case ..<0.51: return "bass"
        case ..<0.76: return "drums"
        default:      return "synth"
        }
    }
}
