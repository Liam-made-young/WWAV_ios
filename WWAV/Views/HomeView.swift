import SwiftUI

struct HomeView: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme
    @State private var feedTab: Int = 0

    var body: some View {
        ZStack {
            theme.pageRadial.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                tabPicker
                ScrollView {
                    if library.feed.isEmpty {
                        EmptyState(
                            title: "no waves yet",
                            body: "pull down to refresh, or drop a post from the + tab."
                        )
                        .frame(minHeight: 320)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(library.feed.enumerated()), id: \.element.id) { idx, track in
                                FeedItemView(track: track, accent: idx == 0) {
                                    nav.openPost(track, in: library, with: player)
                                }
                                if idx < library.feed.count - 1 {
                                    SoftRule()
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
                .refreshable {
                    await library.refresh(token: auth.token)
                }
            }
        }
        .task { await library.refresh(token: auth.token) }
        .fullScreenCover(item: $nav.imageViewerPost) { post in
            FullscreenImageViewer(post: post)
        }
    }

    private var header: some View {
        HStack {
            Text("wwav").wwavTitle(size: 48).tracking(-1)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    private var tabPicker: some View {
        let labels = ["for you", "following", "friends"]
        return HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { feedTab = i }
                } label: {
                    VStack(spacing: 6) {
                        Text(labels[i])
                            .font(.wwav(13, weight: feedTab == i ? .medium : .light, italic: true))
                            .foregroundStyle(feedTab == i ? theme.ink : theme.muted)
                        Rectangle()
                            .fill(feedTab == i ? theme.accent : theme.muted.opacity(0.15))
                            .frame(height: feedTab == i ? 1.5 : 1)
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
    }
}

/// One feed cell. Header (avatar + name) + body that varies by post kind +
/// the social bar (plays / reply / repost / love). Edit-metadata is one tap
/// away on every cell so the user can patch a missing cover or rename.
struct FeedItemView: View {
    let track: Track
    let accent: Bool
    let onPlay: () -> Void
    @Environment(\.theme) private var theme
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var library: TrackLibrary
    @State private var showingComments: Bool = false
    @State private var editing: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ProfileAvatar(url: auth.user?.profilePictureURL, size: 44)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(track.artist)
                        .font(.wwav(15, weight: .medium))
                        .foregroundStyle(theme.ink)
                    Text("@\(track.handle)")
                        .font(.wwav(12, weight: .light))
                        .foregroundStyle(theme.muted)
                    PostKindBadge(kind: track.kind)
                    Spacer(minLength: 4)
                    Text(timeAgo(track.createdAt))
                        .font(.wwav(12, weight: .light))
                        .foregroundStyle(theme.muted)
                    Button { editing = true } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(theme.muted)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                bodyContent

                socialBar
                    .padding(.top, 10)

                if showingComments {
                    CommentsThread(track: track)
                        .padding(.top, 10)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .sheet(isPresented: $editing) {
            EditMetadataSheet(track: track)
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch track.kind {
        case .music: musicBody
        case .image: imageBody
        case .text:  textBody
        case .video: videoBody
        }
    }

    // MARK: – Music

    private var musicBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover.padding(.top, 12)
            titleRow.padding(.top, 12)
            if !track.bio.isEmpty {
                Text(track.bio)
                    .font(.wwav(13, weight: .light))
                    .foregroundStyle(theme.ink)
                    .padding(.top, 6)
            }
            MiniWaveform(accent: accent).padding(.top, 10)
        }
    }

    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                LinearGradient(colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                CachedAsyncImage(url: track.coverImageURL) {
                    Color.clear
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.muted.opacity(0.20), lineWidth: 1))

            Button(action: onPlay) {
                ZStack {
                    Circle().fill(
                        RadialGradient(colors: [theme.clay, theme.clayDeep],
                                       center: UnitPoint(x: 0.35, y: 0.30),
                                       startRadius: 2, endRadius: 36)
                    )
                    Triangle().fill(theme.glow).frame(width: 12, height: 14)
                        .offset(x: 1)
                }
                .frame(width: 50, height: 50)
                .shadow(color: .black.opacity(0.30), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }

    private var titleRow: some View {
        Text(track.title)
            .wwavTitle(size: 22)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: – Image

    private var imageBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !track.resolvedImageURLs.isEmpty {
                ImageCarousel(urls: track.resolvedImageURLs)
                    .padding(.top, 12)
                    .onTapGesture { onPlay() }
            } else if case .separating = track.status {
                placeholderBox(text: "uploading images…")
            } else {
                placeholderBox(text: "no images")
            }
            if track.title != "image post" && !track.title.isEmpty {
                titleRow.padding(.top, 12)
            }
            if !track.bio.isEmpty {
                Text(track.bio)
                    .font(.wwav(14, weight: .light))
                    .foregroundStyle(theme.ink)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: – Text

    private var textBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if track.title != "text post" && !track.title.isEmpty {
                Text(track.title)
                    .wwavTitle(size: 22)
                    .padding(.top, 10)
            }
            Text(track.displayText.isEmpty ? "(empty)" : track.displayText)
                .font(.wwav(17, weight: .light))
                .foregroundStyle(theme.ink)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
    }

    // MARK: – Video

    private var videoBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .center) {
                ZStack {
                    LinearGradient(colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    CachedAsyncImage(url: track.coverImageURL) {
                        Color.clear
                    }
                }
                .aspectRatio(9.0/16.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16)
                            .stroke(theme.muted.opacity(0.20), lineWidth: 1))

                Button(action: onPlay) {
                    ZStack {
                        Circle().fill(
                            RadialGradient(colors: [theme.clay, theme.clayDeep],
                                           center: UnitPoint(x: 0.35, y: 0.30),
                                           startRadius: 2, endRadius: 50)
                        )
                        Triangle().fill(theme.glow).frame(width: 18, height: 22)
                            .offset(x: 2)
                    }
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.40), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)

            titleRow.padding(.top, 12)
            if !track.bio.isEmpty {
                Text(track.bio)
                    .font(.wwav(13, weight: .light))
                    .foregroundStyle(theme.ink)
                    .padding(.top, 6)
            }
        }
    }

    private func placeholderBox(text: String) -> some View {
        ZStack {
            LinearGradient(colors: [theme.clay.opacity(0.18), theme.clayDeep.opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(text).font(.wwav(13, weight: .light, italic: true)).foregroundStyle(theme.muted)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(theme.muted.opacity(0.20), lineWidth: 1))
        .padding(.top, 12)
    }

    private var socialBar: some View {
        HStack(spacing: 18) {
            Text("\(short(track.plays)) \(track.kind == .music || track.kind == .video ? "plays" : "views")")
                .font(.wwav(11, weight: .light))
                .tracking(1)
                .foregroundStyle(theme.muted)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showingComments.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showingComments ? "bubble.left.fill" : "bubble.left")
                        .font(.system(size: 12, weight: .regular))
                    Text(showingComments ? "hide" : "reply")
                        .font(.wwav(11, weight: .light))
                        .tracking(1)
                }
                .foregroundStyle(showingComments ? theme.accent : theme.muted)
                .padding(.vertical, 4).padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { library.toggleRepost(track: track) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 12, weight: track.reposted ? .semibold : .regular))
                    Text("\(track.reposts)")
                        .font(.wwav(11, weight: .light)).tracking(1)
                }
                .foregroundStyle(track.reposted ? theme.accent : theme.muted)
                .padding(.vertical, 4).padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await library.toggleLike(track: track, token: auth.token) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: track.liked ? "heart.fill" : "heart")
                        .font(.system(size: 12, weight: .regular))
                    Text("\(track.loves)")
                        .font(.wwav(11, weight: .light)).tracking(1)
                }
                .foregroundStyle(track.liked ? Color.red.opacity(0.85) : theme.muted)
                .padding(.vertical, 4).padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }

    private func short(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
        return "\(n)"
    }
}

