import SwiftUI

struct PlayView: View {
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.theme) private var theme
    @State private var showingRemix: Bool = false

    var body: some View {
        Group {
            if let post = nav.activePost, post.kind == .video {
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

    private var stemBody: some View {
        ZStack {
            theme.centerRadial.ignoresSafeArea()
            VStack(spacing: 12) {
                header.padding(.horizontal, 28)
                titleBlock.padding(.horizontal, 28)
                Spacer(minLength: 8)
                stemStage
                Spacer(minLength: 8)
                if player.currentTrack != nil {
                    timeLabels.padding(.horizontal, 28)
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

    private var header: some View {
        HStack {
            Text("now playing").wwavLabel()
            Spacer()
            if let track = player.currentTrack {
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
                Text(player.currentTrack?.title ?? "no track loaded")
                    .wwavTitle(size: 46)
                    .lineLimit(1)
                Spacer()
            }
            if let track = player.currentTrack {
                HStack(spacing: 8) {
                    Text("\(track.artist.lowercased()) — \(track.bio.isEmpty ? "stems ready" : "stems")")
                        .wwavLabel(size: 13, tracking: 1.5)
                        .foregroundStyle(theme.muted)

                    if track.isRemix {
                        // Remix badge
                        Text("remix")
                            .font(.wwav(9, weight: .medium))
                            .tracking(1.2)
                            .foregroundStyle(theme.glow)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.accent))

                        // Genealogy button — opens the parent track
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

            // Music social action row with remix button
            if let track = player.currentTrack, track.kind == .music {
                musicSocialPanel(track)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func musicSocialPanel(_ track: Track) -> some View {
        HStack(spacing: 14) {
            // Remix button
            Button {
                showingRemix = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 13, weight: .regular))
                    Text("remix")
                        .font(.wwav(11, weight: .light))
                        .tracking(1)
                }
                .foregroundStyle(theme.accent)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(
                    Capsule().fill(theme.accent.opacity(0.12))
                )
                .overlay(Capsule().stroke(theme.accent.opacity(0.30), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.top, 4)
    }

    private func positionLabel(for track: Track) -> String {
        let musicTracks = library.myTracks.filter { $0.kind == .music }
        guard let idx = musicTracks.firstIndex(of: track) else { return "" }
        let total = musicTracks.count
        return String(format: "%02d / %02d", idx + 1, total)
    }

    private func formatTime(_ s: Double) -> String {
        let total = max(0, Int(s))
        return String(format: "%d:%02d", total / 60, total % 60)
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
