import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme
    @State private var editing = false
    @State private var showSettings = false
    @State private var editingPost: Track?

    var body: some View {
        ZStack {
            theme.pageRadial.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Spacer()
                        Button { editing = true } label: {
                            profileHeaderChip(label: "edit")
                        }
                        .buttonStyle(.plain)
                        Button { showSettings = true } label: {
                            profileHeaderChip(label: "settings")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24).padding(.top, 16)

                    HStack(alignment: .bottom, spacing: 18) {
                        ProfileAvatar(url: auth.user?.profilePictureURL, size: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(library.profile.name)
                                .wwavTitle(size: profileNameSize)
                                .lineLimit(2)
                                .minimumScaleFactor(0.62)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("@\(library.profile.handle)")
                                .font(.wwav(12, weight: .light))
                                .tracking(1)
                                .foregroundStyle(theme.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 24).padding(.top, 20)

                    if !library.profile.bio.isEmpty {
                        Text(library.profile.bio)
                            .wwavLabel(size: 11, tracking: 2)
                            .padding(.horizontal, 24).padding(.top, 18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    statsCard.padding(.horizontal, 24).padding(.top, 22)

                    ProfileLibrarySection(
                        tracks: library.libraryItems,
                        onOpen: { track in
                            nav.openPost(track, in: library, with: player)
                        },
                        onEdit: { editingPost = $0 },
                        onPublish: { track in
                            _ = library.publishToFeed(id: track.id, token: auth.token)
                        }
                    )
                    .padding(.top, 26)
                    .padding(.bottom, 110)
                }
            }
            .refreshable { await library.refresh(token: auth.token, force: true) }
        }
        .task(id: auth.token) { await library.refresh(token: auth.token) }
        .sheet(isPresented: $editing) { ProfileEditSheet() }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(item: $editingPost) { post in
            EditMetadataSheet(track: post)
        }
    }

    private var profileNameSize: CGFloat {
        // Long names that would otherwise wrap mid-word get a smaller starting
        // size before minimumScaleFactor kicks in.
        library.profile.name.count > 14 ? 32 : 38
    }

    private func profileHeaderChip(label: String) -> some View {
        Text(label)
            .font(.wwav(10, weight: .medium, italic: true))
            .tracking(1.3)
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(theme.sand.opacity(WWAVOpacity.firm)))
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [theme.glow.opacity(0.45), theme.muted.opacity(WWAVOpacity.soft)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
    }

    private var statsCard: some View {
        HStack(spacing: 0) {
            stat("\(library.trackCount)", "posts")
            divider
            stat(short(library.totalPlays), "plays")
            divider
            stat("\(library.totalLoves)", "loves")
        }
        .background(
            RoundedRectangle(cornerRadius: 18).fill(
                RadialGradient(
                    colors: [theme.sand, theme.sandDeep.opacity(0.55)],
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 20, endRadius: 220
                )
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    LinearGradient(
                        colors: [theme.glow.opacity(0.45), theme.muted.opacity(WWAVOpacity.soft)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
    }

    private func stat(_ n: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(n).wwavTitle(size: 30).monospacedDigit()
            Text(label).wwavLabel(size: 10, tracking: 2.0)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
    }
    private var divider: some View {
        Rectangle().fill(theme.muted.opacity(WWAVOpacity.hair)).frame(width: 1)
    }

    private func short(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
        return "\(n)"
    }
}

private struct ProfileLibrarySection: View {
    let tracks: [Track]
    let onOpen: (Track) -> Void
    let onEdit: (Track) -> Void
    let onPublish: (Track) -> Void
    @Environment(\.theme) private var theme
    @State private var selectedFilter: ProfileLibraryFilter = .all

    private var drafts: Int { tracks.filter(\.isDraft).count }
    private var live: Int { tracks.filter(\.isPublished).count }
    private var filteredTracks: [Track] {
        tracks.filter(selectedFilter.matches)
    }

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("library")
                        .wwavTitle(size: 30)
                    Text("\(drafts) drafts · \(live) live")
                        .font(.wwav(11, weight: .light))
                        .tracking(1.2)
                        .foregroundStyle(theme.muted)
                }
                Spacer()
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 24)

            libraryFilterStrip

            if tracks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("your library is waiting")
                        .wwavTitle(size: 22)
                    Text("use the + tab to save uploads here, then post them when they feel finished.")
                        .font(.wwav(13, weight: .light, italic: true))
                        .foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.sand.opacity(0.58)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.muted.opacity(0.18), lineWidth: 1))
                .padding(.horizontal, 24)
            } else if filteredTracks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("nothing here yet")
                        .wwavTitle(size: 22)
                    Text("try another library filter.")
                        .font(.wwav(13, weight: .light, italic: true))
                        .foregroundStyle(theme.muted)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.sand.opacity(0.58)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.muted.opacity(0.18), lineWidth: 1))
                .padding(.horizontal, 24)
            } else {
                LazyVGrid(columns: columns, alignment: .center, spacing: 18) {
                    ForEach(filteredTracks) { track in
                        ProfileLibraryTile(
                            track: track,
                            onOpen: { onOpen(track) },
                            onEdit: { onEdit(track) },
                            onPublish: { onPublish(track) }
                        )
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private var libraryFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ProfileLibraryFilter.allCases) { filter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedFilter = filter
                        }
                    } label: {
                        let active = selectedFilter == filter
                        Text(filter.label)
                            .font(.wwav(11, weight: active ? .medium : .light, italic: true))
                            .tracking(1.1)
                            .foregroundStyle(active ? theme.glow : theme.muted)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(active ? theme.accent : theme.sand.opacity(0.64)))
                            .overlay(Capsule().stroke(theme.muted.opacity(active ? 0 : 0.20), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
        }
    }
}

