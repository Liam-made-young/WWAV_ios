import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private let uploadComposerKinds: [PostKind] = [.music, .radio, .image, .text, .video]

struct UploadView: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme

    @State private var selectedKind: PostKind = .music

    var body: some View {
        ZStack {
            theme.centerRadial.ignoresSafeArea()
            VStack(spacing: 0) {
                kindPicker
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                Group {
                    switch selectedKind {
                    case .music: MusicUploadForm()
                    case .album: AlbumUploadForm()
                    case .radio: RadioUploadForm()
                    case .image: ImageUploadForm()
                    case .text: TextUploadForm()
                    case .video: VideoUploadForm()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { consumeRequestedKind(animated: false) }
        .onChange(of: nav.requestedUploadKind) { _, _ in
            consumeRequestedKind(animated: true)
        }
    }

    private var kindPicker: some View {
        HStack(spacing: 6) {
            ForEach(uploadComposerKinds) { kind in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selectedKind = kind }
                } label: {
                    let active = selectedKind == kind
                    Text(kind.label)
                        .font(.wwav(12, weight: active ? .medium : .light, italic: true))
                        .tracking(1.5)
                        .foregroundStyle(active ? theme.glow : theme.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(
                                active
                                    ? AnyShapeStyle(
                                        LinearGradient(
                                            colors: [theme.clay, theme.clayDeep],
                                            startPoint: .top, endPoint: .bottom))
                                    : AnyShapeStyle(theme.muted.opacity(0.10))
                            )
                        )
                        .overlay(
                            Capsule().stroke(theme.muted.opacity(active ? 0 : 0.25), lineWidth: 1)
                        )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func consumeRequestedKind(animated: Bool) {
        guard let requested = nav.requestedUploadKind else { return }
        let target: PostKind = requested == .album ? .music : requested
        if animated {
            withAnimation(.easeInOut(duration: 0.18)) { selectedKind = target }
        } else {
            selectedKind = target
        }
        nav.requestedUploadKind = nil
    }
}

// MARK: – Shared big-circle entry button
//
// All four upload kinds open the same way: a large gradient circle with a
// glowing plus inside, a centered title, and a subtitle of supported
// media. Music/text use a tappable Button; image/video wrap the same
// visual in a real `PhotosPicker` so the system picker is the direct tap
// target — that's the only way `.photosPicker` reliably opens for some
// device + iOS combinations.

struct BigCircleVisual: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [theme.sand, theme.clay, theme.clayDeep],
                        center: UnitPoint(x: 0.38, y: 0.28),
                        startRadius: 6, endRadius: 220
                    )
                )
                .shadow(color: .black.opacity(0.30), radius: 28, y: 22)
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [theme.glow.opacity(0.55), .clear],
                        center: UnitPoint(x: 0.5, y: 0.3),
                        startRadius: 0, endRadius: 110
                    )
                )
                .frame(width: 130, height: 90).offset(y: -55).blur(radius: 8)
            ZStack {
                Capsule().fill(theme.glow).frame(width: 3, height: 56)
                Capsule().fill(theme.glow).frame(width: 56, height: 3)
            }
            .shadow(color: theme.glow.opacity(0.75), radius: 12)
        }
        .frame(width: 220, height: 220)
    }
}

/// Tappable variant for music (file picker) and text (modal).
struct BigCircleEntry: View {
    let title: String
    let subtitle: String
    let kicker: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Text(kicker).wwavLabel(size: 11, tracking: 2.5)
            Button(action: action) { BigCircleVisual() }
                .buttonStyle(.plain)
            Text(title)
                .wwavTitle(size: 26)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Text(subtitle)
                .font(.wwav(11, weight: .light)).tracking(1.5)
                .foregroundStyle(theme.muted)
            Spacer()
        }
        .padding(.horizontal, 28)
    }
}

/// Visual + label scaffold reused around a real `PhotosPicker` so the
/// circle itself is the picker's tap target.
private struct BigCirclePickerScaffold<P: View>: View {
    let kicker: String
    let title: String
    let subtitle: String
    @ViewBuilder var picker: () -> P
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Text(kicker).wwavLabel(size: 11, tracking: 2.5)
            picker()
                .buttonStyle(.plain)
            Text(title)
                .wwavTitle(size: 26)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Text(subtitle)
                .font(.wwav(11, weight: .light)).tracking(1.5)
                .foregroundStyle(theme.muted)
            Spacer()
        }
        .padding(.horizontal, 28)
    }
}

// MARK: – Music upload (existing flow)

private let audioTypes: [UTType] = {
    var types: [UTType] = [.audio, .wav, .mp3, .mpeg4Audio, .aiff]
    if let flac = UTType("public.flac") { types.append(flac) }
    return types
}()

