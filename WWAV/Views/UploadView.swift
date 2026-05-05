import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct UploadTypeCardSpec: Identifiable {
    let kind: PostKind
    let title: String
    let subtitle: String
    let icon: String

    var id: PostKind { kind }
}

private let uploadTypeCards: [UploadTypeCardSpec] = [
    .init(kind: .music, title: "Track", subtitle: "single audio file", icon: "play.circle"),
    .init(kind: .video, title: "Video", subtitle: "clips & reels", icon: "video.fill"),
    .init(kind: .text, title: "Text post", subtitle: "words & image carousels", icon: "text.alignleft"),
    .init(kind: .radio, title: "Radio", subtitle: "live queue", icon: "dot.radiowaves.left.and.right")
]

struct UploadView: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme

    @State private var selectedKind: PostKind?

    var body: some View {
        ZStack {
            theme.pageRadial.ignoresSafeArea()
            Group {
                if let selectedKind {
                    composer(for: selectedKind)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    UploadTypePicker { kind in
                        withAnimation(.easeInOut(duration: 0.22)) {
                            selectedKind = kind
                        }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { consumeRequestedKind(animated: false) }
        .onChange(of: nav.requestedUploadKind) { _, _ in
            consumeRequestedKind(animated: true)
        }
    }

    @ViewBuilder
    private func composer(for kind: PostKind) -> some View {
        switch kind {
        case .music: MusicUploadForm(onBack: returnToTypePicker)
        case .album: AlbumUploadForm(onBack: returnToTypePicker)
        case .radio: RadioUploadForm(onBack: returnToTypePicker)
        case .image: ImageUploadForm()
        case .text: TextUploadForm(onBack: returnToTypePicker)
        case .video: VideoUploadForm(onBack: returnToTypePicker)
        }
    }

    private func consumeRequestedKind(animated: Bool) {
        guard let requested = nav.requestedUploadKind else { return }
        let target: PostKind = requested
        if animated {
            withAnimation(.easeInOut(duration: 0.22)) { selectedKind = target }
        } else {
            selectedKind = target
        }
        nav.requestedUploadKind = nil
    }

    private func returnToTypePicker() {
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedKind = nil
        }
    }
}

private struct UploadTypePicker: View {
    let onSelect: (PostKind) -> Void

    var body: some View {
        GeometryReader { geo in
            let margin: CGFloat = 22
            let spacing: CGFloat = 16
            let widthFit = (geo.size.width - margin * 2 - spacing) / 2
            let heightFit = (geo.size.height - margin * 2 - spacing) / 2
            let diameter = max(132, min(240, min(widthFit, heightFit)))
            let columns = [
                GridItem(.fixed(diameter), spacing: spacing),
                GridItem(.fixed(diameter), spacing: spacing)
            ]

            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(uploadTypeCards) { card in
                    UploadTypeCircleButton(card: card, diameter: diameter) {
                        onSelect(card.kind)
                    }
                }
            }
            .frame(width: diameter * 2 + spacing, height: diameter * 2 + spacing)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(margin)
        }
    }
}

private struct UploadTypeCircleButton: View {
    let card: UploadTypeCardSpec
    let diameter: CGFloat
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                theme.glow.opacity(0.86),
                                theme.sand.opacity(0.96),
                                theme.clay.opacity(0.76),
                                theme.clayDeep.opacity(0.94),
                            ],
                            center: WWAVLight.sun,
                            startRadius: 2,
                            endRadius: diameter * 0.78
                        )
                    )
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glow.opacity(0.62),
                                theme.muted.opacity(0.24),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [theme.glow.opacity(0.28), .clear],
                            center: UnitPoint(x: 0.34, y: 0.24),
                            startRadius: 0,
                            endRadius: diameter * 0.44
                        )
                    )
                    .padding(diameter * 0.12)
                Image(systemName: card.icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: diameter * 0.25, weight: .light))
                    .foregroundStyle(theme.glow)
                    .shadow(color: theme.clayDeep.opacity(0.34), radius: 8, y: 4)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .wwavShadow(.md)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(card.title)
        .accessibilityHint(card.subtitle)
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
    let onBack: (() -> Void)?
    @ViewBuilder var picker: () -> P
    @Environment(\.theme) private var theme

    init(
        kicker: String,
        title: String,
        subtitle: String,
        onBack: (() -> Void)? = nil,
        @ViewBuilder picker: @escaping () -> P
    ) {
        self.kicker = kicker
        self.title = title
        self.subtitle = subtitle
        self.onBack = onBack
        self.picker = picker
    }

    var body: some View {
        VStack(spacing: 32) {
            if let onBack {
                HStack {
                    Button {
                        onBack()
                    } label: {
                        Text("← back")
                            .font(.wwav(12, weight: .light, italic: true))
                            .tracking(1.5)
                            .foregroundStyle(theme.muted)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.top, 12)
            }
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
    let onBack: (() -> Void)?

    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme

    @State private var pickerOpen: Bool = false
    @State private var recorderOpen: Bool = false
    @State private var pickedFile: PickedFile?
    @State private var multitrackDraft: MultitrackDraft?
    @State private var sourceError: String?
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

    init(onBack: (() -> Void)? = nil) {
        self.onBack = onBack
    }

    private var hasSource: Bool {
        pickedFile != nil || multitrackDraft != nil
    }

    var body: some View {
        ScrollView { filled.padding(.bottom, 16) }
        .fileImporter(
            isPresented: $pickerOpen,
            allowedContentTypes: audioTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                pickedFile = PickedFile(url: url)
                multitrackDraft = nil
                sourceError = nil
                if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
            }
        }
        .sheet(isPresented: $recorderOpen) {
            RecordNowSheet(
                onSingleRecording: { url in
                    do {
                        let stableURL = try RecordingDraftStore.copySingle(url)
                        pickedFile = PickedFile(url: stableURL)
                        multitrackDraft = nil
                        sourceError = nil
                        if title.isEmpty { title = "recorded take" }
                    } catch {
                        sourceError = "couldn't keep that recording: \(error.localizedDescription)"
                    }
                },
                onMultitrackRecording: { stems in
                    do {
                        let stableStems = try RecordingDraftStore.copyStems(stems)
                        multitrackDraft = MultitrackDraft(stemURLs: stableStems)
                        pickedFile = nil
                        sourceError = nil
                        if title.isEmpty { title = "multitrack take" }
                    } catch {
                        sourceError = "couldn't keep those stems: \(error.localizedDescription)"
                    }
                }
            )
        }
    }

    private var filled: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button {
                    cancel()
                    onBack?()
                } label: {
                    Text("← back")
                        .font(.wwav(12, weight: .light, italic: true))
                        .tracking(1.5).foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("track").wwavLabel(size: 11, tracking: 3)
            }
            .padding(.top, 4)

            Text("new track").wwavTitle(size: 40)

            trackDropZone

            UploadField(label: sourceLabel) {
                sourceRow
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

            if hasSource {
                UploadField(label: "cover art") {
                    CoverPickerRow(
                        coverItem: $coverItem,
                        coverImage: $coverImage,
                        coverData: $coverData
                    )
                }
            }

            albumToggle
            if albumMode { albumSection }

            statusRow
            Spacer(minLength: 8)
            submissionButtons
        }
        .padding(.horizontal, 28).padding(.top, 12)
    }

    private var boxBg: some View {
        RoundedRectangle(cornerRadius: WWAVRadius.card).fill(
            LinearGradient(
                colors: [theme.clay.opacity(0.18), theme.clayDeep.opacity(0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
    private var boxStroke: some View {
        RoundedRectangle(cornerRadius: WWAVRadius.card)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glow.opacity(0.40),
                        theme.muted.opacity(WWAVOpacity.soft),
                    ],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
    }

    private var sourceLabel: String {
        hasSource ? (multitrackDraft == nil ? "song file" : "stem files") : "selected file"
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
            TrackUploadWaveformPreview()
                .padding(.top, 4)
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
        } else {
            Text("no audio selected yet")
                .font(.wwav(12, weight: .light, italic: true))
                .foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(boxBg)
                .overlay(boxStroke)
        }
    }

    private var trackDropZone: some View {
        VStack(spacing: 14) {
            Button {
                pickerOpen = true
            } label: {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [theme.glow.opacity(0.80), theme.clay, theme.clayDeep],
                                    center: UnitPoint(x: 0.35, y: 0.25),
                                    startRadius: 2,
                                    endRadius: 44
                                )
                            )
                        Image(systemName: "arrow.up")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(theme.glow)
                    }
                    .frame(width: 64, height: 64)

                    VStack(spacing: 6) {
                        Text(hasSource ? "replace audio file" : "drop audio file here")
                            .font(.wwav(18, weight: .light, italic: true))
                            .foregroundStyle(theme.ink)
                        Text("or tap to browse")
                            .font(.wwav(12, weight: .light))
                            .foregroundStyle(theme.muted)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(theme.glow.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(theme.muted.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                )
            }
            .buttonStyle(.plain)

            Button {
                recorderOpen = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "mic")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(theme.glow.opacity(0.22)))
                    Text("record inside WWAV")
                        .font(.wwav(16, weight: .medium, italic: true))
                        .tracking(1.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.glow)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [theme.accent, theme.clayDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .overlay(Capsule().stroke(theme.glow.opacity(0.36), lineWidth: 1))
                .shadow(color: theme.accent.opacity(0.28), radius: 18, y: 8)
            }
            .buttonStyle(.plain)
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
                Text("save this track as the first song on an album")
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
        if let sourceError, inFlightID == nil {
            Text("✕ \(sourceError)")
                .font(.wwav(12, weight: .light))
                .foregroundStyle(Color.red.opacity(0.7))
        } else if let id = inFlightID,
            let track = library.myTracks.first(where: { $0.id == id })
        {
            switch track.status {
            case .separating(let p): UploadProgressRow(p: p)
            case .ready:
                Button {
                    nav.openPost(track, in: library, with: player)
                } label: {
                    Text("saved to library — open preview")
                        .font(.wwav(13, weight: .light, italic: true))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
            case .failed(let msg):
                Text("✕ \(msg)")
                    .font(.wwav(12, weight: .light)).foregroundStyle(Color.red.opacity(0.7))
            case .uploading(let phase, let p): UploadPhaseProgressRow(status: .uploading(phase: phase, progress: p))
            case .sourceOnly:
                Text("saved to library")
                    .font(.wwav(13, weight: .light, italic: true))
                    .foregroundStyle(theme.accent)
            }
        }
    }

    private var submissionButtons: some View {
        VStack(spacing: 10) {
            submitButton(title: saveButtonTitle, publication: .draft, filled: false)
            submitButton(title: postButtonTitle, publication: .published, filled: true)
        }
    }

    private var saveButtonTitle: String {
        if inFlightID != nil { return "saving..." }
        return albumMode ? "save track + album" : "save to library"
    }

    private var postButtonTitle: String {
        if inFlightID != nil { return "working..." }
        return albumMode ? "post track + album" : "post to feed"
    }

    private func submitButton(title: String, publication: PublicationState, filled: Bool) -> some View {
        Button {
            submit(publication: publication)
        } label: {
            Text(title)
                .font(.wwav(15, weight: .regular, italic: true))
                .tracking(2)
                .foregroundStyle(filled ? theme.glow : theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(
                        filled
                            ? AnyShapeStyle(LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            : AnyShapeStyle(theme.sand.opacity(0.62))
                    )
                )
                .overlay(Capsule().stroke(theme.accent.opacity(filled ? 0 : 0.28), lineWidth: 1))
                .shadow(color: filled ? .black.opacity(0.18) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(inFlightID != nil || !hasSource)
        .opacity(inFlightID != nil || !hasSource ? 0.55 : 1.0)
    }

    private func submit(publication: PublicationState) {
        sourceError = nil
        let id: UUID
        if let f = pickedFile {
            id = library.startUpload(
                sourceURL: f.url,
                title: title.isEmpty ? "untitled" : title,
                bio: bio,
                coverImage: coverData,
                token: auth.token,
                publication: publication
            )
        } else if let draft = multitrackDraft {
            if let missing = draft.firstMissingStem {
                sourceError = "\(missing.label) recording is missing. record that lane again."
                return
            }
            id = library.startMultitrackUpload(
                stemURLs: draft.stemURLs,
                title: title.isEmpty ? "untitled" : title,
                bio: bio,
                coverImage: coverData,
                token: auth.token,
                publication: publication
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
                token: auth.token,
                publication: publication
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
        sourceError = nil
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
        sourceError = nil
    }
}

private struct MultitrackDraft: Equatable {
    let stemURLs: [StemKind: URL]

    var firstMissingStem: StemKind? {
        StemKind.allCases.first { kind in
            guard let url = stemURLs[kind] else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }
    }
}

private enum RecordingDraftStore {
    static func copySingle(_ source: URL) throws -> URL {
        let folder = try makeDraftDirectory()
        return try copy(source, to: folder, filename: "single.\(fileExtension(for: source))")
    }

    static func copyStems(_ stems: [StemKind: URL]) throws -> [StemKind: URL] {
        let folder = try makeDraftDirectory()
        var copied: [StemKind: URL] = [:]
        for kind in StemKind.allCases {
            guard let source = stems[kind] else {
                throw RecordingDraftStoreError.missingStem(kind.label)
            }
            copied[kind] = try copy(
                source,
                to: folder,
                filename: "\(kind.rawValue).\(fileExtension(for: source))"
            )
        }
        return copied
    }

    private static func makeDraftDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base
            .appendingPathComponent("wwav/recording-drafts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func copy(_ source: URL, to folder: URL, filename: String) throws -> URL {
        let dest = folder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    private static func fileExtension(for source: URL) -> String {
        source.pathExtension.isEmpty ? "wav" : source.pathExtension
    }
}

private enum RecordingDraftStoreError: LocalizedError {
    case missingStem(String)

    var errorDescription: String? {
        switch self {
        case .missingStem(let label):
            return "\(label) was not recorded."
        }
    }
}

private struct TrackUploadWaveformPreview: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<76, id: \.self) { index in
                let wave = abs(sin(Double(index) * 0.42) * cos(Double(index) * 0.17))
                Capsule()
                    .fill(index < 28 ? theme.accent.opacity(0.88) : theme.muted.opacity(0.28))
                    .frame(width: 3, height: 7 + wave * 34)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 52, alignment: .center)
    }
}


// MARK: – Album upload (groups existing songs)

private struct AlbumUploadForm: View {
    let onBack: (() -> Void)?

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

    init(onBack: (() -> Void)? = nil) {
        self.onBack = onBack
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button {
                        onBack?()
                    } label: {
                        Text("← back")
                            .font(.wwav(12, weight: .light, italic: true))
                            .tracking(1.5)
                            .foregroundStyle(theme.muted)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("album").wwavLabel(size: 11, tracking: 3)
                }
                .padding(.top, 4)

                HStack {
                    Spacer()
                    if let posted = lastPostedAt, Date().timeIntervalSince(posted) < 6 {
                        Text("saved")
                            .font(.wwav(11, weight: .light, italic: true))
                            .foregroundStyle(theme.accent)
                    }
                }

                Text("new album")
                    .wwavTitle(size: 40)

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

                    albumActionButtons
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private var albumActionButtons: some View {
        VStack(spacing: 10) {
            albumActionButton("save album to library", publication: .draft, filled: false)
            albumActionButton("post album to feed", publication: .published, filled: true)
        }
        .padding(.top, 4)
    }

    private func albumActionButton(
        _ label: String,
        publication: PublicationState,
        filled: Bool
    ) -> some View {
        Button {
            _ = library.createAlbumPost(
                title: title,
                caption: caption,
                trackIds: selectedTrackIds,
                coverImage: coverData,
                token: auth.token,
                publication: publication
            )
            self.title = ""
            caption = ""
            selectedTrackIds = []
            coverItem = nil
            coverImage = nil
            coverData = nil
            lastPostedAt = Date()
        } label: {
            Text(label)
                .font(.wwav(15, weight: .regular, italic: true))
                .tracking(2)
                .foregroundStyle(filled ? theme.glow : theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(
                        filled
                            ? AnyShapeStyle(LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            : AnyShapeStyle(theme.sand.opacity(0.62))
                    )
                )
                .overlay(Capsule().stroke(theme.accent.opacity(filled ? 0 : 0.28), lineWidth: 1))
                .shadow(color: filled ? .black.opacity(0.18) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(selectedTrackIds.isEmpty)
        .opacity(selectedTrackIds.isEmpty ? 0.5 : 1)
    }
}

// MARK: – Radio upload form

struct RadioUploadForm: View {
    let onBack: (() -> Void)?

    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var broadcaster: LiveRadioBroadcaster
    @Environment(\.theme) private var theme

    @State private var sessionId: UUID?
    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var queueTrackIds: [UUID] = []
    @State private var savedAt: Date?
    @State private var showingDJConsole: Bool = false
    @State private var radioError: String?
    @State private var radioStatus: String?
    @State private var preparingRadioTrackId: UUID?

    init(onBack: (() -> Void)? = nil) {
        self.onBack = onBack
    }

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

                        streamTitleField
                        controls

                        TrackQueueEditor(
                            title: "queue playlist",
                            emptyMessage: "add songs to queue before going live",
                            tracks: library.albumCandidateTracks,
                            selectedIDs: $queueTrackIds
                        )

                        notesField
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            reconcileRuntimeLiveState()
            hydrateFromSession()
        }
        .fullScreenCover(isPresented: $showingDJConsole) {
            if let session = mySession {
                DJConsoleView(
                    broadcaster: broadcaster,
                    session: session,
                    queueTracks: library.tracks(for: session)
                ) {
                    broadcaster.endLive()
                    library.stopRadio(id: session.id)
                    hydrateFromSession()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.muted)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(theme.sand.opacity(0.58)))
                        .overlay(Circle().stroke(theme.muted.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
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
                        showingDJConsole = true
                    } label: {
                        ZStack {
                            Circle().fill(theme.accent)
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(theme.glow)
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

    private var streamTitleField: some View {
        radioField(label: "stream title") {
            TextField("", text: $title, prompt: Text("late night wwav").foregroundStyle(theme.muted))
                .font(.wwav(23, weight: .light, italic: true))
                .foregroundStyle(theme.ink)
                .padding(.vertical, 8)
                .overlay(Rectangle().fill(theme.muted.opacity(0.3)).frame(height: 1), alignment: .bottom)
        }
    }

    private var notesField: some View {
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

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            streamTitleField
            controls
            notesField
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let radioError {
                Text(radioError)
                    .font(.wwav(11, weight: .light, italic: true))
                    .foregroundStyle(Color.red.opacity(0.78))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let radioStatus {
                Text(radioStatus)
                    .font(.wwav(11, weight: .light, italic: true))
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                goLiveOrSave()
            } label: {
                Text(preparingRadioTrackId != nil ? "loading queue..." : (mySession?.isLive == true ? "save + stay live" : "go live"))
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
            .disabled(queueTrackIds.isEmpty || preparingRadioTrackId != nil)
            .opacity(queueTrackIds.isEmpty || preparingRadioTrackId != nil ? 0.5 : 1)

            if let mySession {
                HStack(spacing: 10) {
                    Button {
                        Task {
                            await playNextQueuedTrack(in: mySession)
                        }
                    } label: {
                        radioControlPill("next")
                    }
                    .buttonStyle(.plain)
                    .disabled(!mySession.isLive || mySession.queueTrackIds.count < 2 || preparingRadioTrackId != nil)
                    .opacity(mySession.isLive && mySession.queueTrackIds.count > 1 && preparingRadioTrackId == nil ? 1 : 0.45)

                    Button {
                        broadcaster.endLive()
                        library.stopRadio(id: mySession.id)
                        hydrateFromSession()
                    } label: {
                        radioControlPill("end live")
                    }
                    .buttonStyle(.plain)
                    .disabled(!mySession.isLive)
                    .opacity(mySession.isLive ? 1 : 0.45)
                }

                Button {
                    showingDJConsole = true
                } label: {
                    radioControlPill("open dj console")
                }
                .buttonStyle(.plain)
                .disabled(!mySession.isLive)
                .opacity(mySession.isLive ? 1 : 0.45)
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
        radioError = nil
        radioStatus = nil
        var liveSessionId: UUID?
        if let mySession {
            library.updateRadioSession(
                id: mySession.id,
                title: title,
                notes: notes,
                queueTrackIds: queueTrackIds
            )
            if !mySession.isLive {
                sessionId = library.startRadio(title: title, notes: notes, queueTrackIds: queueTrackIds)
                liveSessionId = sessionId
            } else {
                liveSessionId = mySession.id
            }
        } else {
            sessionId = library.startRadio(title: title, notes: notes, queueTrackIds: queueTrackIds)
            liveSessionId = sessionId
        }
        if let liveSessionId {
            if broadcaster.goLive(sessionId: liveSessionId) {
                showingDJConsole = true
                Task {
                    await playCurrentQueuedTrack(in: liveSessionId)
                }
            } else {
                library.stopRadio(id: liveSessionId)
                radioError = "couldn't start the mic. check microphone permission and try again."
            }
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

    private func reconcileRuntimeLiveState() {
        guard let session = mySession, session.isLive, !broadcaster.isLive else { return }
        library.stopRadio(id: session.id)
    }

    private func playNextQueuedTrack(in session: RadioSession) async {
        radioError = nil
        radioStatus = nil
        library.advanceRadio(id: session.id)
        guard let updated = library.radioSessions.first(where: { $0.id == session.id }),
              let nextTrack = library.currentTrack(for: updated) else { return }
        await prepareAndPlayQueuedTrack(nextTrack, sessionId: session.id)
    }

    private func playCurrentQueuedTrack(in sessionId: UUID) async {
        guard let session = library.radioSessions.first(where: { $0.id == sessionId }),
              let track = library.currentTrack(for: session) else { return }
        await prepareAndPlayQueuedTrack(track, sessionId: sessionId)
    }

    private func prepareAndPlayQueuedTrack(_ track: Track, sessionId: UUID) async {
        guard preparingRadioTrackId == nil else { return }
        preparingRadioTrackId = track.id
        radioStatus = "loading \(track.title)..."
        let primed = await library.prepareForPlayback(track)
        guard let primed else {
            preparingRadioTrackId = nil
            radioStatus = nil
            radioError = "couldn't load stems for \(track.title). try another queued song."
            return
        }
        library.setRadioCurrentTrack(id: sessionId, trackId: primed.id)
        if broadcaster.playSong(primed) {
            library.incrementPlays(of: primed.id)
            radioStatus = "playing \(primed.title)"
        } else {
            radioStatus = nil
            radioError = "\(primed.title) isn't ready for radio playback yet."
        }
        preparingRadioTrackId = nil
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
                    Text("saved to library")
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
                onPost: { title, caption, publication in
                    _ = library.createImagePost(
                        images: datas,
                        title: title,
                        caption: caption,
                        token: auth.token,
                        publication: publication
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

private struct TextUploadForm: View {
    let onBack: (() -> Void)?

    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var imageItems: [PhotosPickerItem] = []
    @State private var imageData: [Data] = []
    @State private var imagePreviews: [UIImage] = []
    @State private var showingImageSourceDialog: Bool = false
    @State private var imageCameraOpen: Bool = false
    @State private var imageLibraryOpen: Bool = false
    @State private var lastPostedAt: Date?

    init(onBack: (() -> Void)? = nil) {
        self.onBack = onBack
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Button {
                        onBack?()
                    } label: {
                        Text("← back")
                            .font(.wwav(12, weight: .light, italic: true))
                            .tracking(1.5)
                            .foregroundStyle(theme.muted)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("text post").wwavLabel(size: 11, tracking: 3)
                }
                .padding(.top, 4)

                Text("new post")
                    .wwavTitle(size: 40)

                HStack(spacing: 14) {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [theme.glow.opacity(0.68), theme.muted.opacity(0.55)],
                                center: UnitPoint(x: 0.35, y: 0.25),
                                startRadius: 1,
                                endRadius: 32
                            )
                        )
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(auth.user?.username ?? library.profile.name)
                            .font(.wwav(16, weight: .medium))
                            .foregroundStyle(theme.ink)
                        Text("@\((auth.user?.username ?? library.profile.handle).trimmingCharacters(in: CharacterSet(charactersIn: "@")))")
                            .font(.wwav(12, weight: .light))
                            .foregroundStyle(theme.muted)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    TextField(
                        "", text: $title,
                        prompt: Text("title (optional)").foregroundStyle(theme.muted)
                    )
                    .font(.wwav(22, weight: .light, italic: true))
                    .foregroundStyle(theme.ink)
                    .padding(.vertical, 8)
                    .overlay(Rectangle().fill(theme.muted.opacity(0.20)).frame(height: 1), alignment: .bottom)

                    ZStack(alignment: .topLeading) {
                        if bodyText.isEmpty {
                            Text("write the post…")
                                .font(.wwav(20, weight: .light, italic: true))
                                .foregroundStyle(theme.muted.opacity(0.78))
                                .padding(.top, 12)
                                .padding(.leading, 8)
                        }

                        TextEditor(text: $bodyText)
                            .scrollContentBackground(.hidden)
                            .font(.wwav(20, weight: .light, italic: true))
                            .foregroundStyle(theme.ink)
                            .lineSpacing(7)
                            .frame(minHeight: 150, maxHeight: 210)
                            .padding(.horizontal, 2)
                            .background(Color.clear)
                    }

                    if imagePreviews.isEmpty {
                        imageAttachButton(prominent: true)
                    } else {
                        textImageStrip
                    }

                    HStack {
                        Text("\(bodyText.count) characters")
                            .font(.wwav(10, weight: .light))
                            .tracking(1.4)
                            .monospacedDigit()
                            .foregroundStyle(theme.muted.opacity(0.85))
                        Spacer()
                        Text(canPost ? "ready" : "add text or photos")
                            .font(.wwav(10, weight: .light, italic: true))
                            .tracking(1.4)
                            .foregroundStyle(canPost ? theme.accent : theme.muted.opacity(0.85))
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: WWAVRadius.card).fill(theme.glow.opacity(WWAVOpacity.veil)))
                .overlay(
                    RoundedRectangle(cornerRadius: WWAVRadius.card)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    theme.glow.opacity(0.40),
                                    theme.muted.opacity(WWAVOpacity.soft),
                                ],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )

                if let posted = lastPostedAt, Date().timeIntervalSince(posted) < 6 {
                    Text("saved")
                        .font(.wwav(12, weight: .light, italic: true))
                        .foregroundStyle(theme.accent)
                }

                HStack(spacing: 10) {
                    Spacer()
                    textActionButton("save", publication: .draft, filled: false)
                    textActionButton("post", publication: .published, filled: true)
                }
                .padding(.top, 4)
                .overlay(Rectangle().fill(theme.muted.opacity(0.16)).frame(height: 1), alignment: .top)
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .onChange(of: imageItems) { _, newItems in
            Task { await loadTextImages(from: newItems) }
        }
        .photosPicker(
            isPresented: $imageLibraryOpen,
            selection: $imageItems,
            maxSelectionCount: 10,
            matching: .images,
            preferredItemEncoding: .compatible,
            photoLibrary: .shared()
        )
        .fullScreenCover(isPresented: $imageCameraOpen) {
            WWAVCameraImagePicker { image in
                appendCameraImage(image)
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("add image", isPresented: $showingImageSourceDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("open camera") {
                    imageCameraOpen = true
                }
            }
            Button("open camera roll") {
                imageLibraryOpen = true
            }
            Button("cancel", role: .cancel) {}
        }
    }

    private var canPost: Bool {
        !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageData.isEmpty
    }

    private func imageAttachButton(prominent: Bool) -> some View {
        Button {
            showingImageSourceDialog = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: prominent ? 16 : 12, weight: .regular))
                Text(imagePreviews.isEmpty ? "add photos" : "change")
                    .font(.wwav(prominent ? 14 : 11, weight: .medium, italic: true))
                    .tracking(prominent ? 1.2 : 0.8)
                if prominent {
                    Spacer(minLength: 0)
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(imagePreviews.isEmpty ? theme.ink : theme.accent)
            .padding(.horizontal, prominent ? 14 : 10)
            .padding(.vertical, prominent ? 12 : 7)
            .frame(maxWidth: prominent ? .infinity : nil, alignment: .leading)
            .background(
                Capsule().fill(
                    prominent
                        ? AnyShapeStyle(theme.sand.opacity(0.66))
                        : AnyShapeStyle(theme.muted.opacity(0.10))
                )
            )
            .overlay(Capsule().stroke(theme.muted.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var textImageStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(imagePreviews.count) image\(imagePreviews.count == 1 ? "" : "s") attached")
                    .wwavLabel(size: 10, tracking: 2)
                Spacer()
                imageAttachButton(prominent: false)
                Button {
                    imageItems = []
                    imageData = []
                    imagePreviews = []
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.muted)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(theme.muted.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(imagePreviews.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 92, height: 92)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(theme.muted.opacity(0.20), lineWidth: 1)
                            )
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.sand.opacity(0.56)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.muted.opacity(0.16), lineWidth: 1))
    }

    private func textActionButton(
        _ label: String,
        publication: PublicationState,
        filled: Bool
    ) -> some View {
        Button {
            postText(publication: publication)
        } label: {
            Text(label)
                .font(.wwav(15, weight: .regular, italic: true))
                .foregroundStyle(filled ? theme.glow : theme.accent)
                .padding(.horizontal, filled ? 28 : 18)
                .padding(.vertical, 14)
                .background(
                    Capsule().fill(
                        filled
                            ? AnyShapeStyle(LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            : AnyShapeStyle(theme.sand.opacity(0.62))
                    )
                )
                .overlay(Capsule().stroke(theme.accent.opacity(filled ? 0 : 0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!canPost)
        .opacity(canPost ? 1 : 0.5)
    }

    private func postText(publication: PublicationState) {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canPost else { return }
        _ = library.createTextPost(
            title: title,
            body: trimmed,
            images: imageData,
            token: auth.token,
            publication: publication
        )
        title = ""
        bodyText = ""
        imageItems = []
        imageData = []
        imagePreviews = []
        lastPostedAt = Date()
    }

    private func loadTextImages(from items: [PhotosPickerItem]) async {
        var datas: [Data] = []
        var previews: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                let jpeg = image.jpegData(compressionQuality: 0.85) ?? data
                datas.append(jpeg)
                previews.append(image)
            }
        }
        await MainActor.run {
            imageData = datas
            imagePreviews = previews
        }
    }

    private func appendCameraImage(_ image: UIImage) {
        guard imagePreviews.count < 10 else { return }
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        imageData.append(data)
        imagePreviews.append(image)
    }
}

// MARK: – Video upload
//
// Tap the big circle → PhotosPicker (movies). After selection, sheet pops
// up to collect cover art + title + caption, then posts.

private struct VideoUploadForm: View {
    let onBack: (() -> Void)?

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

    init(onBack: (() -> Void)? = nil) {
        self.onBack = onBack
    }

    private var inflightVideo: Track? {
        guard let id = inFlightID else { return nil }
        return library.myTracks.first(where: { $0.id == id })
    }

    var body: some View {
        ZStack {
            BigCirclePickerScaffold(
                kicker: "video post",
                title: "drop a clip. take the screen.",
                subtitle: "mp4 · mov · portrait or landscape",
                onBack: onBack
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
                        Text("saved to library")
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
                    Text("saved to library")
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
                onPost: { title, caption, coverData, publication in
                    guard let url = videoURL else { return }
                    inFlightID = library.createVideoPost(
                        videoURL: url, title: title, caption: caption,
                        coverImage: coverData, token: auth.token,
                        publication: publication
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
    let onPost: (_ title: String, _ caption: String, _ publication: PublicationState) -> Void
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

                        VStack(spacing: 10) {
                            imageActionButton("save images to library", publication: .draft, filled: false)
                            imageActionButton("post images to feed", publication: .published, filled: true)
                        }
                        .padding(.top, 8)
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

    private func imageActionButton(
        _ label: String,
        publication: PublicationState,
        filled: Bool
    ) -> some View {
        Button {
            onPost(title, caption, publication)
        } label: {
            Text(label)
                .font(.wwav(15, weight: .regular, italic: true))
                .tracking(2)
                .foregroundStyle(filled ? theme.glow : theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(
                        filled
                            ? AnyShapeStyle(LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            : AnyShapeStyle(theme.sand.opacity(0.62))
                    )
                )
                .overlay(Capsule().stroke(theme.accent.opacity(filled ? 0 : 0.28), lineWidth: 1))
                .shadow(color: filled ? .black.opacity(0.18) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }
}

private struct TextDetailsSheet: View {
    let onPost: (_ title: String, _ body: String, _ publication: PublicationState) -> Void
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

                        VStack(spacing: 10) {
                            textDetailActionButton("save to library", publication: .draft, filled: false)
                            textDetailActionButton("post to feed", publication: .published, filled: true)
                        }
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

    private func textDetailActionButton(
        _ label: String,
        publication: PublicationState,
        filled: Bool
    ) -> some View {
        let empty = body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            onPost(title, body_, publication)
        } label: {
            Text(label)
                .font(.wwav(15, weight: .regular, italic: true))
                .tracking(2)
                .foregroundStyle(filled ? theme.glow : theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(
                        filled
                            ? AnyShapeStyle(LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            : AnyShapeStyle(theme.sand.opacity(0.62))
                    )
                )
                .overlay(Capsule().stroke(theme.accent.opacity(filled ? 0 : 0.28), lineWidth: 1))
                .shadow(color: filled ? .black.opacity(0.18) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(empty)
        .opacity(empty ? 0.5 : 1.0)
    }
}

private struct VideoDetailsSheet: View {
    let videoURL: URL?
    let onPost: (_ title: String, _ caption: String, _ coverData: Data?, _ publication: PublicationState) -> Void
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

                        VStack(spacing: 10) {
                            videoActionButton("save video to library", publication: .draft, filled: false)
                            videoActionButton("post video to feed", publication: .published, filled: true)
                        }
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

    private func videoActionButton(
        _ label: String,
        publication: PublicationState,
        filled: Bool
    ) -> some View {
        Button {
            onPost(title, caption, coverData, publication)
        } label: {
            Text(label)
                .font(.wwav(15, weight: .regular, italic: true))
                .tracking(2)
                .foregroundStyle(filled ? theme.glow : theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(
                        filled
                            ? AnyShapeStyle(LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            : AnyShapeStyle(theme.sand.opacity(0.62))
                    )
                )
                .overlay(Capsule().stroke(theme.accent.opacity(filled ? 0 : 0.28), lineWidth: 1))
                .shadow(color: filled ? .black.opacity(0.18) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(videoURL == nil)
        .opacity(videoURL == nil ? 0.5 : 1.0)
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
