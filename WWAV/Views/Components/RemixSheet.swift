import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: – Overdub note
// Overdub (mic over stem) is implemented using AVAudioEngine input tap +
// AVAudioFile writing. The mixed signal is written to a new WAV file and
// used as the replacement stem. See RemixOverdubRecorder below.

// MARK: – Per-stem remix state

private enum StemReplaceKind: String, CaseIterable {
    case original  = "original"
    case replaced  = "replaced"
    case recorded  = "recorded"
    case overdub   = "overdub"
}

private struct StemState {
    var kind: StemKind
    var url: URL?               // nil → use parent stem
    var replaceKind: StemReplaceKind = .original
    var isRecording: Bool = false
    var isPlaying: Bool = false
}

// MARK: – Lightweight four-player preview engine

/// A simple 4-player preview that can play four stems sample-locked.
/// Deliberately separate from the main StemPlayerEngine so we never
/// touch it while the sheet is open.
@MainActor
private final class RemixPreviewEngine: ObservableObject {
    @Published private(set) var isPlaying: Bool = false

    private var players: [AVAudioPlayer] = []

    func load(urls: [URL]) {
        stop()
        players = urls.compactMap { try? AVAudioPlayer(contentsOf: $0) }
        players.forEach {
            $0.prepareToPlay()
            $0.numberOfLoops = 0
        }
    }

    func play() {
        guard !players.isEmpty else { return }
        let now = players.first!.deviceCurrentTime + 0.05
        for p in players { p.play(atTime: now) }
        isPlaying = true
    }

    func stop() {
        players.forEach { $0.stop() }
        players.removeAll()
        isPlaying = false
    }
}

// MARK: – AVAudioRecorder wrapper

@MainActor
private final class RemixRecorder: ObservableObject {
    @Published private(set) var isRecording: Bool = false

    private var recorder: AVAudioRecorder?
    private(set) var lastRecordingURL: URL?

    func startRecording() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("remix_take_\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        recorder = try AVAudioRecorder(url: tmp, settings: settings)
        recorder?.record()
        isRecording = true
        lastRecordingURL = tmp
        return tmp
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
    }
}

// MARK: – Overdub recorder (mic mixed with source stem)

/// Mixes live mic input with a looping source stem and writes the result to
/// a new WAV file. Uses a single AVAudioEngine with an input tap.
@MainActor
private final class RemixOverdubRecorder: ObservableObject {
    @Published private(set) var isRecording: Bool = false
    private(set) var lastRecordingURL: URL?

    private var engine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private var sourcePlayer: AVAudioPlayerNode?

    /// Start overdub: play `sourceURL` and mix the live mic on top,
    /// writing the blended PCM to a temporary WAV file.
    func start(sourceURL: URL) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("overdub_\(UUID().uuidString).wav")

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Player node for the source stem.
        let playerNode = AVAudioPlayerNode()
        eng.attach(playerNode)

        let mixer = eng.mainMixerNode
        eng.connect(playerNode, to: mixer, format: nil)

        // Output file in the input format.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: tmp, settings: outputSettings)
        self.outputFile = file

        // Tap mic input and write to file.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buf, _ in
            try? self?.outputFile?.write(from: buf)
        }

        // Schedule the source stem on the player node.
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        playerNode.scheduleFile(sourceFile, at: nil, completionHandler: nil)

        try eng.start()
        playerNode.play()

        self.engine = eng
        self.sourcePlayer = playerNode
        self.lastRecordingURL = tmp
        isRecording = true
        return tmp
    }

    func stop() {
        sourcePlayer?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        sourcePlayer = nil
        outputFile = nil
        isRecording = false
    }
}

// MARK: – Main RemixSheet

struct RemixSheet: View {
    let track: Track

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var auth: AuthManager

    // Per-stem state (4 stems)
    @State private var stemStates: [StemKind: StemState] = {
        var d: [StemKind: StemState] = [:]
        for k in StemKind.allCases { d[k] = StemState(kind: k) }
        return d
    }()

    // Preview engine (lazy: instantiated on appear)
    @StateObject private var preview = RemixPreviewEngine()
    @StateObject private var recorder = RemixRecorder()
    @StateObject private var overdubRecorder = RemixOverdubRecorder()

    // Active recording stem
    @State private var activeStem: StemKind? = nil
    @State private var activeOverdubStem: StemKind? = nil

    // File picker state
    @State private var filePickerStem: StemKind? = nil
    @State private var filePickerOpen: Bool = false