private struct MusicUploadForm: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme

    @State private var entryPickerOpen: Bool = false
    @State private var pickerOpen: Bool = false
    @State private var recorderOpen: Bool = false
    @State private var pickedFile: PickedFile?
    @State private var multitrackDraft: MultitrackDraft?
    @State private var title: String = ""
    @State private var bio: String = ""
    @State private var inFlightID: UUID?
    @State private var coverItem: PhotosPickerItem?
    @State private var coverImage: UIImage?
    @State private var coverData: Data?
    @State private var albumMode: Bool = false
    @State private var albumTitle: String = ""
    @State private var albumCaption: String = ""
    @State private var albumTrackIds: [UUID] = []
    @State private var albumCoverItem: PhotosPickerItem?
    @State private var albumCoverImage: UIImage?
    @State private var albumCoverData: Data?

    private var hasSource: Bool {
        pickedFile != nil || multitrackDraft != nil
    }

    var body: some View {
        Group {
            if !hasSource {
                BigCircleEntry(
                    title: "drop a track. start a wave.",
                    subtitle: "files · single recording · multitrack",
                    kicker: "upload a wav"
                ) {
                    entryPickerOpen = true
                }
            } else {
                ScrollView { filled.padding(.bottom, 16) }
            }
        }
        .confirmationDialog(
            "add a track",
            isPresented: $entryPickerOpen,
            titleVisibility: .visible
        ) {
            Button("look in files") { pickerOpen = true }
            Button("record now") { recorderOpen = true }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("choose an audio file or record inside WWAV.")
        }
        .fileImporter(
            isPresented: $pickerOpen,
            allowedContentTypes: audioTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                pickedFile = PickedFile(url: url)
                multitrackDraft = nil
                if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
            }
        }
        .sheet(isPresented: $recorderOpen) {
            RecordNowSheet(
                onSingleRecording: { url in
                    pickedFile = PickedFile(url: url)
                    multitrackDraft = nil
                    if title.isEmpty { title = "recorded take" }
                },
                onMultitrackRecording: { stems in
                    multitrackDraft = MultitrackDraft(stemURLs: stems)
                    pickedFile = nil
                    if title.isEmpty { title = "multitrack take" }
                }
            )
        }
    }

    private var filled: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button {
                    cancel()
                } label: {
                    Text("← cancel")
                        .font(.wwav(12, weight: .light, italic: true))
                        .tracking(1.5).foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("new track").wwavLabel(size: 11, tracking: 2.5)
            }
            .padding(.top, 4)

            Text("new track").wwavTitle(size: 40)

            UploadField(label: "cover art") {
                CoverPickerRow(
                    coverItem: $coverItem,
                    coverImage: $coverImage,
                    coverData: $coverData
                )
            }

            UploadField(label: "song title") {
                TextField("", text: $title, prompt: Text("untitled").foregroundStyle(theme.muted))
                    .font(.wwav(24, weight: .light, italic: true))
                    .foregroundStyle(theme.ink)
                    .padding(.vertical, 8)
                    .overlay(
                        Rectangle().fill(theme.muted.opacity(0.3)).frame(height: 1),
                        alignment: .bottom)
            }

            UploadField(label: "bio / notes") {
                TextEditor(text: $bio)
                    .scrollContentBackground(.hidden)
                    .font(.wwav(15, weight: .light))
                    .foregroundStyle(theme.ink)
                    .frame(minHeight: 84, maxHeight: 120)
                    .padding(12)
                    .background(boxBg)
                    .overlay(boxStroke)
            }

            UploadField(label: sourceLabel) {
                sourceRow
            }

            albumToggle
            if albumMode { albumSection }

            statusRow
            Spacer(minLength: 8)
            uploadButton
        }
        .padding(.horizontal, 28).padding(.top, 12)
    }

    private var boxBg: some View {
        RoundedRectangle(cornerRadius: 14).fill(
            LinearGradient(
                colors: [theme.clay.opacity(0.18), theme.clayDeep.opacity(0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
    private var boxStroke: some View {
        RoundedRectangle(cornerRadius: 14).stroke(theme.muted.opacity(0.40), lineWidth: 1)
    }

    private var sourceLabel: String {
        multitrackDraft == nil ? "song file" : "stem files"
    }

    @ViewBuilder
    private var sourceRow: some View {
        if let f = pickedFile {
            HStack(spacing: 14) {
                sourceBadge(text: f.url.pathExtension.uppercased().isEmpty ? "WAV" : f.url.pathExtension.uppercased())
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.url.lastPathComponent)
                        .font(.wwav(14, weight: .regular)).foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text("split into stems after upload · \(f.subtitle)")
                        .font(.wwav(11, weight: .light)).foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
                Spacer()
                clearSourceButton
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(boxBg).overlay(boxStroke)
        } else if let draft = multitrackDraft {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    sourceBadge(text: "4X")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("recorded multitrack")
                            .font(.wwav(14, weight: .regular)).foregroundStyle(theme.ink)
                        Text("uses the four stem-player lanes")
                            .font(.wwav(11, weight: .light)).foregroundStyle(theme.muted)
                    }
                    Spacer()
                    clearSourceButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                ForEach(StemKind.allCases) { kind in
                    HStack(spacing: 10) {
                        Text(kind.label)
                            .font(.wwav(10, weight: .medium))
                            .tracking(1.2)
                            .foregroundStyle(theme.muted)
                            .frame(width: 44, alignment: .leading)
                        Text(draft.stemURLs[kind]?.lastPathComponent ?? "missing")
                            .font(.wwav(12, weight: .light))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    if kind.id != (StemKind.allCases.last?.id ?? "") {
                        Rectangle().fill(theme.muted.opacity(0.12)).frame(height: 1).padding(.leading, 16)
                    }
                }
            }
            .background(boxBg).overlay(boxStroke)
        }
    }

    private func sourceBadge(text: String) -> some View {
        ZStack {
            Circle().fill(
                RadialGradient(
                    colors: [theme.clay, theme.clayDeep],
                    center: UnitPoint(x: 0.35, y: 0.30),
                    startRadius: 1, endRadius: 28)
            )
            Text(text)
                .font(.wwav(9, weight: .medium))
                .tracking(1)
                .foregroundStyle(theme.glow)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: 36, height: 36)
    }

    private var clearSourceButton: some View {
        Button {
            clearSource()
        } label: {
            Text("✕").font(.wwav(13, weight: .light)).foregroundStyle(theme.muted)
        }
        .buttonStyle(.plain)
    }

    private var albumToggle: some View {
        Toggle(isOn: $albumMode.animation(.easeInOut(duration: 0.18))) {
            VStack(alignment: .leading, spacing: 3) {
                Text("album upload")
                    .font(.wwav(14, weight: .regular, italic: true))
                    .foregroundStyle(theme.ink)
                Text("post this track as the first song on an album")
                    .font(.wwav(11, weight: .light))
                    .foregroundStyle(theme.muted)
            }
        }
        .tint(theme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(boxBg)
        .overlay(boxStroke)
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            UploadField(label: "album cover") {
                CoverPickerRow(
                    coverItem: $albumCoverItem,
                    coverImage: $albumCoverImage,
                    coverData: $albumCoverData
                )
            }

            UploadField(label: "album title") {
                TextField("", text: $albumTitle, prompt: Text(title.isEmpty ? "untitled album" : title).foregroundStyle(theme.muted))
                    .font(.wwav(24, weight: .light, italic: true))
                    .foregroundStyle(theme.ink)
                    .padding(.vertical, 8)
                    .overlay(
                        Rectangle().fill(theme.muted.opacity(0.3)).frame(height: 1),
                        alignment: .bottom)
            }

            UploadField(label: "album caption") {
                TextEditor(text: $albumCaption)
                    .scrollContentBackground(.hidden)
                    .font(.wwav(15, weight: .light))
                    .foregroundStyle(theme.ink)
                    .frame(minHeight: 72, maxHeight: 110)
                    .padding(12)
                    .background(boxBg)
                    .overlay(boxStroke)
            }

            if library.albumCandidateTracks.isEmpty {
                Text("this upload will start the album. add more tracks later from your library.")
                    .font(.wwav(12, weight: .light, italic: true))
                    .foregroundStyle(theme.muted)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(boxBg)
                    .overlay(boxStroke)
            } else {
                TrackQueueEditor(
                    title: "additional tracks",
                    emptyMessage: "this upload starts the album; add more songs if you want",
                    tracks: library.albumCandidateTracks,
                    selectedIDs: $albumTrackIds
                )
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if let id = inFlightID,
            let track = library.myTracks.first(where: { $0.id == id })
        {
            switch track.status {
            case .separating(let p): UploadProgressRow(p: p)
            case .ready:
                Button {
                    nav.openPost(track, in: library, with: player)
                } label: {
                    Text("✓ stems ready — open in player")
                        .font(.wwav(13, weight: .light, italic: true))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
            case .failed(let msg):
                Text("✕ \(msg)")
                    .font(.wwav(12, weight: .light)).foregroundStyle(Color.red.opacity(0.7))
            case .uploading: EmptyView()
            case .sourceOnly: EmptyView()
            }
        }
    }

    private var uploadButton: some View {
        Button {
            submit()
        } label: {
            Text(uploadButtonTitle)
                .font(.wwav(15, weight: .regular, italic: true)).tracking(2)
                .foregroundStyle(theme.glow)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [theme.clay, theme.clayDeep],
                            startPoint: .top, endPoint: .bottom))
                )
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain).disabled(inFlightID != nil).opacity(inFlightID != nil ? 0.7 : 1.0)
    }

    private var uploadButtonTitle: String {
        if inFlightID != nil { return multitrackDraft == nil ? "uploading…" : "posted" }
        if albumMode { return "upload track + album" }
        return multitrackDraft == nil ? "upload track" : "post multitrack"
    }

    private func submit() {
        let id: UUID
        if let f = pickedFile {
            id = library.startUpload(
                sourceURL: f.url,
                title: title.isEmpty ? "untitled" : title,
                bio: bio,
                coverImage: coverData,
                token: auth.token
            )
        } else if let draft = multitrackDraft {
            id = library.startMultitrackUpload(
                stemURLs: draft.stemURLs,
                title: title.isEmpty ? "untitled" : title,
                bio: bio,
                coverImage: coverData,
                token: auth.token
            )
        } else {
            return
        }

        inFlightID = id

        if albumMode {
            let finalAlbumTitle = albumTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (title.isEmpty ? "untitled album" : title)
                : albumTitle
            _ = library.createAlbumPost(
                title: finalAlbumTitle,
                caption: albumCaption,
                trackIds: [id] + albumTrackIds,
                coverImage: albumCoverData ?? coverData,
                token: auth.token
            )
        }
    }

    private func cancel() {
        pickedFile = nil
        multitrackDraft = nil
        title = ""
        bio = ""
        inFlightID = nil
        coverItem = nil
        coverImage = nil
        coverData = nil
        albumMode = false
        albumTitle = ""
        albumCaption = ""
        albumTrackIds = []
        albumCoverItem = nil
        albumCoverImage = nil
        albumCoverData = nil
    }

    private func clearSource() {
        pickedFile = nil
        multitrackDraft = nil
        inFlightID = nil
    }
}

private struct MultitrackDraft: Equatable {
    let stemURLs: [StemKind: URL]
}


// MARK: – Album upload (groups existing songs)

private struct AlbumUploadForm: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme

    @State private var title: String = ""
    @State private var caption: String = ""
    @State private var selectedTrackIds: [UUID] = []
    @State private var coverItem: PhotosPickerItem?
    @State private var coverImage: UIImage?
    @State private var coverData: Data?
    @State private var lastPostedAt: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("new album").wwavLabel(size: 11, tracking: 2.5)
                    Spacer()
                    if let posted = lastPostedAt, Date().timeIntervalSince(posted) < 6 {
                        Text("posted")
                            .font(.wwav(11, weight: .light, italic: true))
                            .foregroundStyle(theme.accent)
                    }
                }
                .padding(.top, 4)

                Text("group songs into an album.")
                    .wwavTitle(size: 36)

                if library.albumCandidateTracks.isEmpty {
                    Text("upload songs first, then come back here to assemble the album tracklist.")
                        .font(.wwav(14, weight: .light, italic: true))
                        .foregroundStyle(theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(SheetBox.bg(theme))
                        .overlay(SheetBox.stroke(theme))
                } else {
                    UploadField(label: "cover art") {
                        CoverPickerRow(
                            coverItem: $coverItem,
                            coverImage: $coverImage,
                            coverData: $coverData
                        )
                    }

                    UploadField(label: "album title") {
                        TextField("", text: $title, prompt: Text("untitled album").foregroundStyle(theme.muted))
                            .font(.wwav(24, weight: .light, italic: true))
                            .foregroundStyle(theme.ink)
                            .padding(.vertical, 8)
                            .overlay(
                                Rectangle().fill(theme.muted.opacity(0.3)).frame(height: 1),
                                alignment: .bottom
                            )
                    }

                    UploadField(label: "caption / notes") {
                        TextEditor(text: $caption)
                            .scrollContentBackground(.hidden)
                            .font(.wwav(15, weight: .light))
                            .foregroundStyle(theme.ink)
                            .frame(minHeight: 84, maxHeight: 140)
                            .padding(12)
                            .background(SheetBox.bg(theme))
                            .overlay(SheetBox.stroke(theme))
                    }

                    TrackQueueEditor(
                        title: "tracklist",
                        emptyMessage: "choose the songs for this album",
                        tracks: library.albumCandidateTracks,
                        selectedIDs: $selectedTrackIds
                    )

                    Button {
                        _ = library.createAlbumPost(
                            title: title,
                            caption: caption,
                            trackIds: selectedTrackIds,
                            coverImage: coverData,
                            token: auth.token
                        )
                        title = ""
                        caption = ""
                        selectedTrackIds = []
                        coverItem = nil
                        coverImage = nil
                        coverData = nil
                        lastPostedAt = Date()
                    } label: {
                        Text("post album")
                            .font(.wwav(15, weight: .regular, italic: true))
                            .tracking(2)
                            .foregroundStyle(theme.glow)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                Capsule().fill(
                                    LinearGradient(
                                        colors: [theme.clay, theme.clayDeep],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            )
                            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedTrackIds.isEmpty)
                    .opacity(selectedTrackIds.isEmpty ? 0.5 : 1)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }
}

// MARK: – Radio upload form

struct RadioUploadForm: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.theme) private var theme

    @State private var sessionId: UUID?
    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var queueTrackIds: [UUID] = []
    @State private var savedAt: Date?

    private var mySession: RadioSession? {
        if let sessionId,
           let session = library.radioSessions.first(where: { $0.id == sessionId }) {
            return session
        }
        return library.radioSessions.first { session in
            normalize(session.hostHandle) == normalize(library.profile.handle)
        }
    }

    private var currentTrack: Track? {
        guard let mySession else { return nil }
        return library.currentTrack(for: mySession)
    }

    var body: some View {
        ZStack {
            theme.pageRadial.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if library.albumCandidateTracks.isEmpty {
                        emptyLibrary
                    } else {
                        if let mySession, mySession.isLive {
                            onAirCard(mySession)
                        }

                        fields

                        TrackQueueEditor(
                            title: "queue playlist",
                            emptyMessage: "add songs to queue before going live",
                            tracks: library.albumCandidateTracks,
                            selectedIDs: $queueTrackIds
                        )

                        controls
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
        }
        .onAppear { hydrateFromSession() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            RadioPulseMark()
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text("radio").wwavTitle(size: 42)
                Text("audio-only live queue")
                    .font(.wwav(11, weight: .light))
                    .tracking(1.5)
                    .foregroundStyle(theme.muted)
            }
            Spacer()
            if mySession?.isLive == true {
                Text("on air")
                    .font(.wwav(10, weight: .medium, italic: true))
                    .tracking(1.5)
                    .foregroundStyle(theme.glow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.accent))
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("no songs ready")
                .wwavTitle(size: 24)
            Text("upload music first, then build a radio queue from those songs.")
                .font(.wwav(14, weight: .light, italic: true))
                .foregroundStyle(theme.muted)
            Button {
                nav.compose(.music)
            } label: {
                Text("upload music")
                    .font(.wwav(13, weight: .medium, italic: true))
                    .tracking(1.4)
                    .foregroundStyle(theme.glow)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(16)
        .background(radioBg)
        .overlay(radioStroke)
    }

    private func onAirCard(_ session: RadioSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("live now").wwavLabel(size: 10, tracking: 2)
            if let currentTrack {
                HStack(spacing: 12) {
                    ZStack {
                        LinearGradient(
                            colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        CachedAsyncImage(url: currentTrack.thumbnailURL) { Color.clear }
                    }
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.muted.opacity(0.22), lineWidth: 1))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentTrack.title)
                            .wwavTitle(size: 23)
                            .lineLimit(1)
                        Text("@\(currentTrack.handle) · \(session.queueTrackIds.count) in queue")
                            .font(.wwav(11, weight: .light))
                            .tracking(1)
                            .foregroundStyle(theme.muted)
                    }

                    Spacer(minLength: 0)
                    Button {
                        nav.openPost(currentTrack, in: library, with: player)
                    } label: {
                        ZStack {
                            Circle().fill(theme.accent)
                            Triangle().fill(theme.glow).frame(width: 9, height: 11).offset(x: 1)
                        }
                        .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(radioBg)
        .overlay(radioStroke)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            radioField(label: "stream title") {
                TextField("", text: $title, prompt: Text("late night wwav").foregroundStyle(theme.muted))
                    .font(.wwav(23, weight: .light, italic: true))
                    .foregroundStyle(theme.ink)
                    .padding(.vertical, 8)
                    .overlay(Rectangle().fill(theme.muted.opacity(0.3)).frame(height: 1), alignment: .bottom)
            }
            radioField(label: "notes") {
                TextEditor(text: $notes)
                    .scrollContentBackground(.hidden)
                    .font(.wwav(15, weight: .light))
                    .foregroundStyle(theme.ink)
                    .frame(minHeight: 76, maxHeight: 120)
                    .padding(12)
                    .background(radioBg)
                    .overlay(radioStroke)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                goLiveOrSave()
            } label: {
                Text(mySession?.isLive == true ? "save queue" : "go live")
                    .font(.wwav(15, weight: .regular, italic: true))
                    .tracking(2)
                    .foregroundStyle(theme.glow)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    )
            }
            .buttonStyle(.plain)
            .disabled(queueTrackIds.isEmpty)
            .opacity(queueTrackIds.isEmpty ? 0.5 : 1)

            if let mySession {
                HStack(spacing: 10) {
                    Button {
                        library.advanceRadio(id: mySession.id)
                    } label: {
                        radioControlPill("next")
                    }
                    .buttonStyle(.plain)
                    .disabled(!mySession.isLive || mySession.queueTrackIds.count < 2)
                    .opacity(mySession.isLive && mySession.queueTrackIds.count > 1 ? 1 : 0.45)

                    Button {
                        library.stopRadio(id: mySession.id)
                        hydrateFromSession()
                    } label: {
                        radioControlPill("end live")
                    }
                    .buttonStyle(.plain)
                    .disabled(!mySession.isLive)
                    .opacity(mySession.isLive ? 1 : 0.45)
                }
            }

            if let savedAt, Date().timeIntervalSince(savedAt) < 5 {
                Text("saved")
                    .font(.wwav(11, weight: .light, italic: true))
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.top, 4)
    }

    private func radioField<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).wwavLabel(size: 10, tracking: 2)
            content()
        }
    }

    private func radioControlPill(_ text: String) -> some View {
        Text(text)
            .font(.wwav(12, weight: .medium, italic: true))
            .tracking(1.4)
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Capsule().fill(theme.sand.opacity(0.66)))
            .overlay(Capsule().stroke(theme.muted.opacity(0.20), lineWidth: 1))
    }

    private var radioBg: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.sand.opacity(0.64))
    }

    private var radioStroke: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(theme.muted.opacity(0.22), lineWidth: 1)
    }

    private func goLiveOrSave() {
        if let mySession {
            library.updateRadioSession(
                id: mySession.id,
                title: title,
                notes: notes,
                queueTrackIds: queueTrackIds
            )
            if !mySession.isLive {
                sessionId = library.startRadio(title: title, notes: notes, queueTrackIds: queueTrackIds)
            }
        } else {
            sessionId = library.startRadio(title: title, notes: notes, queueTrackIds: queueTrackIds)
        }
        savedAt = Date()
        hydrateFromSession()
    }

    private func hydrateFromSession() {
        guard let session = mySession else {
            if title.isEmpty { title = "\(library.profile.name)'s radio" }
            return
        }
        sessionId = session.id
        title = session.title
        notes = session.notes
        queueTrackIds = session.queueTrackIds
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }
}

