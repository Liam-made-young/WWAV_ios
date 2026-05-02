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
                    TabBar(active: $nav.active)
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

    var body: some View {
        ZStack {
            theme.pageRadial.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
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
        HStack {
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

            Spacer()

            Text("\(tracks.count) tracks")
                .font(.wwav(11, weight: .light))
                .tracking(1.6)
                .foregroundStyle(theme.muted)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                FeedAlbumCover(url: currentAlbum.coverImageURL)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.34)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 5) {
                    Text("album").wwavLabel(size: 10, tracking: 2.2)
                        .foregroundStyle(theme.glow.opacity(0.88))
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
        }
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("track list").wwavLabel(size: 10, tracking: 2)

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
                                .padding(.leading, 66)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.sand.opacity(0.62)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.muted.opacity(0.20), lineWidth: 1))
            }
        }
    }

    private func play(_ track: Track) {
        guard isPlayable(track) else { return }
        nav.albumViewerPost = nil
        dismiss()
        nav.openPost(track, in: library, with: player)
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
                    .font(.wwav(11, weight: .light))
                    .foregroundStyle(active ? theme.accent : theme.muted)
                    .frame(width: 30, alignment: .leading)

                ZStack {
                    LinearGradient(
                        colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    CachedAsyncImage(url: track.thumbnailURL) { Color.clear }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.wwav(15, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(rowSubtitle)
                        .font(.wwav(10, weight: .light))
                        .tracking(1)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                ZStack {
                    Circle().fill(active ? theme.accent : theme.muted.opacity(0.14))
                    Triangle()
                        .fill(active ? theme.glow : theme.muted)
                        .frame(width: 8, height: 10)
                        .offset(x: 1)
                }
                .frame(width: 32, height: 32)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowSubtitle: String {
        if case .ready = track.status {
            return "@\(track.handle) · \(formatDuration(track.durationSeconds))"
        }
        if case .separating(let p) = track.status {
            return "separating · \(Int(p * 100))%"
        }
        return "@\(track.handle)"
    }

    private func formatDuration(_ duration: Double) -> String {
        let seconds = max(0, Int(duration))
        guard seconds > 0 else { return "song" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