private enum ProfileLibraryFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case music
    case video
    case published
    case unpublished

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "all"
        case .text: return "text posts"
        case .music: return "music"
        case .video: return "video"
        case .published: return "published"
        case .unpublished: return "unpublished"
        }
    }

    func matches(_ track: Track) -> Bool {
        switch self {
        case .all: return true
        case .text: return track.kind == .text
        case .music: return track.kind == .music
        case .video: return track.kind == .video
        case .published: return track.isPublished
        case .unpublished: return track.isDraft
        }
    }
}

private struct ProfileLibraryTile: View {
    let track: Track
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onPublish: () -> Void
    @EnvironmentObject private var library: TrackLibrary
    @Environment(\.theme) private var theme

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var isOpenable: Bool {
        if case .ready = track.status { return true }
        return track.kind == .text
    }

    private var statusText: String {
        if track.isDraft {
            switch track.status {
            case .sourceOnly: return "saved source"
            case .uploading(let phase, let progress): return "\(phase.label) \(Int(progress * 100))%"
            case .separating(let progress): return "separating \(Int(progress * 100))%"
            case .failed(_): return "needs attention"
            case .ready: return "ready to post"
            }
        }
        return "live · \(track.plays) \(track.kind == .music || track.kind == .video ? "plays" : "views")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 9) {
                    ProfileLibraryCover(track: track)
                        .overlay(alignment: .topLeading) {
                            LibraryStateBadge(track: track)
                                .padding(8)
                        }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.wwav(16, weight: .medium, italic: true))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Text(statusText)
                            .font(.wwav(10, weight: .light))
                            .tracking(1)
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!isOpenable)

            HStack(spacing: 8) {
                if track.isDraft {
                    Button(action: onPublish) {
                        Text(library.canPublish(track) ? "post to feed" : "preparing")
                            .font(.wwav(10, weight: .medium, italic: true))
                            .tracking(1)
                            .foregroundStyle(library.canPublish(track) ? theme.glow : theme.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(
                                    library.canPublish(track)
                                        ? AnyShapeStyle(LinearGradient(
                                            colors: [theme.clay, theme.clayDeep],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ))
                                        : AnyShapeStyle(theme.muted.opacity(0.12))
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!library.canPublish(track))
                } else {
                    Text("published")
                        .font(.wwav(10, weight: .medium, italic: true))
                        .tracking(1)
                        .foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(theme.accent.opacity(0.12)))
                }

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(theme.muted)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(theme.muted.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.glow.opacity(track.isDraft ? 0.22 : 0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(track.isDraft ? theme.accent.opacity(0.24) : theme.muted.opacity(0.16), lineWidth: 1)
        )
        .opacity(isOpenable || track.isDraft ? 1 : 0.72)
    }
}

private struct ProfileLibraryCover: View {
    let track: Track
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    theme.sand.opacity(0.95),
                    theme.clay.opacity(0.34),
                    theme.clayDeep.opacity(0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            switch track.kind {
            case .music, .album, .image, .video:
                CachedAsyncImage(url: track.thumbnailURL) {
                    fallbackArt
                }
            case .text, .radio:
                fallbackArt
            }

            LinearGradient(
                colors: [.clear, theme.ink.opacity(0.10)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.glow.opacity(0.34), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var fallbackArt: some View {
        VStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.muted)
            if track.kind == .text {
                Text(track.displayText.isEmpty ? "text post" : track.displayText)
                    .font(.wwav(13, weight: .light, italic: true))
                    .foregroundStyle(theme.ink.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var iconName: String {
        switch track.kind {
        case .music: return "music.note"
        case .album: return "rectangle.stack"
        case .radio: return "dot.radiowaves.left.and.right"
        case .image: return "photo"
        case .text: return "text.alignleft"
        case .video: return "play.rectangle"
        }
    }
}

private struct LibraryStateBadge: View {
    let track: Track
    @Environment(\.theme) private var theme

    var body: some View {
        StateBadge(isDraft: track.isDraft)
    }
}

private struct ProfileTrackRow: View {
    let track: Track
    let canEdit: Bool
    let onTap: () -> Void
    let onEdit: () -> Void
    @Environment(\.theme) private var theme

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// Posts become tappable as soon as they're ready. Music tracks are
    /// "ready" once the server confirms separation; image/video flip to
    /// `.ready` after upload completes; text posts are always ready.
    private var isPlayable: Bool {
        if case .ready = track.status { return true }
        return track.kind == .text
    }

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.muted.opacity(0.25), lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(track.title)
                        .wwavTitle(size: 18)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    statusBadge
                    if track.kind != .music {
                        KindBadge(label: track.kind.label)
                    }
                }
                Text(formatDate(track.createdAt) + " · \(track.plays) \(track.kind == .music || track.kind == .video ? "plays" : "views")")
                    .font(.wwav(11, weight: .light))
                    .tracking(1)
                    .monospacedDigit()
                    .foregroundStyle(theme.muted)
            }
            Spacer()

            if canEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.muted)
                        .padding(8)
                }
                .buttonStyle(.plain)
            }

            Button(action: onTap) {
                ZStack {
                    Circle().fill(
                        RadialGradient(colors: [theme.clay, theme.clayDeep],
                                       center: UnitPoint(x: 0.35, y: 0.30),
                                       startRadius: 1, endRadius: 28)
                    )
                    actionIcon
                }
                .frame(width: 36, height: 36)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(!isPlayable)
            .opacity(isPlayable ? 1.0 : 0.4)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    @ViewBuilder
    private var actionIcon: some View {
        switch track.kind {
        case .music, .album, .video:
            Triangle().fill(theme.glow).frame(width: 8, height: 10).offset(x: 1)
        case .image:
            Image(systemName: "photo")
                .font(.system(size: 12)).foregroundStyle(theme.glow)
        case .text, .radio:
            Image(systemName: "text.alignleft")
                .font(.system(size: 12)).foregroundStyle(theme.glow)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if case .ready = track.status {
            LiveBadge()
        } else if case .separating(let p) = track.status {
            Text("\(Int(p*100))%")
                .font(.wwav(10, weight: .light, italic: true))
                .foregroundStyle(theme.muted)
        } else if case .uploading(_, let p) = track.status {
            Text("\(Int(p*100))%")
                .font(.wwav(10, weight: .light, italic: true))
                .foregroundStyle(theme.muted)
        } else if case .failed = track.status {
            Text("failed")
                .font(.wwav(10, weight: .light, italic: true))
                .foregroundStyle(.red.opacity(0.6))
        }
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
                        .font(.system(size: 12)).foregroundStyle(.white)
                        .shadow(radius: 2)
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

    private func formatDate(_ d: Date) -> String {
        return Self.dateFormatter.string(from: d).lowercased()
    }
}

private struct ProfileEditSheet: View {
    @EnvironmentObject var library: TrackLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var handle = ""
    @State private var bio = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("identity") {
                    TextField("name", text: $name)
                    TextField("handle", text: $handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("bio") {
                    TextEditor(text: $bio).frame(minHeight: 80)
                }
            }
            .navigationTitle("edit profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") {
                        library.updateProfile(name: name, handle: handle, bio: bio)
                        dismiss()
                    }
                }
            }
            .onAppear {
                name = library.profile.name
                handle = library.profile.handle
                bio = library.profile.bio
            }
        }
    }
}