private struct RadioPulseMark: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [theme.accent, theme.clayDeep],
                            center: UnitPoint(x: 0.35, y: 0.25),
                            startRadius: 1,
                            endRadius: w * 0.56
                        )
                    )
                Circle()
                    .stroke(theme.glow.opacity(0.7), lineWidth: 1.2)
                    .frame(width: w * 0.34, height: w * 0.34)
                ForEach([0.52, 0.72], id: \.self) { scale in
                    Circle()
                        .trim(from: 0.12, to: 0.88)
                        .stroke(theme.glow.opacity(0.76), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .frame(width: w * scale, height: w * scale)
                        .rotationEffect(.degrees(-90))
                }
                Capsule()
                    .fill(theme.glow)
                    .frame(width: w * 0.09, height: w * 0.34)
                    .offset(y: w * 0.16)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: – Image upload (carousel)
//
// Tap the big circle → opens a PhotosPicker. After selection, the
// "details" sheet pops up over the upload tab so the user can confirm
// the carousel order, write a caption, and post.

private struct ImageUploadForm: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme

    @State private var items: [PhotosPickerItem] = []
    @State private var datas: [Data] = []
    @State private var previews: [UIImage] = []
    @State private var sheetOpen: Bool = false
    @State private var lastPostedAt: Date?

    var body: some View {
        ZStack {
            BigCirclePickerScaffold(
                kicker: "image post",
                title: "share a moment.",
                subtitle: "up to 10 images · jpg · png · heic"
            ) {
                PhotosPicker(
                    selection: $items,
                    maxSelectionCount: 10,
                    matching: .images,
                    preferredItemEncoding: .compatible,
                    photoLibrary: .shared()
                ) {
                    BigCircleVisual()
                }
            }

            if let posted = lastPostedAt, Date().timeIntervalSince(posted) < 6 {
                VStack {
                    Spacer()
                    Text("✓ posted")
                        .font(.wwav(13, weight: .light, italic: true))
                        .foregroundStyle(theme.accent)
                        .padding(.bottom, 24)
                }
            }
        }
        .onChange(of: items) { _, new in
            Task { await load(from: new) }
        }
        .sheet(
            isPresented: $sheetOpen,
            onDismiss: {
                items = []
                datas = []
                previews = []
            }
        ) {
            ImageDetailsSheet(
                previews: previews,
                onPost: { title, caption in
                    _ = library.createImagePost(
                        images: datas, title: title, caption: caption, token: auth.token
                    )
                    lastPostedAt = Date()
                    sheetOpen = false
                }
            )
        }
    }

    private func load(from items: [PhotosPickerItem]) async {
        var newDatas: [Data] = []
        var newPreviews: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
                let img = UIImage(data: data)
            {
                let jpeg = img.jpegData(compressionQuality: 0.85) ?? data
                newDatas.append(jpeg)
                newPreviews.append(img)
            }
        }
        await MainActor.run {
            self.datas = newDatas
            self.previews = newPreviews
            self.sheetOpen = !newPreviews.isEmpty
        }
    }
}

