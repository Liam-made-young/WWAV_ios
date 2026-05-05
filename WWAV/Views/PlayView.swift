import AVFoundation
import PhotosUI
import SwiftUI

private enum RemixPanelMode: Equatable {
    case effects
    case time
    case record
}

struct PlayView: View {
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var listener: LiveRadioListener
    @Environment(\.theme) private var theme
    @State private var showingComments = false
    @State private var remixDeckOpen: Bool = false
    @State private var remixPanelMode: RemixPanelMode = .effects
    @State private var selectedRemixStem: StemKind = .vox
    @State private var selectedRemixEffect: StemRemixEffect = .reverb
    @State private var remixStemStatus: [StemKind: PlaybackRemixStemStatus] = PlaybackRemixStemStatus.defaults
    @State private var remixOriginalStemURLs: [StemKind: URL] = [:]
    @StateObject private var remixRecorder = PlaybackRemixRecorder()
    @State private var remixTitle: String = ""
    @State private var remixNotes: String = ""
    @State private var remixCoverItem: PhotosPickerItem?
    @State private var remixCoverImage: UIImage?
    @State private var remixCoverData: Data?
    @State private var remixComposerOpen: Bool = false
    @State private var remixPosting: Bool = false
    @State private var remixPosted: Bool = false
    @State private var remixCompletionMessage: String = ""
    @State private var remixError: String? = nil
    @State private var liveMessageDraft: String = ""

    private var currentMusicTrack: Track? {
        guard let current = player.currentTrack else { return nil }
        return library.feed.first(where: { $0.id == current.id })
            ?? library.myTracks.first(where: { $0.id == current.id })
            ?? current
    }

    private var playbackQueue: [Track] {
        var seen: Set<UUID> = []
        return (library.feed + library.myTracks).filter { track in
            guard isQueuePlayable(track) else { return false }
            guard seen.insert(track.id).inserted else { return false }
            return true
        }
    }

    private var currentPlaybackAlbum: Track? {
        guard let album = nav.albumPlaybackPost,
              let current = currentMusicTrack
        else { return nil }
        let resolved = library.feed.first(where: { $0.id == album.id })
            ?? library.myTracks.first(where: { $0.id == album.id })
            ?? album
        guard library.albumTracks(for: resolved).contains(where: { $0.id == current.id }) else {
            return nil
        }
        return resolved
    }

    private var albumPlaybackQueue: [Track] {
        guard let album = currentPlaybackAlbum else { return [] }
        return library.albumTracks(for: album).filter(isQueuePlayable)
    }