private struct PostKindBadge: View {
    let kind: PostKind
    @Environment(\.theme) private var theme
    var body: some View {
        if kind == .music { EmptyView() } else {
            Text(kind.label)
                .font(.wwav(9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(theme.muted.opacity(0.14))
                )
        }
    }
}

/// Fullscreen carousel viewer presented when an image post is tapped from
/// the feed. Tap anywhere outside the image to dismiss.
struct FullscreenImageViewer: View {
    let post: Track
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if !post.resolvedImageURLs.isEmpty {
                TabView {
                    ForEach(Array(post.resolvedImageURLs.enumerated()), id: \.offset) { _, url in
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().aspectRatio(contentMode: .fit)
                            case .empty:
                                ProgressView().tint(.white)
                            case .failure:
                                Image(systemName: "photo")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.white.opacity(0.5))
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .tabViewStyle(.page)
                .indexViewStyle(.page(backgroundDisplayMode: .always))
            }
            Button { nav.imageViewerPost = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Circle().fill(.black.opacity(0.5)))
            }
            .padding(.top, 50)
            .padding(.trailing, 18)
        }
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    @Environment(\.theme) private var theme

    init(title: String, body: String) {
        self.title = title
        self.message = body
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Text(title).wwavTitle(size: 28)
            Text(message)
                .font(.wwav(13, weight: .light))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: rect.height))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height / 2))
        p.closeSubpath()
        return p
    }
}
