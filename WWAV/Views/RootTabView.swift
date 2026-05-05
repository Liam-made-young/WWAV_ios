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
                    case .play:    PlayView()
                    case .plus:    UploadView()
                    case .profile: ProfileView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !nav.hidesTabBar {
                    TabBar(active: $nav.active) {
                        nav.homeFeedPing &+= 1
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: nav.hidesTabBar)
        .sheet(item: $nav.publicProfile) { route in
            PublicProfileSheet(route: route)
        }
        .fullScreenCover(item: $nav.albumViewerPost) { album in
            AlbumDetailView(album: album)
        }
    }
}

struct AlbumDetailView: View {
    let album: Track

    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private var currentAlbum: Track {
        library.feed.first(where: { $0.id == album.id })
            ?? library.myTracks.first(where: { $0.id == album.id })
            ?? album
    }

    private var tracks: [Track] {
        library.albumTracks(for: currentAlbum)
    }

    private var playableTracks: [Track] {
        tracks.filter(isPlayable)
    }

    private var albumIsActive: Bool {
        guard let current = player.currentTrack else { return false }
        return tracks.contains(where: { $0.id == current.id })
    }

    private var totalDurationLabel: String {
        let seconds = Int(tracks.reduce(0) { $0 + $1.durationSeconds })
        guard seconds > 0 else { return "\(tracks.count) tracks" }
        let minutes = max(1, Int(round(Double(seconds) / 60.0)))
        return "\(tracks.count) tracks · \(minutes)m"
    }

    var body: some View {
        ZStack {
            theme.pageRadial.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    topBar
                    hero

                    if !currentAlbum.bio.isEmpty {
                        Text(currentAlbum.bio)
                            .font(.wwav(14, weight: .light))
                            .foregroundStyle(theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    trackList
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                nav.albumViewerPost = nil
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(theme.sand.opacity(0.70)))
                    .overlay(Circle().stroke(theme.muted.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("album").wwavLabel(size: 9, tracking: 2.4)
                Text(albumIsActive ? "playing from album" : totalDurationLabel)
                    .font(.wwav(11, weight: .light, italic: true))
                    .tracking(1)
                    .foregroundStyle(theme.muted)
            }

            Spacer()

            if albumIsActive {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(theme.sand.opacity(0.70)))
                    .overlay(Circle().stroke(theme.accent.opacity(0.20), lineWidth: 1))
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                FeedAlbumCover(url: currentAlbum.coverImageURL)
                LinearGradient(
                    colors: [.black.opacity(0.04), .black.opacity(0.56)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("album").wwavLabel(size: 10, tracking: 2.2)
                            .foregroundStyle(theme.glow.opacity(0.88))
                        Text(totalDurationLabel)
                            .font(.wwav(10, weight: .light))
                            .tracking(1.1)
                            .foregroundStyle(theme.glow.opacity(0.76))
                    }
                    Text(currentAlbum.title)
                        .wwavTitle(size: 38)
                        .foregroundStyle(theme.glow)
                        .lineLimit(2)
                        .minimumScaleFactor(0.76)
                    Text("@\(currentAlbum.handle)")
                        .font(.wwav(12, weight: .light))
                        .tracking(1)
                        .foregroundStyle(theme.glow.opacity(0.78))
                }
                .padding(18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.muted.opacity(0.18), lineWidth: 1)
            )
            .wwavShadow(.md)

            HStack(spacing: 10) {
                Button {
                    playAlbum()
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().fill(theme.glow.opacity(0.22))
                            Triangle()
                                .fill(theme.glow)
                                .frame(width: 8, height: 10)
                                .offset(x: 1)
                        }
                        .frame(width: 24, height: 24)
                        Text(albumIsActive ? "resume album" : "play album")
                            .font(.wwav(13, weight: .medium, italic: true))
                            .tracking(1.5)
                    }
                    .foregroundStyle(theme.glow)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .overlay(Capsule().stroke(theme.glow.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(playableTracks.isEmpty)
                .opacity(playableTracks.isEmpty ? 0.45 : 1)

                Text("\(playableTracks.count) playable")
                    .font(.wwav(11, weight: .light, italic: true))
                    .tracking(1)
                    .foregroundStyle(theme.muted)
                    .frame(minWidth: 96)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(theme.sand.opacity(0.58)))
                    .overlay(Capsule().stroke(theme.muted.opacity(0.18), lineWidth: 1))
            }
        }
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("track list").wwavLabel(size: 10, tracking: 2)
                Spacer()
                Text(totalDurationLabel)
                    .font(.wwav(10, weight: .light))
                    .tracking(1)
                    .foregroundStyle(theme.muted)
            }

            if tracks.isEmpty {
                EmptyState(
                    title: "no tracks",
                    body: "this album does not have a playable track list yet."
                )
                .frame(minHeight: 220)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        AlbumTrackRow(
                            track: track,
                            index: index + 1,
                            active: player.currentTrack?.id == track.id
                        ) {
                            play(track)
                        }
                        .disabled(!isPlayable(track))
                        .opacity(isPlayable(track) ? 1 : 0.48)

                        if index < tracks.count - 1 {
                            Rectangle()
                                .fill(theme.muted.opacity(0.14))
                                .frame(height: 1)
                                .padding(.leading, 76)
                        }
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.sand.opacity(0.58)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.muted.opacity(0.20), lineWidth: 1))
            }
        }
    }

    private func playAlbum() {
        if albumIsActive {
            nav.albumViewerPost = nil
            dismiss()
            nav.active = .play
            return
        }
        guard let first = playableTracks.first else { return }
        play(first)
    }

    private func play(_ track: Track) {
        guard isPlayable(track) else { return }
        nav.albumViewerPost = nil
        dismiss()
        nav.openPost(track, in: library, with: player, albumContext: currentAlbum)
    }

    private func isPlayable(_ track: Track) -> Bool {
        guard track.kind == .music else { return false }
        if case .ready = track.status { return true }
        return false
    }
}