// MARK: – Text upload
//
// Tap the big circle → opens a sheet with title + body fields. No picker
// needed — text is born inside the modal.

private struct TextUploadForm: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme

    @State private var sheetOpen: Bool = false
    @State private var lastPostedAt: Date?

    var body: some View {
        ZStack {
            BigCircleEntry(
                title: "write something. say it loud.",
                subtitle: "thoughts · notes · short form",
                kicker: "text post"
            ) {
                sheetOpen = true
            }
            if let posted = lastPostedAt, Date().timeIntervalSince(posted) < 6 {
                VStack {
                    Spacer()
                    Text("✓ posted")
                        .font(.wwav(13, weight: .light, italic: true))
                        .foregroundStyle(theme.accent)
                        .padding(.bottom, 24)
                }
            }
        }
        .sheet(isPresented: $sheetOpen) {
            TextDetailsSheet { title, body in
                _ = library.createTextPost(title: title, body: body, token: auth.token)
                lastPostedAt = Date()
                sheetOpen = false
            }
        }
    }
}

// MARK: – Video upload
//
// Tap the big circle → PhotosPicker (movies). After selection, sheet pops
// up to collect cover art + title + caption, then posts.

private struct VideoUploadForm: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme

    @State private var videoItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var loading: Bool = false
    @State private var loadError: String?
    @State private var sheetOpen: Bool = false
    @State private var lastPostedAt: Date?
    @State private var inFlightID: UUID?

    private var inflightVideo: Track? {
        guard let id = inFlightID else { return nil }
        return library.myTracks.first(where: { $0.id == id })
    }

    var body: some View {
        ZStack {
            BigCirclePickerScaffold(
                kicker: "video post",
                title: "drop a clip. take the screen.",
                subtitle: "mp4 · mov · 9:16 looks best"
            ) {
                PhotosPicker(
                    selection: $videoItem,
                    matching: .videos,
                    preferredItemEncoding: .compatible,
                    photoLibrary: .shared()
                ) {
                    BigCircleVisual()
                }
            }

            VStack {
                Spacer()
                if loading {
                    Text("preparing video…")
                        .font(.wwav(12, weight: .light, italic: true))
                        .foregroundStyle(theme.muted)
                        .padding(.bottom, 24)
                } else if let err = loadError {
                    Text("✕ \(err)")
                        .font(.wwav(12, weight: .light, italic: true))
                        .foregroundStyle(Color.red.opacity(0.8))
                        .padding(.horizontal, 24).padding(.bottom, 24)
                        .multilineTextAlignment(.center)
                } else if let track = inflightVideo {
                    switch track.status {
                    case .uploading:
                        UploadPhaseProgressRow(status: track.status)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 24)
                    case .ready:
                        Text("✓ posted")
                            .font(.wwav(13, weight: .light, italic: true))
                            .foregroundStyle(theme.accent)
                            .padding(.bottom, 24)
                    case .failed(let msg):
                        Text("✕ \(msg)")
                            .font(.wwav(12, weight: .light, italic: true))
                            .foregroundStyle(Color.red.opacity(0.8))
                            .padding(.horizontal, 24).padding(.bottom, 24)
                            .multilineTextAlignment(.center)
                    default:
                        EmptyView()
                    }
                } else if let posted = lastPostedAt, Date().timeIntervalSince(posted) < 6 {
                    Text("✓ posted")
                        .font(.wwav(13, weight: .light, italic: true))
                        .foregroundStyle(theme.accent)
                        .padding(.bottom, 24)
                }
            }
        }
        .onChange(of: videoItem) { _, item in
            Task { await loadVideo(from: item) }
        }
        .sheet(
            isPresented: $sheetOpen,
            onDismiss: {
                videoItem = nil
                videoURL = nil
            }
        ) {
            VideoDetailsSheet(
                videoURL: videoURL,
                onPost: { title, caption, coverData in
                    guard let url = videoURL else { return }
                    inFlightID = library.createVideoPost(
                        videoURL: url, title: title, caption: caption,
                        coverImage: coverData, token: auth.token
                    )
                    lastPostedAt = Date()
                    sheetOpen = false
                }
            )
        }
    }

    /// Loads the picked video into a stable temporary file URL. Tries the
    /// `Transferable` FileRepresentation first (best for big files: streams
    /// the source rather than allocating it in memory). Falls back to `Data`
    /// if the file path isn't available — some PhotosPicker results return
    /// only an in-memory representation, particularly for slow-mo or
    /// recently-edited clips.
    private func loadVideo(from item: PhotosPickerItem?) async {
        guard let item else { return }
        await MainActor.run {
            self.loading = true
            self.loadError = nil
        }

        if let url = await tryFileTransfer(item: item) {
            await MainActor.run {
                self.videoURL = url
                self.loading = false
                self.sheetOpen = true
            }
            return
        }

        if let url = await tryDataFallback(item: item) {
            await MainActor.run {
                self.videoURL = url
                self.loading = false
                self.sheetOpen = true
            }
            return
        }

        await MainActor.run {
            self.loading = false
            self.loadError = "couldn't load this video. try a different clip."
        }
    }

    private func tryFileTransfer(item: PhotosPickerItem) async -> URL? {
        do {
            if let v = try await item.loadTransferable(type: PickedVideo.self) {
                return v.url
            }
        } catch {
            print("[Upload] FileRepresentation video load failed: \(error)")
        }
        return nil
    }

    private func tryDataFallback(item: PhotosPickerItem) async -> URL? {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("wwav-video-\(UUID().uuidString).mov")
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            print("[Upload] Data fallback video load failed: \(error)")
            return nil
        }
    }
}

