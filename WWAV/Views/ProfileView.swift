import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme
    @State private var sectionTab: Int = 0  // 0 uploads / 1 waves / 2 liked
    @State private var editing = false
    @State private var showSettings = false
    @State private var editingPost: Track?

    var body: some View {
        ZStack {
            theme.pageRadial.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 16) {
                        Spacer()
                        Button { editing = true } label: {
                            Text("edit")
                                .font(.wwav(12, weight: .light, italic: true))
                                .foregroundStyle(theme.muted)
                        }
                        Button { showSettings = true } label: {
                            Text("settings")
                                .font(.wwav(12, weight: .light, italic: true))
                                .foregroundStyle(theme.muted)
                        }
                    }
                    .padding(.horizontal, 24).padding(.top, 16)

                    HStack(alignment: .bottom, spacing: 18) {
                        ProfileAvatar(url: auth.user?.profilePictureURL, size: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(library.profile.name).wwavTitle(size: 38)
                            Text("@\(library.profile.handle)")
                                .font(.wwav(12, weight: .light))
                                .tracking(1)
                                .foregroundStyle(theme.muted)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 24).padding(.top, 20)

                    if !library.profile.bio.isEmpty {
                        Text(library.profile.bio)
                            .font(.wwav(15, weight: .light))
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, 24).padding(.top, 20)
                            .frame(maxWidth: 320, alignment: .leading)
                    }

                    statsCard.padding(.horizontal, 24).padding(.top, 22)

                    HStack(spacing: 22) {
                        ForEach(Array(["uploads", "waves", "liked"].enumerated()), id: \.offset) { i, label in
                            VStack(spacing: 4) {
                                Text(label)
                                    .font(.wwav(13, weight: .light, italic: true))
                                    .foregroundStyle(sectionTab == i ? theme.ink : theme.muted)
                                Rectangle()
                                    .fill(sectionTab == i ? theme.accent : .clear)
                                    .frame(height: 1.5)
                                    .frame(maxWidth: 60)
                            }
                            .onTapGesture { withAnimation { sectionTab = i } }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 24).padding(.top, 24)

                    let tracks = sectionTab == 0 ? library.myTracks : []
                    if tracks.isEmpty {
                        VStack(spacing: 8) {
                            Text(emptyMessage(for: sectionTab))
                                .font(.wwav(13, weight: .light, italic: true))
                                .foregroundStyle(theme.muted)
                        }
                        .padding(.horizontal, 24).padding(.top, 32)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                                ProfileTrackRow(
                                    track: track,
                                    onTap: { nav.openPost(track, in: library, with: player) },
                                    onEdit: { editingPost = track }
                                )
                                if idx < tracks.count - 1 { SoftRule() }
                            }
                        }
                        .padding(.top, 6).padding(.bottom, 16)
                    }
                }
            }
            .refreshable { await library.refresh(token: auth.token) }
        }
        .task { await library.refresh(token: auth.token) }
        .sheet(isPresented: $editing) { ProfileEditSheet() }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(item: $editingPost) { post in
            EditMetadataSheet(track: post)
        }
    }

    private func emptyMessage(for tab: Int) -> String {
        switch tab {
        case 0: return "no posts yet — head to the + tab to drop your first one."
        case 1: return "no waves yet — waves are tracks you've remixed via stems."
        default: return "no likes yet."
        }
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
                LinearGradient(colors: [theme.sand, theme.sandDeep.opacity(0.6)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        )
        .overlay(RoundedRectangle(cornerRadius: 18)
                    .stroke(theme.muted.opacity(0.18), lineWidth: 1))
    }

    private func stat(_ n: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(n).wwavTitle(size: 26)
            Text(label).wwavLabel(size: 10, tracking: 1.5)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
    }
    private var divider: some View {
        Rectangle().fill(theme.muted.opacity(0.20)).frame(width: 1)
    }

    private func short(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
        return "\(n)"
    }
}

private struct ProfileTrackRow: View {
    let track: Track
    let onTap: () -> Void
    let onEdit: () -> Void
    @Environment(\.theme) private var theme

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
                    Text(track.title).wwavTitle(size: 19).lineLimit(1)
                    statusBadge
                    if track.kind != .music {
                        Text(track.kind.label)
                            .font(.wwav(9, weight: .medium)).tracking(1.2)
                            .foregroundStyle(theme.muted)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(theme.muted.opacity(0.14)))
                    }
                }
                Text(formatDate(track.createdAt) + " · \(track.plays) \(track.kind == .text || track.kind == .image ? "views" : "plays")")
                    .font(.wwav(11, weight: .light))
                    .tracking(1)
                    .foregroundStyle(theme.muted)
            }
            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.muted)
                    .padding(8)
            }
            .buttonStyle(.plain)

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
        case .music, .video:
            Triangle().fill(theme.glow).frame(width: 8, height: 10).offset(x: 1)
        case .image:
            Image(systemName: "photo")
                .font(.system(size: 12)).foregroundStyle(theme.glow)
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 12)).foregroundStyle(theme.glow)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if case .ready = track.status {
            Text("LIVE")
                .font(.wwav(9, weight: .medium))
                .tracking(1.5).foregroundStyle(theme.glow)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: [theme.accent, theme.clayDeep],
                        startPoint: .top, endPoint: .bottom))
                )
        } else if case .separating(let p) = track.status {
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
        case .music, .video, .image:
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
        case .text:
            ZStack {
                LinearGradient(colors: [theme.sand, theme.sandDeep.opacity(0.6)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "text.alignleft")
                    .font(.system(size: 16)).foregroundStyle(theme.muted)
            }
        }
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: d).lowercased()
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
