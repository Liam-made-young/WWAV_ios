import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
                    case .image: ImageUploadForm()
                    case .text: TextUploadForm()
                    case .video: VideoUploadForm()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var kindPicker: some View {
        HStack(spacing: 6) {
            ForEach(PostKind.allCases) { kind in
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

private struct MusicUploadForm: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme

    @State private var pickerOpen: Bool = false
    @State private var pickedFile: PickedFile?
    @State private var title: String = ""
    @State private var bio: String = ""
    @State private var inFlightID: UUID?
    @State private var coverItem: PhotosPickerItem?
    @State private var coverImage: UIImage?
    @State private var coverData: Data?

    var body: some View {
        Group {
            if pickedFile == nil {
                BigCircleEntry(
                    title: "drop a track. start a wave.",
                    subtitle: "wav · mp3 · flac · m4a",
                    kicker: "upload a wav"
                ) {
                    pickerOpen = true
                }
            } else {
                ScrollView { filled.padding(.bottom, 16) }
            }
        }
        .fileImporter(
            isPresented: $pickerOpen,
            allowedContentTypes: audioTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                pickedFile = PickedFile(url: url)
                if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
            }
        }
    }

    private var audioTypes: [UTType] {
        var types: [UTType] = [.audio, .wav, .mp3, .mpeg4Audio, .aiff]
        if let flac = UTType("public.flac") { types.append(flac) }
        return types
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

            UploadField(label: "song file") {
                if let f = pickedFile {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(
                                RadialGradient(
                                    colors: [theme.clay, theme.clayDeep],
                                    center: UnitPoint(x: 0.35, y: 0.30),
                                    startRadius: 1, endRadius: 28)
                            )
                            Text(
                                f.url.pathExtension.uppercased().isEmpty
                                    ? "WAV" : f.url.pathExtension.uppercased()
                            )
                            .font(.wwav(9, weight: .medium)).tracking(1).foregroundStyle(theme.glow)
                        }
                        .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.url.lastPathComponent)
                                .font(.wwav(14, weight: .regular)).foregroundStyle(theme.ink)
                                .lineLimit(1)
                            Text(f.subtitle)
                                .font(.wwav(11, weight: .light)).foregroundStyle(theme.muted)
                        }
                        Spacer()
                        Button {
                            pickedFile = nil
                            inFlightID = nil
                        } label: {
                            Text("✕").font(.wwav(13, weight: .light)).foregroundStyle(theme.muted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(boxBg).overlay(boxStroke)
                }
            }

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
            case .sourceOnly: EmptyView()
            }
        }
    }

    private var uploadButton: some View {
        Button {
            guard let f = pickedFile else { return }
            let id = library.startUpload(
                sourceURL: f.url,
                title: title.isEmpty ? "untitled" : title,
                bio: bio,
                coverImage: coverData,
                token: auth.token
            )
            inFlightID = id
        } label: {
            Text(inFlightID == nil ? "upload track" : "uploading…")
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

    private func cancel() {
        pickedFile = nil
        title = ""
        bio = ""
        inFlightID = nil
        coverItem = nil
        coverImage = nil
        coverData = nil
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
                _ = library.createTextPost(title: title, body: body)
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
                    _ = library.createVideoPost(
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
        VStack(alignment: .leading, spacing: 6) {
            Text("uploading · \(Int(p * 100))%")
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
                        .frame(width: max(0, geo.size.width * p))
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
    var subtitle: String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let bytes = (attrs[.size] as? Int64) ?? 0
        let mb = Double(bytes) / 1_048_576.0
        if mb < 1 {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.0f kb", kb)
        }
        return String(format: "%.1f mb", mb)
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