// MARK: – Sheets that collect post details after the picker

private struct ImageDetailsSheet: View {
    let previews: [UIImage]
    let onPost: (_ title: String, _ caption: String) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var caption: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                theme.pageRadial.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("image post").wwavTitle(size: 36)

                        // Carousel preview at the top so the user sees what's
                        // actually being posted before captioning.
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(previews.enumerated()), id: \.offset) { _, img in
                                    Image(uiImage: img)
                                        .resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 110, height: 110)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }

                        UploadField(label: "title (optional)") {
                            TextField(
                                "", text: $title,
                                prompt: Text("untitled").foregroundStyle(theme.muted)
                            )
                            .font(.wwav(22, weight: .light, italic: true))
                            .foregroundStyle(theme.ink).padding(.vertical, 8)
                            .overlay(
                                Rectangle().fill(theme.muted.opacity(0.3)).frame(height: 1),
                                alignment: .bottom)
                        }

                        UploadField(label: "caption") {
                            TextEditor(text: $caption)
                                .scrollContentBackground(.hidden)
                                .font(.wwav(15, weight: .light)).foregroundStyle(theme.ink)
                                .frame(minHeight: 100, maxHeight: 180)
                                .padding(12).background(SheetBox.bg(theme)).overlay(
                                    SheetBox.stroke(theme))
                        }

                        Button {
                            onPost(title, caption)
                        } label: {
                            Text("post images")
                                .font(.wwav(15, weight: .regular, italic: true)).tracking(2)
                                .foregroundStyle(theme.glow).frame(maxWidth: .infinity).padding(
                                    .vertical, 16
                                )
                                .background(
                                    Capsule().fill(
                                        LinearGradient(
                                            colors: [theme.clay, theme.clayDeep],
                                            startPoint: .top, endPoint: .bottom))
                                )
                                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                        }
                        .buttonStyle(.plain).padding(.top, 8)
                    }
                    .padding(.horizontal, 28).padding(.vertical, 24)
                }
            }
            .navigationTitle("new image post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
            }
        }
    }
}