    private var activePlaybackQueue: [Track] {
        let albumQueue = albumPlaybackQueue
        if let current = currentMusicTrack,
           albumQueue.contains(where: { $0.id == current.id }) {
            return albumQueue
        }
        return playbackQueue
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
        .onAppear {
            autoLoadIfNeeded()
            syncLiveTuning()
        }
        .onChange(of: library.myTracks) { _, _ in autoLoadIfNeeded() }
        .onChange(of: nav.tunedInSessionId) { _, _ in
            syncLiveTuning()
        }
        .onChange(of: player.currentTrack?.id) { _, _ in
            resetInlineRemix()
        }
        .onDisappear {
            cancelActiveRemixRecording()
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

                Group {
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                liveMessagePanel
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)

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

    private var liveMessagePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            let recentMessages = Array(listener.messages.suffix(3))
            if !recentMessages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recentMessages) { message in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(message.senderHandle.isEmpty ? message.senderName : "@\(message.senderHandle)")
                                .font(.wwav(10, weight: .medium))
                                .tracking(1)
                                .foregroundStyle(theme.muted)
                                .lineLimit(1)
                            Text(message.text)
                                .font(.wwav(12, weight: .light))
                                .foregroundStyle(theme.ink)
                                .lineLimit(2)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("", text: $liveMessageDraft, prompt: Text("message the dj").foregroundStyle(theme.muted))
                    .font(.wwav(13, weight: .light))
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(theme.sand.opacity(0.68)))
                    .overlay(Capsule().stroke(theme.muted.opacity(0.18), lineWidth: 1))

                Button {
                    sendLiveMessage()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.glow)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(theme.accent))
                }
                .buttonStyle(.plain)
                .disabled(liveMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(liveMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.48 : 1)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.sand.opacity(0.46)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.muted.opacity(0.18), lineWidth: 1))
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

    private func syncLiveTuning() {
        if let sid = nav.tunedInSessionId {
            if player.isPlaying { player.pause() }
            listener.tuneIn(sessionId: sid)
        } else if listener.isTuned {
            listener.tuneOut()
        }
    }

    private func sendLiveMessage() {
        let trimmed = liveMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let senderName = auth.user?.username ?? library.profile.name
        let senderHandle = (auth.user?.username ?? library.profile.handle)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        listener.sendMessage(text: trimmed, fromName: senderName, fromHandle: senderHandle)
        liveMessageDraft = ""
    }

    private var stemBody: some View {
        ZStack {
            theme.centerRadial.ignoresSafeArea()
            if remixDeckOpen {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        if remixPanelMode == .record {
                            remixRecordModePanel
                        }
                        header.padding(.horizontal, 28)
                        titleBlock.padding(.horizontal, 28)
                        if let track = currentMusicTrack {
                            musicSocialPanel(track)
                                .padding(.horizontal, 28)
                        }
                        stemStage
                            .padding(.horizontal, 5)
                        if player.currentTrack != nil {
                            transportControls.padding(.horizontal, 28)
                        }
                        remixDeck
                            .padding(.horizontal, 20)
                            .padding(.top, 4)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            } else {
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
        Text("\(formatTime(player.elapsed))  /  \(formatTime(player.duration))")
            .font(.wwav(10, weight: .light))
            .tracking(1)
            .monospacedDigit()
            .foregroundStyle(theme.muted)
            .lineLimit(1)
            .fixedSize()
    }

    private var transportControls: some View {
        HStack(spacing: 8) {
            skipButton(icon: "backward.end.fill", direction: -1)
            timeLabels
            skipButton(icon: "forward.end.fill", direction: 1)
            Rectangle()
                .fill(theme.muted.opacity(0.16))
                .frame(width: 1, height: 30)
            remixModeButton(.effects)
            remixModeButton(.time)
            remixModeButton(.record)
        }
    }

    private func remixModeButton(_ mode: RemixPanelMode) -> some View {
        let active = remixDeckOpen && remixPanelMode == mode
        let tint: Color = {
            switch mode {
            case .record:  return Color.red.opacity(0.82)
            // Glow is near-white in every palette; using it as the foreground
            // on a sand-tinted capsule made the "time" label invisible. Use
            // clayDeep so the pill reads at a glance against sand.
            case .time:    return theme.clayDeep
            case .effects: return theme.accent
            }
        }()
        let label: String = {
            switch mode {
            case .record:  return "rec"
            case .time:    return "time"
            case .effects: return "fx"
            }
        }()
        let isRecord = mode == .record

        return Button {
            guard let track = currentMusicTrack else { return }
            openInlineRemix(for: track, mode: mode)
        } label: {
            Text(label)
                .font(.wwav(11, weight: .medium, italic: true))
                .foregroundStyle(active ? theme.glow : tint)
                .frame(width: 48, height: 38)
                .background(
                    Capsule()
                        .fill(active ? tint : theme.sand.opacity(0.58))
                )
                .overlay(Capsule().stroke(tint.opacity(active ? 0 : 0.24), lineWidth: 1))
                .shadow(color: active && isRecord ? Color.red.opacity(0.24) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(currentMusicTrack == nil)
        .opacity(currentMusicTrack == nil ? 0.45 : 1)
    }

    private func skipButton(icon: String, direction: Int) -> some View {
        let canSkip = activePlaybackQueue.count > 1
        return Button {
            skipTrack(by: direction)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(canSkip ? theme.ink : theme.muted.opacity(0.45))
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.sand.opacity(0.70)))
                .overlay(Circle().stroke(theme.muted.opacity(WWAVOpacity.soft), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!canSkip)
    }

    private func backToAlbumButton(_ album: Track) -> some View {
        Button {
            nav.albumViewerPost = album
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 11, weight: .medium))
                Text("back to album")
                    .font(.wwav(10, weight: .medium, italic: true))
                    .tracking(1.2)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(theme.sand.opacity(0.68)))
            .overlay(Capsule().stroke(theme.accent.opacity(0.24), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("now playing")
                .wwavLabel(size: 10, tracking: 2)
            Spacer()
            if let track = currentMusicTrack {
                Text(positionLabel(for: track))
                    .font(.wwav(10, weight: .light))
                    .tracking(2)
                    .monospacedDigit()
                    .foregroundStyle(theme.muted)
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(currentMusicTrack?.title ?? "no track loaded")
                    .wwavTitle(size: 36)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                Spacer()
            }
            if let track = currentMusicTrack {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("\(track.artist.lowercased()) — \(track.bio.isEmpty ? "stems ready" : "stems")")
                            .wwavLabel(size: 13, tracking: 2.0)
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)

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

                        Spacer(minLength: 0)
                    }

                    if let album = currentPlaybackAlbum {
                        backToAlbumButton(album)
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

    // MARK: – Inline remix deck

    private var remixDeck: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(theme.muted.opacity(0.18))
                .frame(width: 58, height: 6)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)

            HStack(alignment: .firstTextBaseline) {
                Text(remixDeckTitle)
                    .wwavTitle(size: 24)
                Spacer()
                Button {
                    closeInlineRemix()
                } label: {
                    Text("done")
                        .font(.wwav(12, weight: .light, italic: true))
                        .foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
            }

            switch remixPanelMode {
            case .effects: remixEffectSuite
            case .time:    remixTimeTools
            case .record:  remixRecordTools
            }

            if remixPanelMode != .time {
                if remixComposerOpen {
                    remixComposer
                } else {
                    remixPostToggle
                }
            }

            if let remixError {
                Text(remixError)
                    .font(.wwav(11, weight: .light, italic: true))
                    .foregroundStyle(Color.red.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: WWAVRadius.sheet, style: .continuous)
                .fill(theme.sand.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WWAVRadius.sheet, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.glow.opacity(0.45),
                            theme.muted.opacity(WWAVOpacity.soft),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: theme.clayDeep.opacity(0.12), radius: 24, y: 12)
    }

    private var remixDeckTitle: String {
        switch remixPanelMode {
        case .effects: return "\(selectedRemixStem.label)."
        case .time:    return "time."
        case .record:  return "record mode"
        }
    }

    // MARK: – Time tab (speed / pitch / breakbeat loop)

    private static let beatLoopChoices: [(label: String, beats: Double)] = [
        ("1/32", 1.0 / 32),
        ("1/16", 1.0 / 16),
        ("1/8",  1.0 / 8),
        ("1/4",  1.0 / 4),
        ("1/2",  1.0 / 2),
        ("1",    1),
        ("2",    2),
        ("4",    4)
    ]

    private var remixTimeTools: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("speed · pitch · loop").wwavLabel(size: 9, tracking: 2)
                    .foregroundStyle(theme.muted.opacity(0.78))
                Spacer()
                Button(action: resetTimeTools) {
                    Text("reset")
                        .font(.wwav(11, weight: .medium, italic: true))
                        .foregroundStyle(theme.clayDeep)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.sand.opacity(0.72)))
                        .overlay(Capsule().stroke(theme.muted.opacity(0.28), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!timePanelDirty)
                .opacity(timePanelDirty ? 1 : 0.45)
            }

            timeSliderRow(
                label: "speed",
                value: Binding(
                    get: { player.playbackRate },
                    set: { player.setPlaybackRate($0) }
                ),
                range: 0.5...2.0,
                neutral: 1.0,
                readout: String(format: "%.2f×", player.playbackRate)
            )

            timeSliderRow(
                label: "pitch",
                value: Binding(
                    get: { player.pitchSemitones },
                    set: { player.setPitch($0) }
                ),
                range: -12...12,
                neutral: 0,
                readout: pitchReadout(player.pitchSemitones)
            )

            beatLoopSection
        }
    }

    private func timeSliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        neutral: Double,
        readout: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).wwavLabel(size: 10, tracking: 2.4)
                Spacer()
                Text(readout)
                    .font(.wwav(11, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(theme.muted)
                    .onTapGesture(count: 2) { value.wrappedValue = neutral }
            }
            WWAVSlider(value: value, range: range)
        }
    }

    private func pitchReadout(_ semitones: Double) -> String {
        if abs(semitones) < 0.05 { return "+0 st" }
        let sign = semitones > 0 ? "+" : "−"
        return String(format: "%@%.1f st", sign, abs(semitones))
    }

    private var beatLoopSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("beat loop").wwavLabel(size: 10, tracking: 2.4)
                Spacer()
                bpmField
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                spacing: 10
            ) {
                ForEach(Self.beatLoopChoices.indices, id: \.self) { idx in
                    let choice = Self.beatLoopChoices[idx]
                    beatLoopButton(label: choice.label, beats: choice.beats)
                }
            }

            Text(loopStatusLabel)
                .font(.wwav(10, weight: .light, italic: true))
                .tracking(1.4)
                .foregroundStyle(theme.muted)
        }
    }

    private var bpmField: some View {
        HStack(spacing: 6) {
            Text("bpm").wwavLabel(size: 10, tracking: 2.4)
            TextField(
                "120",
                value: Binding(
                    get: { player.loopBPM },
                    set: { player.setLoopBPM($0) }
                ),
                format: .number.precision(.fractionLength(0))
            )
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.wwav(12, weight: .medium))
            .monospacedDigit()
            .frame(width: 52, height: 30)
            .background(Capsule().fill(theme.sand.opacity(0.62)))
            .overlay(Capsule().stroke(theme.muted.opacity(0.22), lineWidth: 1))
        }
    }

    private func beatLoopButton(label: String, beats: Double) -> some View {
        let active = player.activeLoopBeats == beats
        return Button {
            if active {
                player.disableLoop()
            } else {
                player.enableLoop(beats: beats, bpm: player.loopBPM)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        active
                            ? RadialGradient(
                                colors: [theme.glow.opacity(0.96), theme.accent.opacity(0.72)],
                                center: .center, startRadius: 0, endRadius: 32
                            )
                            : RadialGradient(
                                colors: [theme.sand.opacity(0.74), theme.sand.opacity(0.40)],
                                center: .center, startRadius: 0, endRadius: 32
                            )
                    )
                Circle()
                    .stroke(
                        active ? theme.accent.opacity(0.55) : theme.muted.opacity(0.24),
                        lineWidth: 1
                    )
                Text(label)
                    .font(.wwav(12, weight: active ? .semibold : .light, italic: true))
                    .foregroundStyle(active ? theme.ink : theme.muted)
            }
            .frame(height: 56)
            .shadow(color: active ? theme.glow.opacity(0.32) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(player.currentTrack == nil)
    }

    private var loopStatusLabel: String {
        guard let beats = player.activeLoopBeats else { return "free play" }
        let seconds = beats * 60.0 / max(40, player.loopBPM)
        let beatsLabel = beats >= 1
            ? String(format: "%.0f beat%@", beats, beats == 1 ? "" : "s")
            : "\(formatBeatFraction(beats)) beat"
        return String(format: "looping %@ · %.2fs region", beatsLabel, seconds)
    }

    private func formatBeatFraction(_ beats: Double) -> String {
        for choice in Self.beatLoopChoices where abs(choice.beats - beats) < 1e-6 {
            return choice.label
        }
        return String(format: "%.3f", beats)
    }

    private var timePanelDirty: Bool {
        abs(player.playbackRate - 1.0) > 0.001
            || abs(player.pitchSemitones) > 0.001
            || player.activeLoopBeats != nil
            || abs(player.loopBPM - 120) > 0.001
    }

    private func resetTimeTools() {
        player.disableLoop()
        player.resetTimeAndPitch()
        player.setLoopBPM(120)
    }

    private var remixRecordModePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text("record mode").wwavLabel(size: 11, tracking: 3)
                    .foregroundStyle(theme.glow.opacity(0.78))
                Spacer()
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<12, id: \.self) { index in
                        let active = remixRecorder.isRecording && index > 8
                        Capsule()
                            .fill(active ? Color.red.opacity(0.78) : theme.accent.opacity(index < 9 ? 0.40 : 0.20))
                            .frame(width: 4, height: CGFloat(10 + (index % 6) * 5))
                    }
                }
            }

            HStack(spacing: 14) {
                ForEach(StemKind.allCases) { kind in
                    recordStemArm(kind)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 18)
        .background(
            LinearGradient(
                colors: [theme.clayDeep.opacity(0.55), theme.clay.opacity(0.32)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func recordStemArm(_ kind: StemKind) -> some View {
        let selected = selectedRemixStem == kind
        let active = remixRecorder.isRecording && remixRecorder.activeStem == kind
        return Button {
            selectedRemixStem = kind
            remixError = nil
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            selected
                                ? AnyShapeStyle(RadialGradient(
                                    colors: [
                                        Color.red.opacity(active ? 0.62 : 0.48),
                                        Color.red.opacity(active ? 0.32 : 0.20),
                                    ],
                                    center: .center,
                                    startRadius: 1,
                                    endRadius: 38
                                ))
                                : AnyShapeStyle(theme.glow.opacity(0.08))
                        )
                        .overlay(
                            Circle().stroke(
                                selected
                                    ? Color.red.opacity(active ? 0.55 : 0.38)
                                    : theme.glow.opacity(WWAVOpacity.soft),
                                lineWidth: selected ? 1 : 1
                            )
                        )
                    Circle()
                        .fill(active ? theme.glow : (selected ? theme.glow.opacity(0.95) : Color.red.opacity(0.58)))
                        .frame(width: selected ? 14 : 12, height: selected ? 14 : 12)
                }
                .frame(width: selected ? 68 : 56, height: selected ? 68 : 56)
                .background {
                    if selected {
                        ZStack {
                            Rectangle()
                                .fill(Color.red.opacity(0.10))
                            Rectangle()
                                .fill(theme.glow.opacity(0.05))
                        }
                        .frame(width: 96, height: 92)
                    }
                }

                Text(kind.label)
                    .font(.wwav(11, weight: .light))
                    .tracking(1.5)
                    .foregroundStyle(theme.glow.opacity(selected ? 0.92 : 0.62))

                Text("OD")
                    .font(.wwav(9, weight: .light))
                    .tracking(1)
                    .foregroundStyle(remixStemStatus[kind] == .overdub ? theme.glow : theme.glow.opacity(0.50))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(
                            remixStemStatus[kind] == .overdub
                                ? theme.accent.opacity(0.46)
                                : theme.glow.opacity(0.06)
                        )
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            LinearGradient(
                                colors: [
                                    theme.glow.opacity(0.45),
                                    theme.muted.opacity(WWAVOpacity.soft),
                                ],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    )
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var activeRecordingLabel: String {
        guard let stem = remixRecorder.activeStem, let mode = remixRecorder.mode else {
            return "recording"
        }
        return "\(mode.label) \(stem.label) @ \(formatTime(remixRecorder.startTime))"
    }

    private var remixStemSelector: some View {
        HStack(spacing: 7) {
            ForEach(StemKind.allCases) { kind in
                Button {
                    selectedRemixStem = kind
                    remixError = nil
                } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 4) {
                            Image(systemName: remixStatusIcon(for: kind))
                                .font(.system(size: 10, weight: .semibold))
                            Text(kind.label)
                                .font(.wwav(11, weight: .medium))
                                .tracking(0.8)
                                .lineLimit(1)
                        }
                        Capsule()
                            .fill(remixStatusColor(for: kind).opacity(selectedRemixStem == kind ? 1 : 0.42))
                            .frame(height: 3)
                    }
                    .foregroundStyle(selectedRemixStem == kind ? theme.ink : theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedRemixStem == kind ? theme.glow.opacity(0.34) : theme.muted.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selectedRemixStem == kind ? theme.accent.opacity(0.38) : theme.muted.opacity(0.14), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var remixRecordTools: some View {
        let isReplace = remixRecorder.isRecording
            && remixRecorder.activeStem == selectedRemixStem
            && remixRecorder.mode == .replace
        let isOverdub = remixRecorder.isRecording
            && remixRecorder.activeStem == selectedRemixStem
            && remixRecorder.mode == .overdub

        return VStack(alignment: .leading, spacing: 14) {
            remixStemSelector

            if remixRecorder.isRecording {
                Text(activeRecordingLabel)
                    .font(.wwav(12, weight: .light, italic: true))
                    .foregroundStyle(Color.red.opacity(0.86))
            } else {
                Text("arm a stem, then choose record-over or overdub.")
                    .font(.wwav(12, weight: .light, italic: true))
                    .foregroundStyle(theme.muted)
            }

            HStack(spacing: 9) {
                remixToolButton(
                    icon: isReplace ? "stop.fill" : "record.circle",
                    label: isReplace ? "stop" : "record over",
                    active: isReplace,
                    tint: isReplace ? Color.red.opacity(0.84) : Color.red.opacity(0.78)
                ) {
                    toggleRemixRecording(.replace)
                }

                remixToolButton(
                    icon: isOverdub ? "stop.fill" : "mic.badge.plus",
                    label: isOverdub ? "stop" : "overdub",
                    active: isOverdub,
                    tint: isOverdub ? Color.red.opacity(0.84) : theme.accent
                ) {
                    toggleRemixRecording(.overdub)
                }

                remixToolButton(
                    icon: "arrow.counterclockwise",
                    label: "reset",
                    active: false,
                    tint: theme.muted
                ) {
                    resetSelectedStem()
                }
                .disabled(remixRecorder.isRecording)
                .opacity(remixRecorder.isRecording ? 0.45 : 1)
            }
        }
    }

    private var remixEffectSuite: some View {
        VStack(alignment: .leading, spacing: 10) {
            remixStemSelector

            HStack(spacing: 10) {
                ForEach([StemRemixEffect.reverb, .delay, .distortion, .tremolo]) { effect in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            selectedRemixEffect = effect
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: effect.icon)
                                .font(.system(size: 11, weight: .semibold))
                            Text(effectDisplayName(effect))
                                .font(.wwav(12, weight: .light, italic: true))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selectedRemixEffect == effect ? theme.glow : theme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(
                                selectedRemixEffect == effect
                                    ? AnyShapeStyle(theme.accent)
                                    : AnyShapeStyle(theme.sand.opacity(WWAVOpacity.firm))
                            )
                        )
                        .overlay(Capsule().stroke(theme.muted.opacity(WWAVOpacity.soft), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(effectDescription(selectedRemixEffect))
                .font(.wwav(12, weight: .light, italic: true))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.glow.opacity(0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.muted.opacity(WWAVOpacity.hair), lineWidth: 1)
                )

            HStack {
                Text("\(effectDisplayName(selectedRemixEffect)) — dry / wet mix")
                    .wwavLabel(size: 10, tracking: 2)
                Spacer()
                Button {
                    for kind in StemKind.allCases {
                        player.setEffect(selectedRemixEffect, value: 0, for: kind)
                        updateEffectStatus(for: kind)
                    }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.muted)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(theme.muted.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }

            ForEach(StemKind.allCases) { kind in
                effectStemMixRow(kind, effect: selectedRemixEffect)
            }
        }
    }

    private func effectStemMixRow(_ kind: StemKind, effect: StemRemixEffect) -> some View {
        HStack(spacing: 10) {
            Text(kind.label)
                .font(.wwav(13, weight: .light, italic: true))
                .foregroundStyle(theme.ink)
                .frame(width: 48, alignment: .leading)
            WWAVSlider(
                value: Binding(
                    get: { player.effectValue(effect, for: kind) },
                    set: { newValue in
                        player.setEffect(effect, value: newValue, for: kind)
                        updateEffectStatus(for: kind)
                    }
                )
            )
            VStack(spacing: 0) {
                Text("dry")
                Text("wet")
            }
            .font(.wwav(8, weight: .light))
            .foregroundStyle(theme.muted)
            .frame(width: 26)
        }
    }

    private func effectDisplayName(_ effect: StemRemixEffect) -> String {
        switch effect {
        case .distortion: return "Distort"
        case .delay: return "Delay"
        case .reverb: return "Reverb"
        case .tremolo: return "Tremolo"
        }
    }

    private func effectDescription(_ effect: StemRemixEffect) -> String {
        switch effect {
        case .distortion: return "Color and grit — drag right to push the signal into rougher edges."
        case .delay: return "Echo repeats — drag right to send the stem further down the line."
        case .reverb: return "Room ambience — drag right to push the signal deeper into space."
        case .tremolo: return "Movement pulse — drag right to make the stem breathe and shimmer."
        }
    }

    private func remixToolButton(
        icon: String,
        label: String,
        active: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.wwav(11, weight: .medium, italic: true))
                    .tracking(0.9)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? theme.glow : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? tint : tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(active ? 0 : 0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var remixPostToggle: some View {
        Button {
            remixComposerOpen = true
            remixError = nil
        } label: {
            HStack(spacing: 7) {
                Image(systemName: remixPosted ? "checkmark" : "arrow.up.forward")
                    .font(.system(size: 12, weight: .semibold))
                Text(remixPosted ? remixCompletionMessage : "finish remix")
                    .font(.wwav(14, weight: .regular, italic: true))
                    .tracking(1.2)
            }
            .foregroundStyle(theme.glow)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: WWAVRadius.button)
                    .fill(LinearGradient(colors: [theme.clay, theme.clayDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: WWAVRadius.button)
                    .strokeBorder(
                        LinearGradient(
                            colors: [theme.glow.opacity(0.30), Color.clear],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: theme.clayDeep.opacity(0.30), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(remixRecorder.isRecording || remixPosted)
        .opacity(remixRecorder.isRecording ? 0.45 : 1)
    }

    private var remixComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("remix destination").wwavLabel(size: 10, tracking: 2.0)
            remixCoverPicker

            TextField("", text: $remixTitle, prompt: Text("remix title").foregroundStyle(theme.muted))
                .font(.wwav(18, weight: .light, italic: true))
                .foregroundStyle(theme.ink)
                .padding(.vertical, 8)
                .overlay(Rectangle().fill(theme.muted.opacity(0.25)).frame(height: 1), alignment: .bottom)

            TextEditor(text: $remixNotes)
                .scrollContentBackground(.hidden)
                .font(.wwav(13, weight: .light))
                .foregroundStyle(theme.ink)
                .frame(minHeight: 58, maxHeight: 92)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.muted.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.muted.opacity(0.16), lineWidth: 1))

            VStack(spacing: 10) {
                inlineRemixSubmitButton("save to library", publication: .draft, filled: false)
                inlineRemixSubmitButton("post to feed", publication: .published, filled: true)
            }
        }
    }

    private func inlineRemixSubmitButton(
        _ label: String,
        publication: PublicationState,
        filled: Bool
    ) -> some View {
        Button {
            submitInlineRemix(publication: publication)
        } label: {
            HStack(spacing: 7) {
                if remixPosting {
                    ProgressView()
                        .tint(filled ? theme.glow : theme.accent)
                        .scaleEffect(0.72)
                } else if remixPosted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                } else if filled {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(remixPosted ? remixCompletionMessage : remixPosting ? "working" : label)
                    .font(.wwav(14, weight: .regular, italic: true))
                    .tracking(1.2)
            }
            .foregroundStyle(filled ? theme.glow : theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        filled
                            ? AnyShapeStyle(LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            : AnyShapeStyle(theme.sand.opacity(0.62))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.accent.opacity(filled ? 0 : 0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(remixPosting || remixPosted || remixRecorder.isRecording)
        .opacity(remixPosting || remixRecorder.isRecording ? 0.62 : 1)
    }

    private var remixCoverPicker: some View {
        PhotosPicker(selection: $remixCoverItem, matching: .images, photoLibrary: .shared()) {
            HStack(spacing: 12) {
                ZStack {
                    if let remixCoverImage {
                        Image(uiImage: remixCoverImage)
                            .resizable()
                            .scaledToFill()
                    } else if let inherited = currentMusicTrack?.coverImageURL {
                        CachedAsyncImage(url: inherited) {
                            Image(systemName: "photo")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(theme.muted)
                        }
                    } else {
                        LinearGradient(
                            colors: [theme.clay.opacity(0.22), theme.clayDeep.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "photo")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(theme.muted)
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.muted.opacity(0.22), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(remixCoverImage == nil ? "cover art" : "new cover selected")
                        .font(.wwav(13, weight: .medium, italic: true))
                        .foregroundStyle(theme.ink)
                    Text(remixCoverImage == nil ? "tap to change the remix cover" : "tap again to replace it")
                        .font(.wwav(11, weight: .light))
                        .foregroundStyle(theme.muted)
                }
                Spacer(minLength: 0)

                if remixCoverImage != nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.muted.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.muted.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onChange(of: remixCoverItem) { _, newItem in
            Task { await loadRemixCover(from: newItem) }
        }
    }

    private func toggleInlineRemix(for track: Track) {
        if remixDeckOpen {
            closeInlineRemix()
        } else {
            openInlineRemix(for: track, mode: .effects)
        }
    }

    private func openInlineRemix(for track: Track, mode: RemixPanelMode) {
        remixPanelMode = mode
        if remixDeckOpen {
            remixError = nil
            return
        }

        remixDeckOpen = true
        selectedRemixStem = .vox
        selectedRemixEffect = .reverb
        remixTitle = "remix of \(track.title)"
        remixNotes = ""
        resetRemixCover()
        remixComposerOpen = false
        remixPosting = false
        remixPosted = false
        remixCompletionMessage = ""
        remixError = nil
        remixStemStatus = PlaybackRemixStemStatus.defaults
        remixOriginalStemURLs = StemKind.allCases.reduce(into: [:]) { result, kind in
            if let url = player.currentStemURL(for: kind) ?? track.stems?.url(for: kind) {
                result[kind] = url
            }
        }
        player.resetAllEffects()
    }

    private func closeInlineRemix() {
        cancelActiveRemixRecording()
        restoreOriginalRemixStems()
        remixDeckOpen = false
        remixPanelMode = .effects
        remixComposerOpen = false
        remixPosting = false
        remixCompletionMessage = ""
        remixError = nil
        resetRemixCover()
    }

    private func resetInlineRemix() {
        cancelActiveRemixRecording()
        remixDeckOpen = false
        remixPanelMode = .effects
        remixComposerOpen = false
        remixPosting = false
        remixPosted = false
        remixCompletionMessage = ""
        remixError = nil
        resetRemixCover()
        remixStemStatus = PlaybackRemixStemStatus.defaults
        remixOriginalStemURLs = [:]
        player.resetAllEffects()
    }

    private func cancelActiveRemixRecording() {
        guard remixRecorder.isRecording else { return }
        if let stem = remixRecorder.activeStem {
            player.setStemMonitoringMuted(false, for: stem)
        }
        remixRecorder.cancel()
    }

    private func toggleRemixRecording(_ mode: PlaybackRemixRecordingMode) {
        if remixRecorder.isRecording {
            stopRemixRecording()
        } else {
            startRemixRecording(mode)
        }
    }

    private func startRemixRecording(_ mode: PlaybackRemixRecordingMode) {
        guard currentMusicTrack != nil else { return }
        let stem = selectedRemixStem
        let startTime = player.elapsed
        let sampleRate = sampleRateForCurrentStem(stem) ?? 44_100
        remixError = nil

        Task {
            do {
                _ = try await remixRecorder.start(
                    stem: stem,
                    mode: mode,
                    startTime: startTime,
                    sampleRate: sampleRate
                )
                if mode == .replace {
                    player.setStemMonitoringMuted(true, for: stem)
                }
                if !player.isPlaying {
                    player.resume()
                }
            } catch {
                remixError = error.localizedDescription
                player.setStemMonitoringMuted(false, for: stem)
            }
        }
    }

    private func stopRemixRecording() {
        guard let take = remixRecorder.stop() else { return }
        player.setStemMonitoringMuted(false, for: take.stem)
        remixError = nil

        let sourceURL = player.currentStemURL(for: take.stem)
            ?? remixOriginalStemURLs[take.stem]
        guard let sourceURL else {
            remixError = "missing source stem"
            return
        }

        Task {
            do {
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try PlaybackRemixRenderer.spliceTake(
                        sourceURL: sourceURL,
                        takeURL: take.url,
                        startTime: take.startTime,
                        mode: take.mode
                    )
                }.value
                try player.replaceStem(take.stem, with: rendered)
                remixStemStatus[take.stem] = take.mode == .replace ? .recorded : .overdub
            } catch {
                remixError = "couldn't place take: \(error.localizedDescription)"
            }
        }
    }

    private func resetSelectedStem() {
        guard let original = remixOriginalStemURLs[selectedRemixStem] else { return }
        do {
            try player.replaceStem(selectedRemixStem, with: original)
            player.resetEffects(for: selectedRemixStem)
            remixStemStatus[selectedRemixStem] = .original
            remixError = nil
        } catch {
            remixError = "couldn't reset stem"
        }
    }

    private func restoreOriginalRemixStems() {
        for kind in StemKind.allCases {
            player.setStemMonitoringMuted(false, for: kind)
            if let original = remixOriginalStemURLs[kind] {
                try? player.replaceStem(kind, with: original)
            }
            player.resetEffects(for: kind)
        }
        remixStemStatus = PlaybackRemixStemStatus.defaults
    }

    private func submitInlineRemix(publication: PublicationState) {
        guard !remixPosting, let track = currentMusicTrack else { return }
        cancelActiveRemixRecording()
        remixPosting = true
        remixError = nil

        let title = remixTitle
        let notes = remixNotes
        let coverData = remixCoverData
        let token = auth.token
        let baseURLs = StemKind.allCases.reduce(into: [StemKind: URL]()) { result, kind in
            if let url = player.currentStemURL(for: kind)
                ?? remixOriginalStemURLs[kind]
                ?? track.stems?.url(for: kind) {
                result[kind] = url
            }
        }
        let effectStates = StemKind.allCases.reduce(into: [StemKind: StemEffectState]()) { result, kind in
            result[kind] = player.effectState(for: kind)
        }

        Task {
            do {
                var finalStems: [StemKind: URL] = [:]
                for kind in StemKind.allCases {
                    guard let source = baseURLs[kind] else { continue }
                    let state = effectStates[kind] ?? .zero
                    if state.hasActiveEffects {
                        let rendered = try await Task.detached(priority: .userInitiated) {
                            try PlaybackRemixRenderer.renderEffects(sourceURL: source, effects: state)
                        }.value
                        finalStems[kind] = rendered
                    } else {
                        finalStems[kind] = source
                    }
                }
                guard StemKind.allCases.allSatisfy({ finalStems[$0] != nil }) else {
                    throw PlaybackRemixRenderError.unreadableAudio
                }

                library.createRemix(
                    parent: track,
                    title: title,
                    bio: notes,
                    newStems: finalStems,
                    cover: coverData,
                    token: token,
                    publication: publication
                )

                remixPosting = false
                remixPosted = true
                remixCompletionMessage = publication == .published ? "posted" : "saved"
                remixComposerOpen = false
            } catch {
                remixPosting = false
                remixError = "couldn't finish remix: \(error.localizedDescription)"
            }
        }
    }

    private func loadRemixCover(from item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            let jpeg = image.jpegData(compressionQuality: 0.86) ?? data
            await MainActor.run {
                remixCoverImage = image
                remixCoverData = jpeg
            }
        }
    }

    private func resetRemixCover() {
        remixCoverItem = nil
        remixCoverImage = nil
        remixCoverData = nil
    }

    private func sampleRateForCurrentStem(_ kind: StemKind) -> Double? {
        guard let url = player.currentStemURL(for: kind) ?? remixOriginalStemURLs[kind],
              let file = try? AVAudioFile(forReading: url)
        else { return nil }
        return file.processingFormat.sampleRate
    }

    private func updateEffectStatus(for kind: StemKind) {
        let active = player.effectState(for: kind).hasActiveEffects
        if active {
            if remixStemStatus[kind] == .original {
                remixStemStatus[kind] = .effected
            }
        } else if remixStemStatus[kind] == .effected {
            remixStemStatus[kind] = .original
        }
    }

    private func remixStatusIcon(for kind: StemKind) -> String {
        switch remixStemStatus[kind] ?? .original {
        case .original: return "circle"
        case .recorded: return "mic.fill"
        case .overdub: return "plus.circle.fill"
        case .effected: return "slider.horizontal.3"
        }
    }

    private func remixStatusColor(for kind: StemKind) -> Color {
        switch remixStemStatus[kind] ?? .original {
        case .original: return theme.muted
        case .recorded: return Color.red.opacity(0.78)
        case .overdub: return theme.accent
        case .effected: return theme.clayDeep
        }
    }

    private func positionLabel(for track: Track) -> String {
        let queue = activePlaybackQueue
        guard let idx = queue.firstIndex(where: { $0.id == track.id }) else { return "" }
        let total = queue.count
        return String(format: "%02d / %02d", idx + 1, total)
    }

    private func formatTime(_ s: Double) -> String {
        let total = max(0, Int(s))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func skipTrack(by direction: Int) {
        guard let current = currentMusicTrack else { return }
        let queue = activePlaybackQueue
        guard queue.count > 1,
              let index = queue.firstIndex(where: { $0.id == current.id }) else { return }
        let nextIndex = (index + direction + queue.count) % queue.count
        nav.openPost(queue[nextIndex], in: library, with: player, albumContext: currentPlaybackAlbum)
    }

    private func isQueuePlayable(_ track: Track) -> Bool {
        guard track.kind == .music else { return false }
        if case .ready = track.status { return true }
        return false
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

private enum PlaybackRemixStemStatus {
    case original
    case recorded
    case overdub
    case effected

    static var defaults: [StemKind: PlaybackRemixStemStatus] {
        Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, .original) })
    }
}

private enum PlaybackRemixRecordingMode: Sendable {
    case replace
    case overdub

    var label: String {
        switch self {
        case .replace: return "replace"
        case .overdub: return "overdub"
        }
    }
}

private struct PlaybackRemixTake: Sendable {
    let stem: StemKind
    let mode: PlaybackRemixRecordingMode
    let startTime: Double
    let url: URL
}

@MainActor
private final class PlaybackRemixRecorder: ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var activeStem: StemKind?
    @Published private(set) var mode: PlaybackRemixRecordingMode?
    @Published private(set) var startTime: Double = 0

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func start(
        stem: StemKind,
        mode: PlaybackRemixRecordingMode,
        startTime: Double,
        sampleRate: Double
    ) async throws -> URL {
        guard !isRecording else { throw PlaybackRemixRenderError.alreadyRecording }
        guard await requestMicPermission() else { throw PlaybackRemixRenderError.microphoneDenied }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback_remix_take_\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let rec = try AVAudioRecorder(url: tmp, settings: settings)
        rec.prepareToRecord()
        rec.record()

        recorder = rec
        recordingURL = tmp
        activeStem = stem
        self.mode = mode
        self.startTime = startTime
        isRecording = true
        return tmp
    }

    func stop() -> PlaybackRemixTake? {
        guard isRecording,
              let stem = activeStem,
              let mode,
              let url = recordingURL
        else { return nil }

        recorder?.stop()
        restorePlaybackSession()

        recorder = nil
        recordingURL = nil
        activeStem = nil
        self.mode = nil
        isRecording = false

        return PlaybackRemixTake(stem: stem, mode: mode, startTime: startTime, url: url)
    }

    func cancel() {
        recorder?.stop()
        restorePlaybackSession()
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recorder = nil
        recordingURL = nil
        activeStem = nil
        mode = nil
        isRecording = false
    }

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func restorePlaybackSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

private enum PlaybackRemixRenderError: LocalizedError {
    case alreadyRecording
    case microphoneDenied
    case unreadableAudio
    case converterFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "already recording"
        case .microphoneDenied: return "microphone permission is needed to record"
        case .unreadableAudio: return "couldn't read that audio"
        case .converterFailed: return "couldn't convert that audio"
        }
    }
}

private enum PlaybackRemixRenderer {
    static func spliceTake(
        sourceURL: URL,
        takeURL: URL,
        startTime: Double,
        mode: PlaybackRemixRecordingMode
    ) throws -> URL {
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let format = workingFormat(from: sourceFile)
        let source = try convertedBuffer(readBuffer(from: sourceFile), to: format)

        let takeFile = try AVAudioFile(forReading: takeURL)
        let take = try convertedBuffer(readBuffer(from: takeFile), to: format)

        let output = try copyBuffer(source, format: format)
        guard let outputData = output.floatChannelData,
              let sourceData = source.floatChannelData,
              let takeData = take.floatChannelData
        else { throw PlaybackRemixRenderError.unreadableAudio }

        let channelCount = Int(format.channelCount)
        let sourceFrames = Int(output.frameLength)
        let takeFrames = Int(take.frameLength)
        let startFrame = min(max(0, Int(startTime * format.sampleRate)), sourceFrames)
        let writableFrames = max(0, min(takeFrames, sourceFrames - startFrame))

        guard writableFrames > 0 else {
            return try writeBuffer(output, format: format, prefix: "playback_remix_empty")
        }

        for channel in 0..<channelCount {
            let out = outputData[channel]
            let src = sourceData[channel]
            let mic = takeData[channel]
            for frame in 0..<writableFrames {
                let index = startFrame + frame
                let dry = src[index]
                let wet = mic[frame]
                switch mode {
                case .replace:
                    out[index] = clipped(wet)
                case .overdub:
                    out[index] = clipped(dry * 0.82 + wet * 0.72)
                }
            }
        }

        return try writeBuffer(output, format: format, prefix: "playback_remix_take")
    }

    static func renderEffects(sourceURL: URL, effects: StemEffectState) throws -> URL {
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let format = workingFormat(from: sourceFile)
        let source = try convertedBuffer(readBuffer(from: sourceFile), to: format)
        let output = try copyBuffer(source, format: format)
        try applyEffects(effects, to: output, format: format)
        return try writeBuffer(output, format: format, prefix: "playback_remix_fx")
    }

    private static func workingFormat(from file: AVAudioFile) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.processingFormat.sampleRate,
            channels: file.processingFormat.channelCount,
            interleaved: false
        )!
    }

    private static func readBuffer(from file: AVAudioFile) throws -> AVAudioPCMBuffer {
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              )
        else { throw PlaybackRemixRenderError.unreadableAudio }
        try file.read(into: buffer)
        return buffer
    }

    private static func convertedBuffer(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if formatsMatch(input.format, format) {
            return input
        }

        guard let converter = AVAudioConverter(from: input.format, to: format),
              let output = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 1024
              )
        else { throw PlaybackRemixRenderError.converterFailed }

        var didFeedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if didFeedInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            didFeedInput = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error {
            throw conversionError ?? PlaybackRemixRenderError.converterFailed
        }
        return output
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private static func copyBuffer(_ source: AVAudioPCMBuffer, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength),
              let sourceData = source.floatChannelData,
              let outputData = output.floatChannelData
        else { throw PlaybackRemixRenderError.unreadableAudio }

        output.frameLength = source.frameLength
        for channel in 0..<Int(format.channelCount) {
            outputData[channel].update(from: sourceData[channel], count: Int(source.frameLength))
        }
        return output
    }

    private static func applyEffects(
        _ effects: StemEffectState,
        to buffer: AVAudioPCMBuffer,
        format: AVAudioFormat
    ) throws {
        guard let data = buffer.floatChannelData else { throw PlaybackRemixRenderError.unreadableAudio }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)

        if effects.distortion > 0.001 {
            let drive = Float(1 + effects.distortion * 24)
            let norm = Float(tanh(Double(drive)))
            for channel in 0..<channels {
                let samples = data[channel]
                for i in 0..<frames {
                    samples[i] = clipped(Float(tanh(Double(samples[i] * drive))) / max(0.001, norm))
                }
            }
        }

        if effects.tremolo > 0.001 {
            let depth = Float(effects.tremolo * 0.86)
            let rate = Float(3.5 + effects.tremolo * 5.5)
            for channel in 0..<channels {
                let samples = data[channel]
                for i in 0..<frames {
                    let t = Float(i) / Float(format.sampleRate)
                    let lfo = (sin(t * rate * 2 * .pi) + 1) * 0.5
                    samples[i] = clipped(samples[i] * (1 - depth * lfo))
                }
            }
        }

        if effects.delay > 0.001 {
            applyDelay(
                to: data,
                channels: channels,
                frames: frames,
                sampleRate: format.sampleRate,
                amount: effects.delay
            )
        }

        if effects.reverb > 0.001 {
            applyReverb(
                to: data,
                channels: channels,
                frames: frames,
                sampleRate: format.sampleRate,
                amount: effects.reverb
            )
        }
    }

    private static func applyDelay(
        to data: UnsafePointer<UnsafeMutablePointer<Float>>,
        channels: Int,
        frames: Int,
        sampleRate: Double,
        amount: Double
    ) {
        let delayFrames = max(1, Int((0.08 + amount * 0.46) * sampleRate))
        let wet = Float(0.16 + amount * 0.42)
        let feedback = Float(0.14 + amount * 0.46)

        for channel in 0..<channels {
            let samples = data[channel]
            var line = [Float](repeating: 0, count: delayFrames)
            var index = 0
            for frame in 0..<frames {
                let dry = samples[frame]
                let delayed = line[index]
                samples[frame] = clipped(dry + delayed * wet)
                line[index] = clipped(dry + delayed * feedback)
                index = (index + 1) % delayFrames
            }
        }
    }

    private static func applyReverb(
        to data: UnsafePointer<UnsafeMutablePointer<Float>>,
        channels: Int,
        frames: Int,
        sampleRate: Double,
        amount: Double
    ) {
        let taps = [0.029, 0.037, 0.043, 0.053].map { max(1, Int($0 * sampleRate)) }
        let wet = Float(0.10 + amount * 0.30)
        let feedback = Float(0.18 + amount * 0.34)

        for channel in 0..<channels {
            let samples = data[channel]
            var lines = taps.map { [Float](repeating: 0, count: $0) }
            var indices = taps.map { _ in 0 }

            for frame in 0..<frames {
                let dry = samples[frame]
                var sum: Float = 0
                for i in lines.indices {
                    let delayed = lines[i][indices[i]]
                    sum += delayed
                    lines[i][indices[i]] = clipped(dry + delayed * feedback)
                    indices[i] = (indices[i] + 1) % lines[i].count
                }
                samples[frame] = clipped(dry + (sum / Float(lines.count)) * wet)
            }
        }
    }

    private static func writeBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat, prefix: String) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        return outputURL
    }

    private static func clipped(_ value: Float) -> Float {
        min(1, max(-1, value))
    }
}
