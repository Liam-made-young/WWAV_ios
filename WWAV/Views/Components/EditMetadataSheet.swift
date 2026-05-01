import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// One sheet that edits any post type's metadata. Lets the user:
///   - rename the title
///   - rewrite the bio / caption / text body
///   - replace the cover image (any kind)
///   - swap the audio source for music posts (re-runs separation)
///   - replace the video file for video posts
///   - add or replace carousel images for image posts
struct EditMetadataSheet: View {
    let track: Track
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var title: String = ""
    @State private var bio: String = ""
    @State private var textBody: String = ""

    // Cover replacement.
    @State private var coverItem: PhotosPickerItem?
    @State private var coverImage: UIImage?
    @State private var coverData: Data?

    // Audio replacement (music only).
    @State private var pickAudioOpen: Bool = false
    @State private var newAudioURL: URL?

    // Video replacement (video only).
    @State private var videoItem: PhotosPickerItem?
    @State private var newVideoURL: URL?

    // Carousel replacement (image only).
    @State private var imageItems: [PhotosPickerItem] = []
    @State private var newImageDatas: [Data] = []
    @State private var newImagePreviews: [UIImage] = []

    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                theme.pageRadial.ignoresSafeArea()
                ScrollView { formBody }
            }
            .navigationTitle("edit metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { sheetToolbar }
            .onAppear {
                title = track.title
                bio = track.bio
                textBody = track.textBody ?? ""
            }
            .fileImporter(
                isPresented: $pickAudioOpen,
                allowedContentTypes: audioTypes,
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    newAudioURL = url
                }
            }
            .onChange(of: coverItem) { _, item in
                Task { await loadCover(from: item) }
            }
            .onChange(of: videoItem) { _, item in
                Task { await loadVideo(from: item) }
            }
            .onChange(of: imageItems) { _, items in
                Task { await loadImages(from: items) }
            }
            .alert("delete this post?", isPresented: $showDeleteConfirm) {
                Button("cancel", role: .cancel) {}
                Button("delete", role: .destructive) {
                    library.deletePost(id: track.id, token: auth.token)
                    dismiss()
                }
            } message: {
                Text("this can't be undone — the post is removed from this app permanently.")
            }
        }
    }

    @ToolbarContentBuilder
    private var sheetToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("save") { save() }
        }
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("editing — \(track.kind.label)")
                .wwavLabel(size: 10, tracking: 2)

            titleField
            bodyField
            kindSpecificFields
            deleteButton
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }

    private var titleField: some View {
        field(label: "title") {
            TextField("", text: $title)
                .font(.wwav(22, weight: .light, italic: true))
                .foregroundStyle(theme.ink)
                .padding(.vertical, 8)
                .overlay(Rectangle().fill(theme.muted.opacity(0.3))
                            .frame(height: 1), alignment: .bottom)
        }
    }

    @ViewBuilder
    private var bodyField: some View {
        if track.kind == .text {
            field(label: "text") {
                TextEditor(text: $textBody)
                    .scrollContentBackground(.hidden)
                    .font(.wwav(15, weight: .light))
                    .frame(minHeight: 140)
                    .padding(12)
                    .background(boxBg)
                    .overlay(boxStroke)
            }
        } else {
            field(label: track.kind == .music ? "bio / notes" : "caption") {
                TextEditor(text: $bio)
                    .scrollContentBackground(.hidden)
                    .font(.wwav(15, weight: .light))
                    .frame(minHeight: 100)
                    .padding(12)
                    .background(boxBg)
                    .overlay(boxStroke)
            }
        }
    }

    @ViewBuilder
    private var kindSpecificFields: some View {
        if track.kind != .text {
            field(label: "cover art") { coverPicker }
        }
        if track.kind == .music {
            field(label: "audio file") { audioPicker }
        }
        if track.kind == .video {
            field(label: "video file") { videoPicker }
        }
        if track.kind == .image {
            field(label: "carousel images (replace)") { imagesPicker }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Text("delete post")
                .font(.wwav(13, weight: .light, italic: true))
                .foregroundStyle(Color.red.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }

    private var audioTypes: [UTType] {
        var types: [UTType] = [.audio, .wav, .mp3, .mpeg4Audio, .aiff]
        if let flac = UTType("public.flac") { types.append(flac) }
        return types
    }

    private var boxBg: some View {
        RoundedRectangle(cornerRadius: 14).fill(
            LinearGradient(colors: [theme.sand, theme.sandDeep.opacity(0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private var boxStroke: some View {
        RoundedRectangle(cornerRadius: 14).stroke(theme.muted.opacity(0.25), lineWidth: 1)
    }

    @ViewBuilder
    private func field<Content: View>(
        label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).wwavLabel(size: 10, tracking: 2)
            content()
        }
    }

    private var coverPicker: some View {
        PhotosPicker(selection: $coverItem, matching: .images, photoLibrary: .shared()) {
            HStack(spacing: 14) {
                ZStack {
                    if let img = coverImage {
                        Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else if let url = track.coverImageURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().aspectRatio(contentMode: .fill)
                            default:
                                LinearGradient(colors: [theme.clay.opacity(0.18), theme.clayDeep.opacity(0.12)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                        }
                    } else {
                        LinearGradient(colors: [theme.clay.opacity(0.18), theme.clayDeep.opacity(0.12)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Text("+").font(.wwav(28, weight: .light)).foregroundStyle(theme.muted)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.muted.opacity(0.40), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(coverImage == nil ? "tap to choose" : "ready to save")
                        .font(.wwav(14, weight: .regular)).foregroundStyle(theme.ink)
                    Text(coverImage == nil ? "replaces the current cover" : "looks good")
                        .font(.wwav(11, weight: .light)).foregroundStyle(theme.muted)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private var audioPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                pickAudioOpen = true
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(
                            RadialGradient(colors: [theme.clay, theme.clayDeep],
                                           center: UnitPoint(x: 0.35, y: 0.30),
                                           startRadius: 1, endRadius: 28)
                        )
                        Text("WAV")
                            .font(.wwav(9, weight: .medium)).tracking(1)
                            .foregroundStyle(theme.glow)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(newAudioURL?.lastPathComponent ?? "tap to replace audio")
                            .font(.wwav(14, weight: .regular))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Text("re-runs stem separation")
                            .font(.wwav(11, weight: .light))
                            .foregroundStyle(theme.muted)
                    }
                    Spacer()
                }
                .padding(12)
                .background(boxBg)
                .overlay(boxStroke)
            }
            .buttonStyle(.plain)
        }
    }

    private var videoPicker: some View {
        PhotosPicker(selection: $videoItem, matching: .videos, photoLibrary: .shared()) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(
                        RadialGradient(colors: [theme.clay, theme.clayDeep],
                                       center: UnitPoint(x: 0.35, y: 0.30),
                                       startRadius: 1, endRadius: 28)
                    )
                    Image(systemName: "video.fill")
                        .font(.system(size: 14)).foregroundStyle(theme.glow)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(newVideoURL?.lastPathComponent ?? "tap to replace video")
                        .font(.wwav(14, weight: .regular))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text("swaps the file used by the player")
                        .font(.wwav(11, weight: .light))
                        .foregroundStyle(theme.muted)
                }
                Spacer()
            }
            .padding(12)
            .background(boxBg)
            .overlay(boxStroke)
        }
        .buttonStyle(.plain)
    }

    private var imagesPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            PhotosPicker(
                selection: $imageItems,
                maxSelectionCount: 10,
                matching: .images,
                photoLibrary: .shared()
            ) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(
                            RadialGradient(colors: [theme.clay, theme.clayDeep],
                                           center: UnitPoint(x: 0.35, y: 0.30),
                                           startRadius: 1, endRadius: 28)
                        )
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 14)).foregroundStyle(theme.glow)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(newImagePreviews.isEmpty
                             ? "tap to choose new images"
                             : "\(newImagePreviews.count) image\(newImagePreviews.count == 1 ? "" : "s") selected")
                            .font(.wwav(14, weight: .regular))
                            .foregroundStyle(theme.ink)
                        Text("replaces the carousel")
                            .font(.wwav(11, weight: .light))
                            .foregroundStyle(theme.muted)
                    }
                    Spacer()
                }
                .padding(12)
                .background(boxBg)
                .overlay(boxStroke)
            }
            .buttonStyle(.plain)

            if !newImagePreviews.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(newImagePreviews.enumerated()), id: \.offset) { _, img in
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private func loadCover(from item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let img = UIImage(data: data) {
            let jpeg = img.jpegData(compressionQuality: 0.85) ?? data
            await MainActor.run {
                self.coverImage = img
                self.coverData = jpeg
            }
        }
    }

    private func loadVideo(from item: PhotosPickerItem?) async {
        guard let item else { return }
        if let url = try? await item.loadTransferable(type: VideoTransferable.self)?.url {
            await MainActor.run { self.newVideoURL = url }
        }
    }

    private func loadImages(from items: [PhotosPickerItem]) async {
        var datas: [Data] = []
        var previews: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                let jpeg = img.jpegData(compressionQuality: 0.85) ?? data
                datas.append(jpeg)
                previews.append(img)
            }
        }
        await MainActor.run {
            self.newImageDatas = datas
            self.newImagePreviews = previews
        }
    }

    private func save() {
        let token = auth.token

        // Always update title + body fields.
        library.updateMetadata(
            id: track.id,
            title: title,
            bio: bio,
            textBody: track.kind == .text ? textBody : nil,
            token: token
        )

        if let coverData {
            library.replaceCover(id: track.id, image: coverData, token: token)
        }
        if let newAudioURL, track.kind == .music {
            library.replaceAudio(id: track.id, sourceURL: newAudioURL, token: token)
        }
        if let newVideoURL, track.kind == .video {
            library.replaceVideo(id: track.id, videoURL: newVideoURL)
        }
        if !newImageDatas.isEmpty, track.kind == .image {
            library.replaceImages(id: track.id, images: newImageDatas, token: token)
        }
        dismiss()
    }
}

/// PhotosPicker delivers videos as a temporary file URL via Transferable.
/// We copy it to a stable cache so the URL outlives the picker session.
private struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { transferable in
            SentTransferredFile(transferable.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("wwav-pick-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
            if FileManager.default.fileExists(atPath: copy.path) {
                try? FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}