private struct TextDetailsSheet: View {
    let onPost: (_ title: String, _ body: String) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var body_: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                theme.pageRadial.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("text post").wwavTitle(size: 36)

                        UploadField(label: "title (optional)") {
                            TextField(
                                "", text: $title,
                                prompt: Text("untitled").foregroundStyle(theme.muted)
                            )
                            .font(.wwav(22, weight: .light, italic: true))
                            .foregroundStyle(theme.ink).padding(.vertical, 8)
                            .overlay(
                                Rectangle().fill(theme.muted.opacity(0.3)).frame(height: 1),
                                alignment: .bottom)
                        }

                        UploadField(label: "what's happening") {
                            TextEditor(text: $body_)
                                .scrollContentBackground(.hidden)
                                .font(.wwav(17, weight: .light)).foregroundStyle(theme.ink)
                                .frame(minHeight: 240, maxHeight: 420)
                                .padding(12).background(SheetBox.bg(theme)).overlay(
                                    SheetBox.stroke(theme))
                        }

                        Text("\(body_.count) chars")
                            .font(.wwav(11, weight: .light)).foregroundStyle(theme.muted)

                        Button {
                            onPost(title, body_)
                        } label: {
                            Text("post")
                                .font(.wwav(15, weight: .regular, italic: true)).tracking(2)
                                .foregroundStyle(theme.glow).frame(maxWidth: .infinity).padding(
                                    .vertical, 16
                                )
                                .background(
                                    Capsule().fill(
                                        LinearGradient(
                                            colors: [theme.clay, theme.clayDeep],
                                            startPoint: .top, endPoint: .bottom))
                                )
                                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(
                            body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? 0.5 : 1.0
                        )
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 28).padding(.vertical, 24)
                }
            }
            .navigationTitle("new text post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
            }
        }
    }
}

private struct VideoDetailsSheet: View {
    let videoURL: URL?
    let onPost: (_ title: String, _ caption: String, _ coverData: Data?) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var caption: String = ""
    @State private var coverItem: PhotosPickerItem?
    @State private var coverImage: UIImage?
    @State private var coverData: Data?