    // Composer phase
    @State private var showingComposer: Bool = false
    @State private var composerTitle: String = ""
    @State private var composerBio: String = ""
    @State private var composerCoverItem: PhotosPickerItem? = nil
    @State private var composerCoverData: Data? = nil
    @State private var composerCoverImage: UIImage? = nil
    @State private var isPosting: Bool = false
    @State private var postSuccess: Bool = false

    private let audioTypes: [UTType] = [.audio, .wav, .mp3, .mpeg4Audio, .aiff]

    var body: some View {
        NavigationStack {
            ZStack {
                theme.centerRadial.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        headerBlock
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                            .padding(.bottom, 16)

                        ForEach(StemKind.allCases) { kind in
                            stemRow(kind)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                            if kind != .synth {
                                Divider()
                                    .background(theme.muted.opacity(0.15))
                                    .padding(.horizontal, 20)
                            }
                        }

                        previewRow
                            .padding(.horizontal, 20)
                            .padding(.top, 16)

                        Divider()
                            .background(theme.muted.opacity(0.15))
                            .padding(.horizontal, 20)
                            .padding(.top, 16)

                        if showingComposer {
                            composerBlock
                                .padding(.horizontal, 24)
                                .padding(.top, 16)
                        } else {
                            openComposerButton
                                .padding(.horizontal, 24)
                                .padding(.top, 20)
                        }

                        Spacer(minLength: 32)
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        preview.stop()
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
        .onAppear {
            composerTitle = "remix of \(track.title)"
            // Pause main player so preview audio doesn't fight it.
            if player.isPlaying { player.pause() }
        }
        .onDisappear {
            preview.stop()
            recorder.stopRecording()
            overdubRecorder.stop()
        }
        .fileImporter(
            isPresented: $filePickerOpen,
            allowedContentTypes: audioTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first,
               let stem = filePickerStem {
                replaceStem(stem, with: url, kind: .replaced)
            }
            filePickerStem = nil
        }
    }

    // MARK: – Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("remix").wwavLabel(size: 11, tracking: 2.5)
            Text(track.title)
                .wwavTitle(size: 32)
                .lineLimit(1)
            Text("\(track.artist.lowercased()) · 4 stems")
                .font(.wwav(12, weight: .light))
                .tracking(1.2)
                .foregroundStyle(theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: – Stem Row

    private func stemRow(_ kind: StemKind) -> some View {
        let state = stemStates[kind] ?? StemState(kind: kind)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // Stem label pill
                Text(kind.label)
                    .font(.wwav(13, weight: .medium))
                    .tracking(1.5)
                    .foregroundStyle(state.replaceKind == .original ? theme.muted : theme.ink)
                    .frame(width: 52, alignment: .leading)

                // Status pill
                statusPill(for: state)

                Spacer(minLength: 0)

                // Action buttons
                actionButtons(for: kind, state: state)
            }

            // Recording indicator
            if state.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(0.9)
                    Text("recording…")
                        .font(.wwav(11, weight: .light, italic: true))
                        .foregroundStyle(Color.red.opacity(0.85))

                    Spacer()

                    Button {
                        stopRecording(kind)
                    } label: {
                        Text("stop")
                            .font(.wwav(11, weight: .regular))
                            .tracking(1)
                            .foregroundStyle(theme.glow)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(theme.accent))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(state.replaceKind == .original
                      ? theme.sand.opacity(0.30)
                      : theme.clay.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.muted.opacity(state.replaceKind == .original ? 0.15 : 0.30), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func statusPill(for state: StemState) -> some View {
        switch state.replaceKind {
        case .original:
            Text("original")
                .font(.wwav(9, weight: .light))
                .tracking(1)
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.muted.opacity(0.12)))
        case .replaced:
            Text("file")
                .font(.wwav(9, weight: .medium))
                .tracking(1)
                .foregroundStyle(theme.glow)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.accent))
        case .recorded:
            Text("recorded")
                .font(.wwav(9, weight: .medium))
                .tracking(1)
                .foregroundStyle(theme.glow)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.accent))
        case .overdub:
            Text("overdub")
                .font(.wwav(9, weight: .medium))
                .tracking(1)
                .foregroundStyle(theme.glow)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.accent.opacity(0.75)))
        }
    }

    private func actionButtons(for kind: StemKind, state: StemState) -> some View {
        HStack(spacing: 8) {
            // Replace from file
            circleAction(icon: "doc.badge.plus", label: "file") {
                filePickerStem = kind
                filePickerOpen = true
            }

            // Re-record
            let isRec = state.isRecording || (activeStem == kind)
            circleAction(
                icon: isRec ? "stop.circle" : "mic",
                label: isRec ? "stop" : "record",
                active: isRec,
                color: isRec ? Color.red.opacity(0.80) : theme.accent
            ) {
                if isRec {
                    stopRecording(kind)
                } else {
                    startRecording(kind)
                }
            }

            // Overdub
            let isOD = activeOverdubStem == kind && overdubRecorder.isRecording
            circleAction(
                icon: isOD ? "stop.circle" : "mic.badge.plus",
                label: isOD ? "stop" : "overdub",
                active: isOD,
                color: isOD ? Color.red.opacity(0.80) : theme.accent
            ) {
                if isOD {
                    stopOverdub(kind)
                } else {
                    startOverdub(kind)
                }
            }

            // Reset to original
            if state.replaceKind != .original {
                circleAction(icon: "arrow.counterclockwise", label: "reset", color: theme.muted) {
                    resetStem(kind)
                }
            }
        }
    }

    private func circleAction(
        icon: String,
        label: String,
        active: Bool = false,
        color: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let c = color ?? theme.accent
        return Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? theme.glow : c)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(active ? c : c.opacity(0.12))
                    )
                    .overlay(Circle().stroke(c.opacity(active ? 0 : 0.25), lineWidth: 1))
                Text(label)
                    .font(.wwav(8, weight: .light))
                    .tracking(0.8)
                    .foregroundStyle(theme.muted)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: – Preview Row

    private var previewRow: some View {
        HStack(spacing: 14) {
            Button {
                if preview.isPlaying {
                    preview.stop()
                } else {
                    let urls = previewURLs()
                    guard !urls.isEmpty else { return }
                    preview.load(urls: urls)
                    preview.play()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: preview.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text(preview.isPlaying ? "stop preview" : "preview mix")
                        .font(.wwav(12, weight: .light))
                        .tracking(1.2)
                }
                .foregroundStyle(preview.isPlaying ? theme.glow : theme.accent)
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(
                    Capsule().fill(
                        preview.isPlaying
                            ? AnyShapeStyle(LinearGradient(colors: [theme.clay, theme.clayDeep], startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(theme.accent.opacity(0.12))
                    )
                )
                .overlay(
                    Capsule().stroke(theme.accent.opacity(preview.isPlaying ? 0 : 0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(track.stems == nil)

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func previewURLs() -> [URL] {
        guard let parentStems = track.stems else { return [] }
        return StemKind.allCases.compactMap { kind in
            stemStates[kind]?.url ?? parentStems.url(for: kind)
        }
    }

    // MARK: – Post remix composer

    private var openComposerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                showingComposer = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 12, weight: .medium))
                Text("post remix")
                    .font(.wwav(15, weight: .regular, italic: true))
                    .tracking(1.5)
            }
            .foregroundStyle(theme.glow)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [theme.clay, theme.clayDeep],
                                   startPoint: .top, endPoint: .bottom)
                )
            )
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }

    private var composerBlock: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("post remix").wwavLabel(size: 11, tracking: 2.5)

            // Cover art picker
            HStack(spacing: 14) {
                PhotosPicker(selection: $composerCoverItem, matching: .images) {
                    ZStack {
                        if let img = composerCoverImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(LinearGradient(
                                    colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 72, height: 72)
                            Image(systemName: "photo")
                                .font(.system(size: 22))
                                .foregroundStyle(theme.muted)
                        }
                    }
                }
                .buttonStyle(.plain)
                .onChange(of: composerCoverItem) { _, newItem in
                    Task {
                        if let data = try? await newItem?.loadTransferable(type: Data.self),
                           let img = UIImage(data: data) {
                            composerCoverImage = img
                            composerCoverData = data
                        }
                    }
                }

                Text("cover art (optional)")
                    .font(.wwav(12, weight: .light, italic: true))
                    .foregroundStyle(theme.muted)
            }

            // Title
            VStack(alignment: .leading, spacing: 6) {
                Text("title").wwavLabel(size: 9, tracking: 2.0)
                TextField("", text: $composerTitle,
                          prompt: Text("remix title").foregroundStyle(theme.muted))
                    .font(.wwav(22, weight: .light, italic: true))
                    .foregroundStyle(theme.ink)
                    .padding(.vertical, 8)
                    .overlay(Rectangle().fill(theme.muted.opacity(0.3)).frame(height: 1),
                             alignment: .bottom)
            }

            // Bio / notes
            VStack(alignment: .leading, spacing: 6) {
                Text("notes").wwavLabel(size: 9, tracking: 2.0)
                TextEditor(text: $composerBio)
                    .scrollContentBackground(.hidden)
                    .font(.wwav(15, weight: .light))
                    .foregroundStyle(theme.ink)
                    .frame(minHeight: 72, maxHeight: 120)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(LinearGradient(
                                colors: [theme.clay.opacity(0.18), theme.clayDeep.opacity(0.12)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.muted.opacity(0.40), lineWidth: 1))
            }

            // Submit button
            Button {
                submitRemix()
            } label: {
                HStack(spacing: 6) {
                    if isPosting {
                        ProgressView()
                            .tint(theme.glow)
                            .scaleEffect(0.7)
                    } else if postSuccess {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 12, weight: .medium))
                    }
                    Text(postSuccess ? "posted!" : isPosting ? "posting…" : "post remix")
                        .font(.wwav(15, weight: .regular, italic: true))
                        .tracking(1.5)
                }
                .foregroundStyle(theme.glow)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(
                        LinearGradient(colors: [theme.clay, theme.clayDeep],
                                       startPoint: .top, endPoint: .bottom)
                    )
                )
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(isPosting || postSuccess)
            .opacity(isPosting ? 0.7 : 1.0)
        }
    }

    // MARK: – Actions

    private func replaceStem(_ kind: StemKind, with url: URL, kind replaceKind: StemReplaceKind) {
        stemStates[kind]?.url = url
        stemStates[kind]?.replaceKind = replaceKind
        preview.stop()
    }

    private func resetStem(_ kind: StemKind) {
        stemStates[kind]?.url = nil
        stemStates[kind]?.replaceKind = .original
        preview.stop()
    }

    private func startRecording(_ kind: StemKind) {
        guard !recorder.isRecording else { return }
        activeStem = kind
        stemStates[kind]?.isRecording = true
        Task {
            do {
                _ = try recorder.startRecording()
            } catch {
                stemStates[kind]?.isRecording = false
                activeStem = nil
                print("[Remix] recorder start failed: \(error)")
            }
        }
    }

    private func stopRecording(_ kind: StemKind) {
        recorder.stopRecording()
        stemStates[kind]?.isRecording = false
        if let url = recorder.lastRecordingURL {
            replaceStem(kind, with: url, kind: .recorded)
        }
        activeStem = nil
    }

    private func startOverdub(_ kind: StemKind) {
        guard !overdubRecorder.isRecording else { return }
        guard let parentStems = track.stems else {
            // No parent stems — fall back to plain recording with a note.
            startRecording(kind)
            return
        }
        let srcURL = stemStates[kind]?.url ?? parentStems.url(for: kind)
        activeOverdubStem = kind
        do {
            _ = try overdubRecorder.start(sourceURL: srcURL)
        } catch {
            activeOverdubStem = nil
            print("[Remix] overdub start failed, falling back to plain record: \(error)")
            // TODO: overdub — fall back to re-record when overdub engine fails
            startRecording(kind)
        }
    }

    private func stopOverdub(_ kind: StemKind) {
        overdubRecorder.stop()
        if let url = overdubRecorder.lastRecordingURL {
            replaceStem(kind, with: url, kind: .overdub)
        }
        activeOverdubStem = nil
    }

    private func submitRemix() {
        guard !isPosting else { return }
        isPosting = true
        preview.stop()

        // Build stem map: use replaced URL or fall back to parent stem.
        var newStems: [StemKind: URL] = [:]
        for kind in StemKind.allCases {
            if let url = stemStates[kind]?.url {
                newStems[kind] = url
            } else if let parentStem = track.stems?.url(for: kind) {
                newStems[kind] = parentStem
            }
        }

        let title = composerTitle
        let bio = composerBio
        let cover = composerCoverData
        let token = auth.token

        library.createRemix(
            parent: track,
            title: title,
            bio: bio,
            newStems: newStems,
            cover: cover,
            token: token
        )

        withAnimation(.easeInOut(duration: 0.3)) {
            isPosting = false
            postSuccess = true
        }

        // Dismiss after a short beat so the user sees "posted!".
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        }
    }
}
