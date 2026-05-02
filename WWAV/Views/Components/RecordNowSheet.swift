import AVFoundation
import SwiftUI

// MARK: – Recording state machine

enum RecordLaneState: Equatable {
    case idle
    case recording
    case paused
    case done
}

// MARK: – MultitrackRecorderEngine

/// Drives both single-take and multitrack recording.
///
/// Architecture:
/// - `AVAudioRecorder` writes the actual 16-bit PCM WAV file; `pause()` /
///   `record()` on that same instance give a single contiguous file.
/// - A parallel `AVAudioEngine` tap on `inputNode` feeds rolling RMS peaks
///   (published at ~30 Hz) for the live waveform visualisations.
/// - Each lane is fully independent: stopping lane A while lane B is active
///   simply pauses A's recorder and removes A's tap; B remains untouched.
@MainActor
final class MultitrackRecorderEngine: NSObject, ObservableObject {

    // MARK: Published state

    /// Per-lane peak history (last kMaxPeaks samples, newest first).
    @Published private(set) var peaks: [StemKind: [Float]] = Dictionary(
        uniqueKeysWithValues: StemKind.allCases.map { ($0, [Float]()) }
    )
    /// Per-lane record/pause/done state.
    @Published private(set) var laneState: [StemKind: RecordLaneState] = Dictionary(
        uniqueKeysWithValues: StemKind.allCases.map { ($0, RecordLaneState.idle) }
    )
    /// Single-take waveform peaks (newest first).
    @Published private(set) var singlePeaks: [Float] = []
    /// Single-take state.
    @Published private(set) var singleState: RecordLaneState = .idle
    /// Running elapsed seconds for the *currently* active lane/take.
    @Published private(set) var elapsed: TimeInterval = 0
    /// Human-readable elapsed e.g. "1:23".
    var formattedElapsed: String {
        let s = max(0, Int(elapsed))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    /// The finalised single-take URL (available after finishSingle()).
    @Published private(set) var singleFinishedURL: URL?
    /// Set when something goes wrong; displayed in the UI.
    @Published var errorMessage: String?

    // MARK: Internal bookkeeping

    private struct LaneContext {
        var recorder: AVAudioRecorder
        var url: URL
        var tapInstalled: Bool = false
    }

    private var laneContexts: [StemKind: LaneContext] = [:]
    private var singleContext: LaneContext?
    private var activeLane: StemKind? = nil   // nil → single mode active
    private var isSingleMode: Bool = false

    private let engine = AVAudioEngine()
    private var engineRunning = false
    private var timer: Timer?

    private static let kMaxPeaks = 256
    private static let kSampleRate: Double = 44_100
    private static let kTapBufferSize: AVAudioFrameCount = 1024

    // MARK: Init

    override init() {
        super.init()
    }

    // MARK: Permission helper

    private func requestMicPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: AVAudioSession helpers

    private func activateRecordSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true)
    }

    private func restorePlaybackSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: Tap helpers

    private func installTap(for kind: StemKind?) {
        guard !engineRunning else { return }
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.kTapBufferSize,
            format: format
        ) { [weak self] buffer, _ in
            guard let self else { return }
            let rms = Self.rms(buffer: buffer)
            Task { @MainActor in
                if let lane = kind {
                    var arr = self.peaks[lane] ?? []
                    arr.insert(rms, at: 0)
                    if arr.count > Self.kMaxPeaks { arr.removeLast() }
                    self.peaks[lane] = arr
                } else {
                    self.singlePeaks.insert(rms, at: 0)
                    if self.singlePeaks.count > Self.kMaxPeaks { self.singlePeaks.removeLast() }
                }
            }
        }
        do {
            try engine.start()
            engineRunning = true
        } catch {
            print("[RecorderEngine] AVAudioEngine start failed: \(error)")
        }
    }

    private func removeTap() {
        guard engineRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engineRunning = false
    }

    // MARK: RMS computation

    private static func rms(buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var sum: Float = 0
        let channel = data[0]
        for i in 0..<frameCount {
            let s = channel[i]
            sum += s * s
        }
        return (sum / Float(frameCount)).squareRoot()
    }

    // MARK: Recorder construction

    private func makeRecorder(label: String) throws -> (AVAudioRecorder, URL) {
        let safe = label.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wwav-\(safe)-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Self.kSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.prepareToRecord()
        return (rec, url)
    }

    // MARK: Timer

    private func startTimer(for kind: StemKind?) {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let lane = kind {
                    self.elapsed = self.laneContexts[lane]?.recorder.currentTime ?? self.elapsed
                } else {
                    self.elapsed = self.singleContext?.recorder.currentTime ?? self.elapsed
                }
            }
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: – Public API

    /// Start or resume recording for `kind` lane (multitrack).
    func startLane(_ kind: StemKind) {
        Task { @MainActor in
            let granted = await requestMicPermission()
            guard granted else {
                errorMessage = "microphone permission is needed to record."
                return
            }
            do {
                try activateRecordSession()
                // Pause any other active lane first.
                if let other = activeLane, other != kind {
                    pauseLane(other)
                }
                activeLane = kind
                isSingleMode = false

                if let ctx = laneContexts[kind], laneState[kind] == .paused {
                    // Resume existing recorder — single contiguous file.
                    ctx.recorder.record()
                    laneState[kind] = .recording
                } else {
                    // Fresh take: tear down old context if any.
                    laneContexts[kind]?.recorder.stop()
                    let (rec, url) = try makeRecorder(label: kind.rawValue)
                    rec.record()
                    laneContexts[kind] = LaneContext(recorder: rec, url: url)
                    peaks[kind] = []
                    laneState[kind] = .recording
                }

                // Install AVAudioEngine tap for this lane.
                removeTap()
                installTap(for: kind)
                startTimer(for: kind)
                errorMessage = nil
            } catch {
                errorMessage = "couldn't start recording: \(error.localizedDescription)"
            }
        }
    }

    /// Pause the given lane (tap-to-pause path).
    func pauseLane(_ kind: StemKind) {
        guard laneState[kind] == .recording else { return }
        laneContexts[kind]?.recorder.pause()
        laneState[kind] = .paused
        if activeLane == kind {
            activeLane = nil
            removeTap()
            stopTimer()
        }
    }

    /// Toggle record/pause for a lane.
    func toggleLane(_ kind: StemKind) {
        switch laneState[kind] ?? .idle {
        case .idle, .done:
            startLane(kind)
        case .recording:
            pauseLane(kind)
        case .paused:
            startLane(kind)
        }
    }

    /// Finish and finalise a lane's recording. Returns the file URL.
    @discardableResult
    func finishLane(_ kind: StemKind) -> URL? {
        guard laneContexts[kind] != nil else { return nil }
        let url = laneContexts[kind]?.url
        laneContexts[kind]?.recorder.stop()
        if activeLane == kind {
            activeLane = nil
            removeTap()
            stopTimer()
        }
        laneState[kind] = .done
        // Keep context so caller can retrieve URL via laneURL(for:)
        return url
    }

    func laneURL(for kind: StemKind) -> URL? {
        laneContexts[kind]?.url
    }

    // MARK: Single-take API

    /// Start or resume single-take recording.
    func startSingle() {
        Task { @MainActor in
            let granted = await requestMicPermission()
            guard granted else {
                errorMessage = "microphone permission is needed to record."
                return
            }
            do {
                try activateRecordSession()
                isSingleMode = true
                activeLane = nil

                if let ctx = singleContext, singleState == .paused {
                    ctx.recorder.record()
                    singleState = .recording
                } else {
                    singleContext?.recorder.stop()
                    let (rec, url) = try makeRecorder(label: "single")
                    rec.record()
                    singleContext = LaneContext(recorder: rec, url: url)
                    singlePeaks = []
                    singleState = .recording
                }

                removeTap()
                installTap(for: nil)
                startTimer(for: nil)
                errorMessage = nil
            } catch {
                errorMessage = "couldn't start recording: \(error.localizedDescription)"
            }
        }
    }

    func pauseSingle() {
        guard singleState == .recording else { return }
        singleContext?.recorder.pause()
        singleState = .paused
        removeTap()
        stopTimer()
    }

    func toggleSingle() {
        switch singleState {
        case .idle, .done:
            startSingle()
        case .recording:
            pauseSingle()
        case .paused:
            startSingle()
        }
    }

    @discardableResult
    func finishSingle() -> URL? {
        let url = singleContext?.url
        singleContext?.recorder.stop()
        singleContext = nil
        singleState = .done
        singleFinishedURL = url
        removeTap()
        stopTimer()
        restorePlaybackSession()
        return url
    }

    func discardSingle() {
        singleContext?.recorder.stop()
        if let url = singleContext?.url {
            try? FileManager.default.removeItem(at: url)
        }
        singleContext = nil
        singlePeaks = []
        singleState = .idle
        singleFinishedURL = nil
        removeTap()
        stopTimer()
    }

    // MARK: Cancel all

    func cancel() {
        stopTimer()
        removeTap()
        for kind in StemKind.allCases {
            laneContexts[kind]?.recorder.stop()
            if let url = laneContexts[kind]?.url {
                try? FileManager.default.removeItem(at: url)
            }
        }
        laneContexts = [:]
        singleContext?.recorder.stop()
        if let url = singleContext?.url {
            try? FileManager.default.removeItem(at: url)
        }
        singleContext = nil
        for kind in StemKind.allCases {
            laneState[kind] = .idle
            peaks[kind] = []
        }
        singleState = .idle
        singlePeaks = []
        singleFinishedURL = nil
        activeLane = nil
        restorePlaybackSession()
    }
}