    var body: some View {
        NavigationStack {
            ZStack {
                theme.pageRadial.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("video post").wwavTitle(size: 36)

                        if let url = videoURL {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle().fill(
                                        RadialGradient(
                                            colors: [theme.clay, theme.clayDeep],
                                            center: UnitPoint(x: 0.35, y: 0.30),
                                            startRadius: 1, endRadius: 28)
                                    )
                                    Image(systemName: "video.fill")
                                        .font(.system(size: 14)).foregroundStyle(theme.glow)
                                }
                                .frame(width: 36, height: 36)
                                Text(url.lastPathComponent)
                                    .font(.wwav(13, weight: .light)).foregroundStyle(theme.ink)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(12)
                            .background(SheetBox.bg(theme))
                            .overlay(SheetBox.stroke(theme))
                        }

                        UploadField(label: "cover art (optional)") {
                            CoverPickerRow(
                                coverItem: $coverItem,
                                coverImage: $coverImage,
                                coverData: $coverData
                            )
                        }

                        UploadField(label: "title") {
                            TextField(
                                "", text: $title,
                                prompt: Text("untitled").foregroundStyle(theme.muted)
                            )
                            .font(.wwav(22, weight: .light, italic: true))
                            .foregroundStyle(theme.ink).padding(.vertical, 8)
                            .overlay(
                                Rectangle().fill(theme.muted.opacity(0.3)).frame(height: 1),
                                alignment: .bottom)
                        }

                        UploadField(label: "caption") {
                            TextEditor(text: $caption)
                                .scrollContentBackground(.hidden)
                                .font(.wwav(15, weight: .light)).foregroundStyle(theme.ink)
                                .frame(minHeight: 100, maxHeight: 180)
                                .padding(12).background(SheetBox.bg(theme)).overlay(
                                    SheetBox.stroke(theme))
                        }

                        Button {
                            onPost(title, caption, coverData)
                        } label: {
                            Text("post video")
                                .font(.wwav(15, weight: .regular, italic: true)).tracking(2)
                                .foregroundStyle(theme.glow).frame(maxWidth: .infinity).padding(
                                    .vertical, 16
                                )
                                .background(
                                    Capsule().fill(
                                        LinearGradient(
                                            colors: [theme.clay, theme.clayDeep],
                                            startPoint: .top, endPoint: .bottom))
                                )
                                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                        }
                        .buttonStyle(.plain).disabled(videoURL == nil).opacity(
                            videoURL == nil ? 0.5 : 1.0
                        )
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 28).padding(.vertical, 24)
                }
            }
            .navigationTitle("new video post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: – Shared building blocks

private struct UploadField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).wwavLabel(size: 10, tracking: 2)
            content
        }
    }
}

private struct UploadProgressRow: View {
    let p: Double
    @Environment(\.theme) private var theme
    var body: some View {
        UploadPhaseProgressRow(status: .separating(p))
    }
}

/// Unified progress row for all upload phases — used by both music (separating)
/// and video (compressing → saving → finalizing).
struct UploadPhaseProgressRow: View {
    let status: TrackStatus
    @Environment(\.theme) private var theme

    private var label: String {
        switch status {
        case .separating(let p): return "separating · \(Int(p * 100))%"
        case .uploading(let phase, let p): return "\(phase.label) · \(Int(p * 100))%"
        default: return ""
        }
    }

    private var fraction: Double {
        switch status {
        case .separating(let p): return p
        case .uploading(_, let p): return p
        default: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.wwav(11, weight: .light, italic: true))
                .foregroundStyle(theme.muted)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.muted.opacity(0.20))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [theme.accent, theme.clayDeep],
                                startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 3)
        }
    }
}

private struct CoverPickerRow: View {
    @Binding var coverItem: PhotosPickerItem?
    @Binding var coverImage: UIImage?
    @Binding var coverData: Data?
    @Environment(\.theme) private var theme

