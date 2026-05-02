import SwiftUI

private let feedTabLabels = ["for you", "following", "friends"]

private struct WWAVLogoMark: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black)

                Circle()
                    .fill(.white)
                    .frame(width: w * 0.92, height: w * 0.92)
                    .offset(y: -h * 0.08)

                Circle()
                    .fill(.black)
                    .frame(width: w * 0.43, height: w * 0.43)
                    .offset(x: w * 0.04, y: h * 0.08)

                Circle()
                    .fill(.white)
                    .frame(width: w * 0.24, height: w * 0.24)
                    .offset(x: -w * 0.02, y: h * 0.22)

                Circle()
                    .fill(.black)
                    .frame(width: w * 0.25, height: w * 0.25)
                    .offset(x: w * 0.32, y: h * 0.18)

                Circle()
                    .fill(.white)
                    .frame(width: w * 0.17, height: w * 0.17)
                    .offset(x: w * 0.32, y: h * 0.24)

                Capsule()
                    .fill(.black)
                    .frame(width: w * 0.98, height: h * 0.045)
                    .offset(y: h * 0.24)

                Capsule()
                    .fill(.black)
                    .frame(width: w * 0.44, height: h * 0.052)
                    .offset(x: -w * 0.26, y: h * 0.34)

                Capsule()
                    .fill(.black)
                    .frame(width: w * 0.34, height: h * 0.052)
                    .offset(x: w * 0.30, y: h * 0.34)

                Capsule()
                    .fill(.black)
                    .frame(width: w * 0.78, height: h * 0.052)
                    .offset(x: w * 0.06, y: h * 0.45)

                Circle()
                    .fill(.black)
                    .frame(width: w * 0.40, height: w * 0.40)
                    .offset(x: -w * 0.22, y: h * 0.53)

                Capsule()
                    .fill(.white)
                    .frame(width: w * 0.44, height: h * 0.12)
                    .rotationEffect(.degrees(-10))
                    .offset(x: w * 0.18, y: h * 0.49)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("WWAV")
    }
}

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
                    LazyVStack(spacing: 0) {
                        FeedComposerCard()
                            .padding(.horizontal, 24)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        SoftRule()

                        if library.feed.isEmpty {
                            EmptyState(
                                title: "no waves yet",
                                body: "pull down to refresh, or post from here."
                            )
                            .frame(minHeight: 320)
                        } else {
                            ForEach(Array(library.feed.enumerated()), id: \.element.id) { idx, track in
                                FeedItemView(track: track, accent: idx == 0) {
                                    nav.openPost(track, in: library, with: player)
                                }
                                if idx < library.feed.count - 1 {
                                    SoftRule()
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
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
            WWAVLogoMark()
                .frame(width: 54, height: 54)
                .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { feedTab = i }
                } label: {
                    VStack(spacing: 6) {
                        Text(feedTabLabels[i])
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

private let feedComposerKinds: [PostKind] = [.text, .music, .image, .video]

private struct FeedComposerCard: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.theme) private var theme

    @FocusState private var focused: Bool
    @State private var selectedKind: PostKind = .text
    @State private var draft: String = ""

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProfileAvatar(url: auth.user?.profilePictureURL, size: 40)

            VStack(alignment: .leading, spacing: 12) {
                composerBody

                HStack(spacing: 8) {
                    ForEach(feedComposerKinds) { kind in
                        kindButton(kind)
                    }

                    Spacer(minLength: 0)

                    actionButton
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.sand.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.muted.opacity(0.20), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var composerBody: some View {
        if selectedKind == .text {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("what's happening?")
                        .font(.wwav(16, weight: .light, italic: true))
                        .foregroundStyle(theme.muted)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                }

                TextEditor(text: $draft)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .font(.wwav(16, weight: .light))
                    .foregroundStyle(theme.ink)
                    .frame(minHeight: 56, maxHeight: 116)
                    .padding(.horizontal, -5)
                    .padding(.vertical, -8)
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: iconName(for: selectedKind))
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(theme.muted.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedKind.label) post")
                        .font(.wwav(16, weight: .medium, italic: true))
                        .foregroundStyle(theme.ink)
                    Text(selectedKind == .music ? "stem upload" : selectedKind == .image ? "photo set" : "video clip")
                        .font(.wwav(12, weight: .light, italic: true))
                        .foregroundStyle(theme.muted)
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: 56)
        }
    }

    private var actionButton: some View {
        Button {
            if selectedKind == .text {
                submitText()
            } else {
                nav.compose(selectedKind)
            }
        } label: {
            HStack(spacing: 5) {
                if selectedKind != .text {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10, weight: .medium))
                }
                Text(selectedKind == .text ? "post" : "open")
                    .font(.wwav(11, weight: .regular, italic: true))
                    .tracking(1.3)
            }
            .foregroundStyle(theme.glow)
            .padding(.vertical, 7)
            .padding(.horizontal, 13)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [theme.clay, theme.clayDeep],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(selectedKind == .text && trimmedDraft.isEmpty)
        .opacity(selectedKind == .text && trimmedDraft.isEmpty ? 0.5 : 1)
    }

    private func kindButton(_ kind: PostKind) -> some View {
        let active = selectedKind == kind
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedKind = kind
            }
            focused = kind == .text
        } label: {
            Image(systemName: iconName(for: kind))
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? theme.glow : theme.muted)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(active ? theme.accent : theme.muted.opacity(0.10))
                )
                .overlay(
                    Circle().stroke(theme.muted.opacity(active ? 0 : 0.20), lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func submitText() {
        let body = trimmedDraft
        guard !body.isEmpty else { return }
        _ = library.createTextPost(title: "", body: body, token: auth.token)
        draft = ""
        focused = false
    }

    private func iconName(for kind: PostKind) -> String {
        switch kind {
        case .music: return "music.note"
        case .image: return "photo"
        case .text: return "text.bubble"
        case .video: return "play.rectangle"
        }
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
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @State private var showingComments: Bool = false
    @State private var editing: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                nav.openProfile(for: track)
            } label: {
                ProfileAvatar(url: track.authorProfilePictureURL, size: 44)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button {
                        nav.openProfile(for: track)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(track.artist)
                                .font(.wwav(15, weight: .medium))
                                .foregroundStyle(theme.ink)
                            Text("@\(track.handle)")
                                .font(.wwav(12, weight: .light))
                                .foregroundStyle(theme.muted)
                        }
                    }
                    .buttonStyle(.plain)

                    PostKindBadge(kind: track.kind)
                    Spacer(minLength: 4)
                    Text(timeAgo(track.createdAt))
                        .font(.wwav(12, weight: .light))
                        .foregroundStyle(theme.muted)
                    if library.isAuthoredByCurrentUser(track) {
                        Button { editing = true } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(theme.muted)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
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
        VStack(alignment: .leading, spacing: 4) {
            Text(track.title)
                .wwavTitle(size: 22)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if track.isRemix {
                HStack(spacing: 6) {
                    // Remix badge chip
                    Text("remix")
                        .font(.wwav(9, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(theme.glow)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.accent))

                    // Genealogy button — opens parent track
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

    // MARK: – Image

    private var imageBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !track.resolvedImageURLs.isEmpty {
                ImageCarousel(urls: track.resolvedImageURLs)
                    .padding(.top, 12)
                    .onTapGesture { onPlay() }
            } else if case .separating = track.status {
                placeholderBox(text: "uploading images…")
            } else if case .uploading = track.status {
                placeholderBox(text: "uploading…")
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

struct PublicProfileSheet: View {
    let route: PublicProfileRoute

    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private var posts: [Track] {
        library.posts(for: route)
    }

    private var totalViews: Int {
        posts.reduce(0) { $0 + $1.plays }
    }

    private var totalLoves: Int {
        posts.reduce(0) { $0 + $1.loves }
    }

    private var isCurrentUser: Bool {
        if let routeId = route.authorUserId, let myId = library.profile.remoteUserId {
            return routeId == myId
        }
        return route.handle.lowercased() == library.profile.handle.lowercased()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.pageRadial.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header

                        SoftRule()

                        if posts.isEmpty {
                            EmptyState(
                                title: "no posts yet",
                                body: "posts from @\(route.handle) will collect here once the feed sees them."
                            )
                            .frame(minHeight: 220)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(posts.enumerated()), id: \.element.id) { index, track in
                                    PublicProfilePostRow(track: track, index: index) {
                                        nav.openPost(track, in: library, with: player)
                                        dismiss()
                                    }
                                    if index < posts.count - 1 { SoftRule() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 28)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.ink)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(theme.muted.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                ProfileAvatar(url: route.profilePictureURL, size: 74)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(route.displayName)
                            .wwavTitle(size: 30)
                            .lineLimit(1)
                        if isCurrentUser {
                            Text("you")
                                .font(.wwav(9, weight: .medium, italic: true))
                                .tracking(1.3)
                                .foregroundStyle(theme.glow)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(theme.accent))
                        }
                    }
                    Text("@\(route.handle)")
                        .font(.wwav(13, weight: .light))
                        .foregroundStyle(theme.muted)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                profileStat("\(posts.count)", "posts")
                profileStat(short(totalViews), "views")
                profileStat(short(totalLoves), "loves")
            }
        }
    }

    private func profileStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.wwav(16, weight: .medium))
                .foregroundStyle(theme.ink)
            Text(label)
                .font(.wwav(10, weight: .light))
                .tracking(1.2)
                .foregroundStyle(theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.sand.opacity(0.58)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.muted.opacity(0.16), lineWidth: 1))
    }

    private func short(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
        return "\(n)"
    }
}

private struct PublicProfilePostRow: View {
    let track: Track
    let index: Int
    let onTap: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                thumbnail
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.muted.opacity(0.22), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(track.title)
                            .wwavTitle(size: 20)
                            .lineLimit(1)
                        PostKindBadge(kind: track.kind)
                    }
                    Text(rowSubtitle)
                        .font(.wwav(11, weight: .light))
                        .tracking(1)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                    if track.kind == .text, !track.displayText.isEmpty {
                        Text(track.displayText)
                            .font(.wwav(12, weight: .light))
                            .foregroundStyle(theme.ink.opacity(0.80))
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.muted.opacity(0.65))
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch track.kind {
        case .music, .video, .image:
            ZStack {
                LinearGradient(
                    colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                CachedAsyncImage(url: track.thumbnailURL) { Color.clear }
                if track.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                }
            }
        case .text:
            ZStack {
                LinearGradient(
                    colors: [theme.sand, theme.sandDeep.opacity(0.64)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "text.bubble")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(theme.muted)
            }
        }
    }

    private var rowSubtitle: String {
        let views = track.kind == .music || track.kind == .video ? "plays" : "views"
        return "\(track.plays) \(views) · \(track.loves) loves"
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