// MARK: – RecordNowSheet

struct RecordNowSheet: View {
    let onSingleRecording: (URL) -> Void
    let onMultitrackRecording: ([StemKind: URL]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @StateObject private var engine = MultitrackRecorderEngine()
    @State private var mode: RecordingMode = .single
    /// Finalised multitrack URLs per lane.
    @State private var laneDoneURLs: [StemKind: URL] = [:]
    /// Which lane the user has focused for recording.
    @State private var focusedLane: StemKind = .vox

    private var multitrackComplete: Bool {
        StemKind.allCases.allSatisfy { laneDoneURLs[$0] != nil }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.pageRadial.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("record now").wwavTitle(size: 36)
                        modePicker

                        if mode == .single {
                            singleSection
                        } else {
                            multitrackSection
                        }

                        if let msg = engine.errorMessage {
                            Text(msg)
                                .font(.wwav(12, weight: .light, italic: true))
                                .foregroundStyle(Color.red.opacity(0.72))
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") {
                        engine.cancel()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onDisappear { engine.cancel() }
    }

    // MARK: Mode picker

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(RecordingMode.allCases) { option in
                let active = mode == option
                Button {
                    guard engine.singleState != .recording,
                          !StemKind.allCases.contains(where: { engine.laneState[$0] == .recording }) else { return }
                    withAnimation(.easeInOut(duration: 0.18)) { mode = option }
                } label: {
                    Text(option.label)
                        .font(.wwav(12, weight: active ? .medium : .light, italic: true))
                        .tracking(1.4)
                        .foregroundStyle(active ? theme.glow : theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(active ? theme.accent : theme.muted.opacity(0.10)))
                        .overlay(Capsule().stroke(theme.muted.opacity(active ? 0 : 0.22), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Single-take section

    private var singleSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("record one full take — WWAV will split it into stems during upload.")
                .font(.wwav(13, weight: .light, italic: true))
                .foregroundStyle(theme.muted)

            // Waveform (large vertical lane)
            SingleLaneStage(peaks: engine.singlePeaks, isActive: engine.singleState == .recording)
                .frame(maxWidth: .infinity)
                .frame(height: 200)

            // Record button with tap + hold gestures
            RecordPillButton(
                state: engine.singleState,
                elapsed: engine.formattedElapsed,
                onTap: {
                    if engine.singleState == .recording {
                        engine.pauseSingle()
                    } else if engine.singleState == .paused || engine.singleState == .idle {
                        engine.startSingle()
                    }
                },
                onHoldStart: {
                    guard engine.singleState == .idle || engine.singleState == .done || engine.singleState == .paused else { return }
                    engine.startSingle()
                },
                onHoldEnd: {
                    engine.pauseSingle()
                }
            )

            // Done / discard row
            HStack(spacing: 10) {
                if engine.singleState == .recording || engine.singleState == .paused {
                    Button {
                        engine.finishSingle()
                    } label: {
                        donePillLabel("done recording")
                    }
                    .buttonStyle(.plain)
                }
                if engine.singleState == .paused || engine.singleState == .done {
                    Button {
                        engine.discardSingle()
                    } label: {
                        Text("discard")
                            .font(.wwav(12, weight: .light, italic: true))
                            .tracking(1.2)
                            .foregroundStyle(theme.muted)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Capsule().fill(theme.muted.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Taken URL row
            if let url = engine.singleFinishedURL {
                recordedFileRow(url: url, title: "single take")
            }

            // Use button
            Button {
                guard let url = engine.singleFinishedURL else { return }
                onSingleRecording(url)
                dismiss()
            } label: {
                Text("use single take")
                    .font(.wwav(15, weight: .regular, italic: true)).tracking(2)
                    .foregroundStyle(theme.glow).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top, endPoint: .bottom))
                    )
            }
            .buttonStyle(.plain)
            .disabled(engine.singleFinishedURL == nil)
            .opacity(engine.singleFinishedURL == nil ? 0.45 : 1)
        }
    }

    // MARK: Multitrack section

    private var multitrackSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("record directly into the four stem-player lanes.")
                .font(.wwav(13, weight: .light, italic: true))
                .foregroundStyle(theme.muted)

            // Four-lane stage
            MultitrackLaneStage(
                peaks: engine.peaks,
                laneStates: engine.laneState,
                focusedLane: focusedLane,
                onSelectLane: { focusedLane = $0 }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 260)

            // Focused lane label + record button
            VStack(alignment: .leading, spacing: 10) {
                Text("lane: \(focusedLane.label)")
                    .font(.wwav(11, weight: .light)).tracking(2)
                    .foregroundStyle(theme.muted)

                RecordPillButton(
                    state: engine.laneState[focusedLane] ?? .idle,
                    elapsed: engine.formattedElapsed,
                    onTap: {
                        let st = engine.laneState[focusedLane] ?? .idle
                        if st == .recording {
                            engine.pauseLane(focusedLane)
                        } else {
                            engine.startLane(focusedLane)
                        }
                    },
                    onHoldStart: {
                        let st = engine.laneState[focusedLane] ?? .idle
                        guard st != .recording else { return }
                        engine.startLane(focusedLane)
                    },
                    onHoldEnd: {
                        engine.pauseLane(focusedLane)
                    }
                )

                // Done / discard for focused lane
                let laneIsActive = (engine.laneState[focusedLane] == .recording || engine.laneState[focusedLane] == .paused)
                let laneHasTake = laneDoneURLs[focusedLane] != nil
                HStack(spacing: 10) {
                    if laneIsActive {
                        Button {
                            if let url = engine.finishLane(focusedLane) {
                                laneDoneURLs[focusedLane] = url
                            }
                        } label: {
                            donePillLabel("done: \(focusedLane.label)")
                        }
                        .buttonStyle(.plain)
                    }
                    if laneHasTake {
                        Button {
                            laneDoneURLs.removeValue(forKey: focusedLane)
                            // Reset lane so user can re-record
                            // The engine discards via startLane fresh on next record.
                        } label: {
                            Text("redo")
                                .font(.wwav(12, weight: .light, italic: true))
                                .tracking(1.2)
                                .foregroundStyle(theme.muted)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(Capsule().fill(theme.muted.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Lane status list
            VStack(spacing: 0) {
                ForEach(StemKind.allCases) { kind in
                    laneStatusRow(kind)
                    if kind != StemKind.allCases.last {
                        Rectangle().fill(theme.muted.opacity(0.14)).frame(height: 1).padding(.leading, 52)
                    }
                }
            }
            .background(sheetBoxBg)
            .overlay(sheetBoxStroke)

            // Use multitrack button
            Button {
                guard multitrackComplete else { return }
                onMultitrackRecording(laneDoneURLs)
                dismiss()
            } label: {
                Text("use multitrack")
                    .font(.wwav(15, weight: .regular, italic: true)).tracking(2)
                    .foregroundStyle(theme.glow).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top, endPoint: .bottom))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!multitrackComplete)
            .opacity(multitrackComplete ? 1 : 0.45)
        }
    }

    // MARK: Lane status row

    private func laneStatusRow(_ kind: StemKind) -> some View {
        let st = engine.laneState[kind] ?? .idle
        let hasTake = laneDoneURLs[kind] != nil
        let isFocused = focusedLane == kind
        return Button {
            focusedLane = kind
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            st == .recording ? Color.red.opacity(0.78) :
                            (hasTake ? theme.accent :
                             (isFocused ? theme.clay.opacity(0.5) : theme.muted.opacity(0.14)))
                        )
                    Image(systemName: hasTake ? "checkmark" : (st == .recording ? "waveform" : "mic"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(hasTake || st == .recording ? theme.glow : (isFocused ? theme.ink : theme.muted))
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.label)
                        .font(.wwav(15, weight: .medium))
                        .foregroundStyle(theme.ink)
                    Text(stateLabel(st, hasTake: hasTake, kind: kind))
                        .font(.wwav(10, weight: .light)).tracking(1)
                        .foregroundStyle(theme.muted)
                }

                Spacer()

                if isFocused {
                    Text("active")
                        .font(.wwav(9, weight: .light)).tracking(1.5)
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(theme.accent.opacity(0.12)))
                }
            }
            .padding(12)
            .background(isFocused ? theme.clay.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func stateLabel(_ st: RecordLaneState, hasTake: Bool, kind: StemKind) -> String {
        if hasTake { return "done" }
        switch st {
        case .idle: return "empty"
        case .recording: return engine.formattedElapsed
        case .paused: return "paused — tap to resume"
        case .done: return "done"
        }
    }

    // MARK: Shared helpers

    private var sheetBoxBg: some View {
        RoundedRectangle(cornerRadius: 14).fill(
            LinearGradient(
                colors: [theme.sand, theme.sandDeep.opacity(0.6)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private var sheetBoxStroke: some View {
        RoundedRectangle(cornerRadius: 14).stroke(theme.muted.opacity(0.25), lineWidth: 1)
    }

    private func donePillLabel(_ text: String) -> some View {
        Text(text)
            .font(.wwav(13, weight: .medium, italic: true)).tracking(1.2)
            .foregroundStyle(theme.glow)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [theme.clay, theme.clayDeep],
                        startPoint: .leading, endPoint: .trailing))
            )
    }

    private func recordedFileRow(url: URL, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.glow)
                .frame(width: 38, height: 38)
                .background(Circle().fill(theme.accent))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.wwav(14, weight: .medium)).foregroundStyle(theme.ink)
                Text(url.lastPathComponent)
                    .font(.wwav(10, weight: .light)).foregroundStyle(theme.muted).lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
        .background(sheetBoxBg)
        .overlay(sheetBoxStroke)
    }
}

// MARK: – RecordPillButton
//
// Single button that handles:
//   • Quick tap  → toggle record/pause
//   • Long press (≥0.18 s) held → starts recording; releasing ends (hold-to-record)
//
// The hold path uses a LongPressGesture sequenced with a DragGesture so we get
// an onEnded callback when the finger lifts.

private struct RecordPillButton: View {
    let state: RecordLaneState
    let elapsed: String
    let onTap: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void

    @State private var holdActive = false
    @Environment(\.theme) private var theme

    private var isRecording: Bool { state == .recording }

    var body: some View {
        ZStack {
            // Background pulse when recording.
            if isRecording {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.red.opacity(0.18))
                    .scaleEffect(holdActive ? 1.04 : 1.0)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isRecording)
            }

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Color.red.opacity(0.85) : (state == .paused ? theme.clay : theme.muted.opacity(0.22)))
                        .frame(width: 48, height: 48)
                    Image(systemName: isRecording ? "pause.fill" : (state == .paused ? "play.fill" : "record.circle"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isRecording ? .white : (state == .paused ? theme.glow : theme.ink))
                }
                .shadow(color: isRecording ? Color.red.opacity(0.45) : .clear, radius: 10)

                VStack(alignment: .leading, spacing: 3) {
                    Text(buttonTitle)
                        .font(.wwav(14, weight: .medium, italic: true))
                        .foregroundStyle(isRecording ? theme.glow : theme.ink)
                    Text(isRecording ? elapsed : subLabel)
                        .font(.wwav(10, weight: .light)).tracking(1)
                        .foregroundStyle(theme.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isRecording ? Color.red.opacity(0.76) : theme.sand.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(theme.muted.opacity(isRecording ? 0 : 0.22), lineWidth: 1)
            )
        }
        .gesture(
            // Hold-to-record: long press triggers onHoldStart; drag ending triggers onHoldEnd.
            LongPressGesture(minimumDuration: 0.18)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { value in
                    switch value {
                    case .first(true):
                        if !holdActive {
                            holdActive = true
                            onHoldStart()
                        }
                    default:
                        break
                    }
                }
                .onEnded { _ in
                    if holdActive {
                        holdActive = false
                        onHoldEnd()
                    }
                }
        )
        // Tap-to-toggle sits on top; it fires before the long press completes its minimum duration.
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    guard !holdActive else { return }
                    onTap()
                }
        )
        .animation(.easeInOut(duration: 0.18), value: state)
    }

    private var buttonTitle: String {
        switch state {
        case .idle: return "record"
        case .recording: return "pause"
        case .paused: return "resume"
        case .done: return "record again"
        }
    }

    private var subLabel: String {
        switch state {
        case .idle: return "tap or hold"
        case .paused: return "tap or hold to resume"
        case .done: return "take complete"
        case .recording: return ""
        }
    }
}

// MARK: – Single-lane waveform

struct SingleLaneStage: View {
    let peaks: [Float]
    let isActive: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { ctx, size in
            drawLane(
                ctx: ctx,
                size: size,
                peaks: peaks,
                accent: isActive ? UIColor(theme.accent) : UIColor(theme.muted),
                dim: false
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [theme.clay.opacity(0.12), theme.clayDeep.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isActive ? theme.accent.opacity(0.5) : theme.muted.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: – Shared waveform drawing helper

private func drawLane(
    ctx: GraphicsContext,
    size: CGSize,
    peaks: [Float],
    accent: UIColor,
    dim: Bool
) {
    guard !peaks.isEmpty else { return }
    let color = Color(uiColor: accent).opacity(dim ? 0.35 : 0.88)
    let blockH: CGFloat = 3
    let gap: CGFloat = 1
    let stride = blockH + gap
    let maxBlocks = Int(size.height / stride)
    let centerX = size.width / 2

    for i in 0..<min(maxBlocks, peaks.count) {
        let rms = peaks[i]
        let half = CGFloat(rms) * (size.width * 0.46)
        let y = CGFloat(i) * stride
        let rect = CGRect(x: centerX - half, y: y, width: half * 2, height: blockH)
        var path = Path(roundedRect: rect, cornerRadius: 1)
        ctx.fill(path, with: .color(color))
        // Baseline
        let baseRect = CGRect(x: centerX - 1, y: y, width: 2, height: blockH)
        path = Path(roundedRect: baseRect, cornerRadius: 0.5)
        ctx.fill(path, with: .color(color.opacity(0.3)))
    }
}

// MARK: – Multitrack lane stage (four vertical columns)

private enum RecordingMode: String, CaseIterable, Identifiable {
    case single
    case multitrack

    var id: String { rawValue }

    var label: String {
        switch self {
        case .single: return "single"
        case .multitrack: return "multitrack"
        }
    }
}