    var body: some View {
        PhotosPicker(selection: $coverItem, matching: .images, photoLibrary: .shared()) {
            HStack(spacing: 14) {
                ZStack {
                    if let img = coverImage {
                        Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(
                            colors: [theme.clay.opacity(0.18), theme.clayDeep.opacity(0.12)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                        Text("+").font(.wwav(28, weight: .light)).foregroundStyle(theme.muted)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10).stroke(
                        theme.muted.opacity(0.40), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(coverImage == nil ? "tap to choose" : "tap to change")
                        .font(.wwav(14, weight: .regular)).foregroundStyle(theme.ink)
                    Text(coverImage == nil ? "a square jpg or png works best" : "looks good")
                        .font(.wwav(11, weight: .light)).foregroundStyle(theme.muted)
                }
                Spacer()
                if coverImage != nil {
                    Button(role: .destructive) {
                        coverItem = nil
                        coverImage = nil
                        coverData = nil
                    } label: {
                        Text("✕").font(.wwav(13, weight: .light)).foregroundStyle(theme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .buttonStyle(.plain)
        .onChange(of: coverItem) { _, newItem in
            Task { await load(from: newItem) }
        }
    }

    private func load(from item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
            let img = UIImage(data: data)
        {
            let jpeg = img.jpegData(compressionQuality: 0.85) ?? data
            await MainActor.run {
                self.coverImage = img
                self.coverData = jpeg
            }
        }
    }
}

private enum SheetBox {
    static func bg(_ theme: Palette) -> some View {
        RoundedRectangle(cornerRadius: 14).fill(
            LinearGradient(
                colors: [theme.sand, theme.sandDeep.opacity(0.6)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
    static func stroke(_ theme: Palette) -> some View {
        RoundedRectangle(cornerRadius: 14).stroke(theme.muted.opacity(0.25), lineWidth: 1)
    }
}

private struct PickedFile: Equatable {
    let url: URL
    let subtitle: String

    init(url: URL) {
        self.url = url
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let bytes = (attrs[.size] as? Int64) ?? 0
        let mb = Double(bytes) / 1_048_576.0
        if mb < 1 {
            let kb = Double(bytes) / 1024.0
            self.subtitle = String(format: "%.0f kb", kb)
        } else {
            self.subtitle = String(format: "%.1f mb", mb)
        }
    }
}

private struct PickedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { transferable in
            SentTransferredFile(transferable.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "wwav-pick-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)"
                )
            if FileManager.default.fileExists(atPath: copy.path) {
                try? FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

// MARK: – Radio upload (DJ live queue)

struct RadioUploadForm: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.theme) private var theme

    @State private var sessionId: UUID?
    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var queueTrackIds: [UUID] = []
    @State private var savedAt: Date?

    private var mySession: RadioSession? {
        if let sessionId,
           let session = library.radioSessions.first(where: { $0.id == sessionId }) {
            return session
        }
        return library.radioSessions.first { session in
            normalize(session.hostHandle) == normalize(library.profile.handle)
        }
    }

    private var currentTrack: Track? {
        guard let mySession else { return nil }
        return library.currentTrack(for: mySession)
    }

    var body: some View {
        ZStack {
            theme.pageRadial.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if library.albumCandidateTracks.isEmpty {
                        emptyLibrary
                    } else {
                        if let mySession, mySession.isLive {
                            onAirCard(mySession)
                        }

                        fields

                        TrackQueueEditor(
                            title: "queue playlist",
                            emptyMessage: "add songs to queue before going live",
                            tracks: library.albumCandidateTracks,
                            selectedIDs: $queueTrackIds
                        )

                        controls
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
        }
        .onAppear { hydrateFromSession() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            RadioPulseMark()
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text("radio").wwavTitle(size: 42)
                Text("audio-only live queue")
                    .font(.wwav(11, weight: .light))
                    .tracking(1.5)
                    .foregroundStyle(theme.muted)
            }
            Spacer()
            if mySession?.isLive == true {
                Text("on air")
                    .font(.wwav(10, weight: .medium, italic: true))
                    .tracking(1.5)
                    .foregroundStyle(theme.glow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.accent))
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("no songs ready")
                .wwavTitle(size: 24)
            Text("upload music first, then build a radio queue from those songs.")
                .font(.wwav(14, weight: .light, italic: true))
                .foregroundStyle(theme.muted)
            Button {
                nav.compose(.music)
            } label: {
                Text("upload music")
                    .font(.wwav(13, weight: .medium, italic: true))
                    .tracking(1.4)
                    .foregroundStyle(theme.glow)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(16)
        .background(radioBg)
        .overlay(radioStroke)
    }

    private func onAirCard(_ session: RadioSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("live now").wwavLabel(size: 10, tracking: 2)
            if let currentTrack {
                HStack(spacing: 12) {
                    ZStack {
                        LinearGradient(
                            colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        CachedAsyncImage(url: currentTrack.thumbnailURL) { Color.clear }
                    }
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.muted.opacity(0.22), lineWidth: 1))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentTrack.title)
                            .wwavTitle(size: 23)
                            .lineLimit(1)
                        Text("@\(currentTrack.handle) · \(session.queueTrackIds.count) in queue")
                            .font(.wwav(11, weight: .light))
                            .tracking(1)
                            .foregroundStyle(theme.muted)
                    }

                    Spacer(minLength: 0)
                    Button {
                        nav.openPost(currentTrack, in: library, with: player)
                    } label: {
                        ZStack {
                            Circle().fill(theme.accent)
                            Triangle().fill(theme.glow).frame(width: 9, height: 11).offset(x: 1)
                        }
                        .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(radioBg)
        .overlay(radioStroke)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            radioField(label: "stream title") {
                TextField("", text: $title, prompt: Text("late night wwav").foregroundStyle(theme.muted))
                    .font(.wwav(23, weight: .light, italic: true))
                    .foregroundStyle(theme.ink)
                    .padding(.vertical, 8)
                    .overlay(Rectangle().fill(theme.muted.opacity(0.3)).frame(height: 1), alignment: .bottom)
            }
            radioField(label: "notes") {
                TextEditor(text: $notes)
                    .scrollContentBackground(.hidden)
                    .font(.wwav(15, weight: .light))
                    .foregroundStyle(theme.ink)
                    .frame(minHeight: 76, maxHeight: 120)
                    .padding(12)
                    .background(radioBg)
                    .overlay(radioStroke)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                goLiveOrSave()
            } label: {
                Text(mySession?.isLive == true ? "save queue" : "go live")
                    .font(.wwav(15, weight: .regular, italic: true))
                    .tracking(2)
                    .foregroundStyle(theme.glow)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    )
            }
            .buttonStyle(.plain)
            .disabled(queueTrackIds.isEmpty)
            .opacity(queueTrackIds.isEmpty ? 0.5 : 1)

            if let mySession {
                HStack(spacing: 10) {
                    Button {
                        library.advanceRadio(id: mySession.id)
                    } label: {
                        radioControlPill("next")
                    }
                    .buttonStyle(.plain)
                    .disabled(!mySession.isLive || mySession.queueTrackIds.count < 2)
                    .opacity(mySession.isLive && mySession.queueTrackIds.count > 1 ? 1 : 0.45)

                    Button {
                        library.stopRadio(id: mySession.id)
                        hydrateFromSession()
                    } label: {
                        radioControlPill("end live")
                    }
                    .buttonStyle(.plain)
                    .disabled(!mySession.isLive)
                    .opacity(mySession.isLive ? 1 : 0.45)
                }
            }

            if let savedAt, Date().timeIntervalSince(savedAt) < 5 {
                Text("saved")
                    .font(.wwav(11, weight: .light, italic: true))
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.top, 4)
    }

    private func radioField<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).wwavLabel(size: 10, tracking: 2)
            content()
        }
    }

    private func radioControlPill(_ text: String) -> some View {
        Text(text)
            .font(.wwav(12, weight: .medium, italic: true))
            .tracking(1.4)
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Capsule().fill(theme.sand.opacity(0.66)))
            .overlay(Capsule().stroke(theme.muted.opacity(0.20), lineWidth: 1))
    }

    private var radioBg: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.sand.opacity(0.64))
    }

    private var radioStroke: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(theme.muted.opacity(0.22), lineWidth: 1)
    }

    private func goLiveOrSave() {
        if let mySession {
            library.updateRadioSession(
                id: mySession.id,
                title: title,
                notes: notes,
                queueTrackIds: queueTrackIds
            )
            if !mySession.isLive {
                sessionId = library.startRadio(title: title, notes: notes, queueTrackIds: queueTrackIds)
            }
        } else {
            sessionId = library.startRadio(title: title, notes: notes, queueTrackIds: queueTrackIds)
        }
        savedAt = Date()
        hydrateFromSession()
    }

    private func hydrateFromSession() {
        guard let session = mySession else {
            if title.isEmpty { title = "\(library.profile.name)'s radio" }
            return
        }
        sessionId = session.id
        title = session.title
        notes = session.notes
        queueTrackIds = session.queueTrackIds
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }
}

private struct RadioPulseMark: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [theme.accent, theme.clayDeep],
                            center: UnitPoint(x: 0.35, y: 0.25),
                            startRadius: 1,
                            endRadius: w * 0.56
                        )
                    )
                Circle()
                    .stroke(theme.glow.opacity(0.7), lineWidth: 1.2)
                    .frame(width: w * 0.34, height: w * 0.34)
                ForEach([0.52, 0.72], id: \.self) { scale in
                    Circle()
                        .trim(from: 0.12, to: 0.88)
                        .stroke(theme.glow.opacity(0.76), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .frame(width: w * scale, height: w * scale)
                        .rotationEffect(.degrees(-90))
                }
                Capsule()
                    .fill(theme.glow)
                    .frame(width: w * 0.09, height: w * 0.34)
                    .offset(y: w * 0.16)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

