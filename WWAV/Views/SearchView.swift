import SwiftUI

struct SearchView: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.theme) private var theme
    @State private var query: String = ""
    @State private var kindFilter: KindFilter = .all

    private enum KindFilter: String, CaseIterable, Identifiable {
        case all, music, album, image, text, video
        var id: String { rawValue }
    }

    private var pool: [Track] {
        library.feed.isEmpty ? library.myTracks : library.feed
    }

    private var results: [Track] {
        let kindFiltered: [Track]
        switch kindFilter {
        case .all:   kindFiltered = pool
        case .music: kindFiltered = pool.filter { $0.kind == .music }
        case .album: kindFiltered = pool.filter { $0.kind == .album }
        case .image: kindFiltered = pool.filter { $0.kind == .image }
        case .text:  kindFiltered = pool.filter { $0.kind == .text }
        case .video: kindFiltered = pool.filter { $0.kind == .video }
        }
        guard !query.isEmpty else { return kindFiltered }
        let q = query.lowercased()
        return kindFiltered.filter { t in
            t.title.lowercased().contains(q)
                || t.artist.lowercased().contains(q)
                || t.handle.lowercased().contains(q)
                || t.bio.lowercased().contains(q)
                || (t.textBody?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        ZStack {
            theme.pageRadial.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("search").wwavTitle(size: 40)
                        Spacer()
                    }
                    .padding(.horizontal, 24).padding(.top, 16)

                    searchField
                        .padding(.horizontal, 24).padding(.top, 16)

                    kindFilterRow
                        .padding(.horizontal, 24).padding(.top, 14)

                    Text(results.isEmpty ? "no matches" : "posts — \(results.count)")
                        .wwavLabel(size: 10, tracking: 2)
                        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 8)

                    if results.isEmpty && library.myTracks.isEmpty {
                        Text("upload your first post to make it searchable.")
                            .font(.wwav(13, weight: .light, italic: true))
                            .foregroundStyle(theme.muted)
                            .padding(.horizontal, 24).padding(.top, 24)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, track in
                                ResultRow(index: idx, track: track, accent: idx == 0) {
                                    nav.openPost(track, in: library, with: player)
                                }
                                if idx < results.count - 1 { SoftRule() }
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(theme.ink)
            TextField("", text: $query, prompt: Text("search posts, captions, artists").foregroundStyle(theme.muted))
                .font(.wwav(16, weight: .light, italic: true))
                .foregroundStyle(theme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(
            Capsule().fill(LinearGradient(colors: [theme.sand, theme.sandDeep.opacity(0.6)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(Capsule().stroke(theme.muted.opacity(0.20), lineWidth: 1))
    }

    private var kindFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(KindFilter.allCases) { f in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { kindFilter = f }
                    } label: {
                        let active = kindFilter == f
                        Text(f.rawValue)
                            .font(.wwav(11, weight: active ? .medium : .light, italic: true))
                            .tracking(1.5)
                            .foregroundStyle(active ? theme.glow : theme.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(
                                    active
                                    ? AnyShapeStyle(LinearGradient(colors: [theme.clay, theme.clayDeep],
                                                                   startPoint: .top, endPoint: .bottom))
                                    : AnyShapeStyle(theme.muted.opacity(0.10))
                                )
                            )
                            .overlay(Capsule().stroke(theme.muted.opacity(active ? 0 : 0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ResultRow: View {
    let index: Int
    let track: Track
    let accent: Bool
    let onTap: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 14) {
                Text(String(format: "%02d", index + 1))
                    .font(.wwav(11, weight: .light))
                    .foregroundStyle(theme.muted)
                    .frame(width: 18, alignment: .leading)

                thumbnail.frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.muted.opacity(0.30), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(track.title).wwavTitle(size: 19)
                        if track.kind != .music {
                            Text(track.kind.label)
                                .font(.wwav(9, weight: .medium)).tracking(1.2)
                                .foregroundStyle(theme.muted)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(theme.muted.opacity(0.14)))
                        }
                    }
                    Text("\(track.artist.lowercased()) · \(track.plays) \(track.kind == .music || track.kind == .video ? "plays" : "views")")
                        .font(.wwav(11, weight: .light))
                        .tracking(1)
                        .foregroundStyle(theme.muted)
                }
                Spacer(minLength: 0)
                if track.kind == .music || track.kind == .album {
                    MiniWaveform(accent: accent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch track.kind {
        case .music, .album, .video, .image:
            ZStack {
                LinearGradient(colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                CachedAsyncImage(url: track.thumbnailURL) { Color.clear }
                if track.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14)).foregroundStyle(.white).shadow(radius: 2)
                }
            }
        case .text, .radio:
            ZStack {
                LinearGradient(colors: [theme.sand, theme.sandDeep.opacity(0.6)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: track.kind == .radio ? "radio" : "text.alignleft")
                    .font(.system(size: 16)).foregroundStyle(theme.muted)
            }
        }
    }
}