private struct FeedAlbumCover: View {
    let url: URL?
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.clay.opacity(0.32), theme.clayDeep.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            CachedAsyncImage(url: url, contentMode: .fill) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(theme.muted.opacity(0.72))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

private struct AlbumTrackRow: View {
    let track: Track
    let index: Int
    let active: Bool
    let onPlay: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                Text(String(format: "%02d", index))
                    .font(.wwav(11, weight: active ? .medium : .light))
                    .foregroundStyle(active ? theme.accent : theme.muted)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .center)

                ZStack {
                    LinearGradient(
                        colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    CachedAsyncImage(url: track.thumbnailURL) { Color.clear }
                }
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.muted.opacity(0.14), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.wwav(15, weight: active ? .semibold : .medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(rowSubtitle)
                        .font(.wwav(10, weight: .light))
                        .tracking(1)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let duration = durationText {
                    Text(duration)
                        .font(.wwav(10, weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(theme.muted)
                }

                ZStack {
                    Circle().fill(active ? theme.accent : theme.muted.opacity(0.14))
                    Image(systemName: active ? "speaker.wave.2.fill" : "play.fill")
                        .font(.system(size: active ? 10 : 9, weight: .semibold))
                        .foregroundStyle(active ? theme.glow : theme.muted)
                }
                .frame(width: 32, height: 32)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? theme.glow.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowSubtitle: String {
        if case .ready = track.status {
            return "@\(track.handle)"
        }
        if case .separating(let p) = track.status {
            return "separating · \(Int(p * 100))%"
        }
        return "@\(track.handle)"
    }

    private var durationText: String? {
        guard case .ready = track.status else { return nil }
        return formatDuration(track.durationSeconds)
    }

    private func formatDuration(_ duration: Double) -> String {
        let seconds = max(0, Int(duration))
        guard seconds > 0 else { return "song" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
