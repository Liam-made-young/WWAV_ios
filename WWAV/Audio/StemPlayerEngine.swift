import Foundation
import AVFoundation
import Combine
import MediaPlayer

enum StemRemixEffect: String, CaseIterable, Identifiable, Sendable {
    case distortion
    case delay
    case reverb
    case tremolo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .distortion: return "dist"
        case .delay: return "delay"
        case .reverb: return "reverb"
        case .tremolo: return "tremolo"
        }
    }

    var icon: String {
        switch self {
        case .distortion: return "bolt.fill"
        case .delay: return "repeat"
        case .reverb: return "sparkles"
        case .tremolo: return "waveform.path"
        }
    }
}

struct StemEffectState: Equatable, Sendable {
    var distortion: Double = 0
    var delay: Double = 0
    var reverb: Double = 0
    var tremolo: Double = 0

    static let zero = StemEffectState()

    var hasActiveEffects: Bool {
        distortion > 0.001 || delay > 0.001 || reverb > 0.001 || tremolo > 0.001
    }

    func value(for effect: StemRemixEffect) -> Double {
        switch effect {
        case .distortion: return distortion
        case .delay: return delay
        case .reverb: return reverb
        case .tremolo: return tremolo
        }
    }

    mutating func set(_ effect: StemRemixEffect, value: Double) {
        let v = max(0, min(1, value))
        switch effect {
        case .distortion: distortion = v
        case .delay: delay = v
        case .reverb: reverb = v
        case .tremolo: tremolo = v
        }
    }
}

/// Plays four stems in sample-lock. Per-stem volume changes are applied to mixer
/// nodes in real time, so the user can solo or fade individual stems while playing.
@MainActor
final class StemPlayerEngine: ObservableObject {

    // MARK: – Public state
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var volumes: [StemKind: Double] = [
        .vox: 0.85, .bass: 0.70, .drum: 0.90, .synth: 0.55
    ]
    @Published private(set) var effects: [StemKind: StemEffectState] = StemPlayerEngine.defaultEffectStates()
    /// 240 peak amplitudes [0...1] for the loaded track's drums/vox stem,
    /// used to render the circular waveform around the 3-D widget.
    @Published private(set) var peaks: [Float] = WaveformAnalyzer.placeholderPeaks()
    /// Track currently being downloaded / prepared for playback. nil when
    /// the engine isn't fetching anything. Drives the loading overlay on
    /// the play view.
    @Published private(set) var preparingTrack: Track?
    /// 0...1 progress for `preparingTrack`, advanced once per stem as
    /// `prepareForPlayback` walks through the four files.
    @Published private(set) var preparingProgress: Double = 0

    /// Playback rate applied to every stem's `AVAudioUnitTimePitch`. 0.5...2.0.
    /// Pitch is preserved (TimePitch's whole job).
    @Published private(set) var playbackRate: Double = 1.0
    /// Pitch shift in semitones applied to every stem. -12...+12.
    /// Tempo is preserved.
    @Published private(set) var pitchSemitones: Double = 0
    /// Beat length of the active in-place loop, or nil when looping is off.
    @Published private(set) var activeLoopBeats: Double? = nil
    /// Beats-per-minute used to translate the beat-length buttons into a
    /// frame count for the loop region. Default 120; user-editable.
    @Published var loopBPM: Double = 120

    // MARK: – Engine guts
    private let engine = AVAudioEngine()
    private struct StemNodeChain {
        let player: AVAudioPlayerNode
        let timePitch: AVAudioUnitTimePitch
        let distortion: AVAudioUnitDistortion
        let delay: AVAudioUnitDelay
        let reverb: AVAudioUnitReverb
        let mixer: AVAudioMixerNode
    }

    private var nodes: [StemKind: StemNodeChain] = [:]
    private var files: [StemKind: AVAudioFile] = [:]
    private var stemURLs: [StemKind: URL] = [:]
    private var monitoringMuted: Set<StemKind> = []
    private var startSampleTime: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private var pausedFrame: AVAudioFramePosition = 0
    private var displayTimer: Timer?
    /// Bumped every time we cancel or replace the current schedule. Lets us
    /// ignore stale `dataPlayedBack` completion callbacks that AVAudioPlayerNode
    /// still fires after a `.stop()` — without this, pausing fires the "track
    /// ended" handler for the cancelled buffer and resets pausedFrame to 0.
    private var playGeneration: Int = 0
    /// File frame where the active loop region begins. Frame-space, before
    /// any TimePitch resampling — `currentFrame()` uses this to fold the
    /// player's monotonically-increasing sampleTime back into a moving
    /// playhead inside the region.
    private var loopStartFrame: AVAudioFramePosition = 0
    private var loopFrameCount: AVAudioFrameCount = 0
    private var loopBuffers: [StemKind: AVAudioPCMBuffer] = [:]

    init() {
        configureSession()
        installNodes()
        setupRemoteCommands()
        observeInterruptions()
    }

    // MARK: – Public API

    /// Marks the engine as preparing a new track. Pauses any currently
    /// playing track immediately so the previous song doesn't keep playing
    /// while the new one's stems are still downloading.
    func beginPreparing(_ track: Track) {
        if isPlaying { pause() }
        preparingTrack = track
        preparingProgress = 0
    }

    /// Advances the prepare progress. Safe to call from any actor — caller
    /// must already be on the main actor since the engine is @MainActor.
    func updatePrepareProgress(_ p: Double) {
        preparingProgress = max(preparingProgress, min(1, max(0, p)))
    }

    /// Clears the preparing state. Call once `load(_:)` has succeeded or
    /// when the prepare attempt has been cancelled / failed.
    func endPreparing() {
        preparingTrack = nil
        preparingProgress = 0
    }

    func volume(for kind: StemKind) -> Double {
        volumes[kind] ?? 0
    }

    func setVolume(_ value: Double, for kind: StemKind) {
        let v = max(0, min(1, value))
        volumes[kind] = v
        applyOutputVolume(for: kind)
    }

    func effectState(for kind: StemKind) -> StemEffectState {
        effects[kind] ?? .zero
    }

    func effectValue(_ effect: StemRemixEffect, for kind: StemKind) -> Double {
        effectState(for: kind).value(for: effect)
    }

    func setEffect(_ effect: StemRemixEffect, value: Double, for kind: StemKind) {
        var state = effectState(for: kind)
        state.set(effect, value: value)
        effects[kind] = state
        applyEffectState(state, for: kind)
    }

    func resetEffects(for kind: StemKind) {
        effects[kind] = .zero
        applyEffectState(.zero, for: kind)
    }

    func resetAllEffects() {
        effects = Self.defaultEffectStates()
        for kind in StemKind.allCases {
            applyEffectState(effects[kind] ?? .zero, for: kind)
        }
    }

    // MARK: – Time / pitch / loop

    func setPlaybackRate(_ value: Double) {
        let v = max(0.5, min(2.0, value))
        playbackRate = v
        for (_, chain) in nodes {
            chain.timePitch.rate = Float(v)
        }
        if isPlaying { updateNowPlaying() }
    }

    func setPitch(_ semitones: Double) {
        let v = max(-12, min(12, semitones))
        pitchSemitones = v
        for (_, chain) in nodes {
            chain.timePitch.pitch = Float(v * 100)  // cents
        }
    }

    func resetTimeAndPitch() {
        setPlaybackRate(1.0)
        setPitch(0)
    }

    func setLoopBPM(_ bpm: Double) {
        let v = max(40, min(220, bpm))
        loopBPM = v
        if let beats = activeLoopBeats {
            // Re-anchor the loop on the current region start so BPM tweaks
            // resize the region in place rather than dragging the playhead.
            enableLoop(beats: beats, bpm: v, anchorFrame: loopStartFrame)
        }
    }

    /// Captures the current playhead, schedules a `frameCount`-frame buffer
    /// of every stem, and asks the player nodes to loop it indefinitely.
    /// The downstream TimePitch unit handles wall-clock stretching, so a
    /// loop of N beats stays musically N beats regardless of `playbackRate`.
    func enableLoop(beats: Double, bpm: Double) {
        enableLoop(beats: beats, bpm: bpm, anchorFrame: nil)
    }

    private func enableLoop(beats: Double, bpm: Double, anchorFrame: AVAudioFramePosition?) {
        guard currentTrack != nil, let voxFile = files[.vox] else { return }
        let safeBPM = max(40, min(220, bpm))
        let secondsPerBeat = 60.0 / safeBPM
        let wantedFrames = AVAudioFrameCount(max(0, beats * secondsPerBeat * sampleRate))
        let startFrame = anchorFrame ?? currentFrame()
        let maxFrames = AVAudioFrameCount(max(0, voxFile.length - startFrame))
        let count = min(wantedFrames, maxFrames)
        // Below ~one slice the loop would just chatter — bail out.
        guard count > 1024 else { return }

        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            print("StemPlayerEngine.enableLoop engine start failed: \(error)")
            return
        }

        playGeneration += 1
        for (_, pair) in nodes { pair.player.stop() }
        loopBuffers.removeAll()

        let when = AVAudioTime(
            hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05)
        )

        for kind in StemKind.allCases {
            guard let file = files[kind], let pair = nodes[kind] else { continue }
            let stemAvailable = AVAudioFrameCount(max(0, file.length - startFrame))
            let n = min(count, stemAvailable)
            guard n > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: n
                  )
            else { continue }
            file.framePosition = startFrame
            do {
                try file.read(into: buffer, frameCount: n)
            } catch {
                print("StemPlayerEngine.enableLoop read \(kind) failed: \(error)")
                continue
            }
            loopBuffers[kind] = buffer
            pair.player.scheduleBuffer(
                buffer,
                at: when,
                options: [.loops, .interruptsAtLoop],
                completionCallbackType: .dataPlayedBack
            ) { _ in
                // Swallowed — `.loops` should never fire end-of-buffer; if
                // disableLoop / stop pulls the rug, the generation guard in
                // `handleStemFinished` catches it.
            }
            pair.player.play(at: when)
        }

        loopStartFrame = startFrame
        loopFrameCount = count
        activeLoopBeats = beats
        loopBPM = safeBPM
        startSampleTime = startFrame
        pausedFrame = startFrame
        isPlaying = true
        startDisplayLoop()
        updateNowPlaying()
    }

    func disableLoop() {
        guard activeLoopBeats != nil else { return }
        let resumeFrame = currentFrame()
        activeLoopBeats = nil
        loopFrameCount = 0
        loopBuffers.removeAll()
        playGeneration += 1
        for (_, pair) in nodes { pair.player.stop() }
        pausedFrame = resumeFrame
        if currentTrack != nil {
            scheduleAllAndPlay(fromFrame: resumeFrame)
        }
    }

    private var isLooping: Bool { activeLoopBeats != nil }

    func setStemMonitoringMuted(_ muted: Bool, for kind: StemKind) {
        if muted {
            monitoringMuted.insert(kind)
        } else {
            monitoringMuted.remove(kind)
        }
        applyOutputVolume(for: kind)
    }

    func currentStemURL(for kind: StemKind) -> URL? {
        stemURLs[kind]
    }

    func currentStemURLs() -> [StemKind: URL] {
        stemURLs
    }

    func replaceStem(_ kind: StemKind, with url: URL) throws {
        guard currentTrack != nil else { return }
        let file = try AVAudioFile(forReading: url)
        let wasPlaying = isPlaying
        let frame = wasPlaying ? currentFrame() : pausedFrame

        playGeneration += 1
        for (_, pair) in nodes { pair.player.stop() }

        files[kind] = file
        stemURLs[kind] = url
        recalculateDuration()

        if var track = currentTrack, var bundle = track.stems {
            switch kind {
            case .vox: bundle.vox = url
            case .bass: bundle.bass = url
            case .drum: bundle.drum = url
            case .synth: bundle.synth = url
            }
            track.stems = bundle
            currentTrack = track
        }

        pausedFrame = min(frame, AVAudioFramePosition(duration * sampleRate))
        elapsed = min(duration, Double(pausedFrame) / sampleRate)

        if kind == .drum {
            computePeaksAsync(for: url)
        }

        if wasPlaying {
            scheduleAllAndPlay(fromFrame: pausedFrame)
        } else {
            updateNowPlaying()
        }
    }

    /// Loads a track's stems into the engine and starts playback at frame 0.
    ///
    /// Files are swapped atomically: the new four are decoded into a local
    /// dictionary first, and only after all four succeed do they replace the
    /// engine's `files`. This prevents the "Frankenstein" mode where a
    /// partially-failed load leaves stale files for some stems and new files
    /// for others, causing different tracks to silently share audio.
    func load(_ track: Track) {
        guard let bundle = track.stems else { return }

        // Hard reset audio state before touching anything new.
        stopAll()
        for (_, pair) in nodes { pair.player.reset() }
        files.removeAll()
        stemURLs.removeAll()
        monitoringMuted.removeAll()
        resetAllEffects()
        // Tempo / pitch / loop are per-track — a fresh song starts at 1.0×,
        // 0 semitones, no loop. Without this, stale loop buffers from the
        // previous track would dangle in `loopBuffers`.
        activeLoopBeats = nil
        loopFrameCount = 0
        loopBuffers.removeAll()
        setPlaybackRate(1.0)
        setPitch(0)
        currentTrack = track
        elapsed = 0
        pausedFrame = 0
        duration = 0

        do {
            try AVAudioSession.sharedInstance().setActive(true)
            var newFiles: [StemKind: AVAudioFile] = [:]
            var newSampleRate: Double = sampleRate
            var newDuration: Double = 0
            for kind in StemKind.allCases {
                let url = bundle.url(for: kind)
                let file = try AVAudioFile(forReading: url)
                newFiles[kind] = file
                stemURLs[kind] = url
                newSampleRate = file.processingFormat.sampleRate
                newDuration = max(newDuration, Double(file.length) / newSampleRate)
            }
            // Commit only after every stem decoded successfully.
            files = newFiles
            sampleRate = newSampleRate
            duration = newDuration
            for kind in StemKind.allCases {
                applyEffectState(effects[kind] ?? .zero, for: kind)
                applyOutputVolume(for: kind)
            }

            if !engine.isRunning {
                try engine.start()
            }
            scheduleAllAndPlay(fromFrame: 0)
            computePeaksAsync(for: bundle.drum)
            updateNowPlaying()
        } catch {
            print("StemPlayerEngine.load error: \(error)")
            files.removeAll()
            stemURLs.removeAll()
            currentTrack = nil
            duration = 0
            isPlaying = false
            updateNowPlaying()
        }
    }

    private func computePeaksAsync(for url: URL) {
        let target = url
        Task.detached(priority: .utility) { [weak self] in
            let computed = WaveformAnalyzer.peaks(for: target) ?? WaveformAnalyzer.placeholderPeaks()
            await MainActor.run { [weak self] in
                self?.peaks = computed
            }
        }
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func pause() {
        guard isPlaying else { return }
        // Snapshot the playhead BEFORE stopping — `stop()` clears it.
        let frame = currentFrame()
        pausedFrame = frame
        // Bump the generation so the cancelled segment's completion callback
        // (which AVAudioPlayerNode fires after stop) is treated as stale.
        playGeneration += 1
        for (_, pair) in nodes { pair.player.stop() }
        isPlaying = false
        displayTimer?.invalidate()
        updateAllOutputVolumes()
        updateNowPlaying()
        // Keep the engine itself running — it's cheap and resume becomes instant.
    }

    func resume() {
        guard currentTrack != nil, !isPlaying else { return }
        do {
            if !engine.isRunning { try engine.start() }
            // Defensive: bump generation + clear any lingering queue.
            playGeneration += 1
            for (_, pair) in nodes { pair.player.stop() }
            if let beats = activeLoopBeats {
                // Resume re-enters the loop at the same region start so
                // pause/play feels like a single hold-and-release.
                enableLoop(beats: beats, bpm: loopBPM, anchorFrame: loopStartFrame)
            } else {
                scheduleAllAndPlay(fromFrame: pausedFrame)
            }
        } catch {
            print("StemPlayerEngine.resume error: \(error)")
        }
    }

    func seek(to seconds: Double) {
        guard currentTrack != nil else { return }
        // Seeking exits the loop — the user is asking for free playback at a
        // new position. Without this, scheduleAllAndPlay below would clash
        // with the looping buffers.
        if isLooping {
            activeLoopBeats = nil
            loopFrameCount = 0
            loopBuffers.removeAll()
        }
        let target = max(0, min(seconds, duration))
        let targetFrame = AVAudioFramePosition(target * sampleRate)
        pausedFrame = targetFrame
        elapsed = target
        let wasPlaying = isPlaying
        playGeneration += 1
        for (_, pair) in nodes { pair.player.stop() }
        if wasPlaying {
            scheduleAllAndPlay(fromFrame: targetFrame)
        } else {
            updateNowPlaying()
        }
    }

    // MARK: – Setup

    private func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback keeps audio going when the screen locks and when the
            // app is backgrounded (paired with `UIBackgroundModes: audio`).
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("AVAudioSession config failed: \(error)")
        }
    }

    // MARK: – Remote / lock-screen controls

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.resume()
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.pause()
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }

        cc.skipForwardCommand.preferredIntervals = [15]
        cc.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.seek(to: self.elapsed + 15)
            return .success
        }
        cc.skipBackwardCommand.preferredIntervals = [15]
        cc.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.seek(to: max(0, self.elapsed - 15))
            return .success
        }

        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let e = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            self.seek(to: e.positionTime)
            return .success
        }
    }

    /// Pushes the current track + transport state to the lock screen,
    /// Control Center, and any connected accessories (AirPods, CarPlay).
    private func updateNowPlaying() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artist
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: – Interruptions (phone calls, Siri, other audio apps)

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
            // Another app or a call is taking the audio session — pause so
            // the user resumes from the right spot afterwards.
            if isPlaying { pause() }
        case .ended:
            // If iOS suggests we should resume (e.g. call ended quickly),
            // do — otherwise leave it paused for the user to tap play.
            if let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
                if opts.contains(.shouldResume) {
                    resume()
                }
            }
        @unknown default:
            break
        }
    }

    private func installNodes() {
        for kind in StemKind.allCases {
            let player = AVAudioPlayerNode()

            // TimePitch sits first so the colour effects (distortion / delay /
            // reverb) operate on the time-stretched signal — that way reverb
            // tails follow the BPM when the user slows the track down.
            let timePitch = AVAudioUnitTimePitch()
            timePitch.rate = 1.0
            timePitch.pitch = 0

            let distortion = AVAudioUnitDistortion()
            distortion.loadFactoryPreset(.multiDistortedSquared)
            distortion.wetDryMix = 0
            distortion.preGain = 0

            let delay = AVAudioUnitDelay()
            delay.wetDryMix = 0
            delay.feedback = 0
            delay.lowPassCutoff = 15_000

            let reverb = AVAudioUnitReverb()
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = 0

            let mixer  = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(timePitch)
            engine.attach(distortion)
            engine.attach(delay)
            engine.attach(reverb)
            engine.attach(mixer)
            engine.connect(player, to: timePitch, format: nil)
            engine.connect(timePitch, to: distortion, format: nil)
            engine.connect(distortion, to: delay, format: nil)
            engine.connect(delay, to: reverb, format: nil)
            engine.connect(reverb, to: mixer, format: nil)
            engine.connect(mixer, to: engine.mainMixerNode, format: nil)
            nodes[kind] = StemNodeChain(
                player: player,
                timePitch: timePitch,
                distortion: distortion,
                delay: delay,
                reverb: reverb,
                mixer: mixer
            )
            applyOutputVolume(for: kind)
        }
        engine.prepare()
    }

    // MARK: – Scheduling

    /// Schedules every stem from the same start frame, using a single shared
    /// future host time so they all fire on the *same* sample.
    private func scheduleAllAndPlay(fromFrame frame: AVAudioFramePosition) {
        playGeneration += 1
        let gen = playGeneration

        let when = AVAudioTime(
            hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05)
        )

        for kind in StemKind.allCases {
            guard let file = files[kind], let pair = nodes[kind] else { continue }
            let remaining = AVAudioFrameCount(max(0, file.length - frame))
            if remaining == 0 { continue }
            pair.player.scheduleSegment(
                file,
                startingFrame: frame,
                frameCount: remaining,
                at: when,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleStemFinished(kind, generation: gen)
                }
            }
            pair.player.play(at: when)
        }
        startSampleTime = frame
        isPlaying = true
        startDisplayLoop()
        updateNowPlaying()
    }

    private func handleStemFinished(_ kind: StemKind, generation: Int) {
        // Stale callback from a cancelled `.stop()` — ignore it. Without this
        // guard, pause() fires the completion for the cancelled segment and
        // we mistake it for "track ended", resetting the playhead to 0.
        guard generation == playGeneration else { return }
        // Belt-and-braces: `.loops` shouldn't fire end-of-buffer, but
        // disableLoop's `stop()` will. The generation bump above already
        // catches that, but a second guard is cheap.
        guard !isLooping else { return }
        guard kind == .vox else { return }
        stopAll()
        elapsed = duration
        pausedFrame = 0
        updateNowPlaying()
    }

    private func stopAll() {
        for (_, pair) in nodes { pair.player.stop() }
        isPlaying = false
        displayTimer?.invalidate()
        updateAllOutputVolumes()
    }

    // MARK: – Position tracking

    private func currentFrame() -> AVAudioFramePosition {
        guard let pair = nodes[.vox],
              let nodeTime = pair.player.lastRenderTime,
              let playerTime = pair.player.playerTime(forNodeTime: nodeTime)
        else { return pausedFrame }
        if isLooping, loopFrameCount > 0 {
            // Player's sampleTime keeps incrementing past the loop boundary
            // (the buffer wraps). Fold it back into the region so `elapsed`
            // pulses around the loop instead of running off the end of the
            // file.
            let offset = Int64(playerTime.sampleTime) % Int64(loopFrameCount)
            return loopStartFrame + AVAudioFramePosition(offset)
        }
        return startSampleTime + playerTime.sampleTime
    }

    private func startDisplayLoop() {
        displayTimer?.invalidate()
        var ticksSinceNowPlayingPush = 0
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1/30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let f = self.currentFrame()
                self.elapsed = max(0, Double(f) / self.sampleRate)
                self.updateTremoloVolumes()
                // Refresh Now Playing ~once a second so the lock-screen
                // scrubber stays accurate without thrashing the API.
                ticksSinceNowPlayingPush += 1
                if ticksSinceNowPlayingPush >= 30 {
                    ticksSinceNowPlayingPush = 0
                    self.updateNowPlaying()
                }
            }
        }
        if let t = displayTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private static func defaultEffectStates() -> [StemKind: StemEffectState] {
        Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, StemEffectState.zero) })
    }

    private func recalculateDuration() {
        duration = files.values
            .map { Double($0.length) / $0.processingFormat.sampleRate }
            .max() ?? 0
    }

    private func applyEffectState(_ state: StemEffectState, for kind: StemKind) {
        guard let chain = nodes[kind] else { return }

        chain.distortion.wetDryMix = Float(state.distortion * 82)
        chain.distortion.preGain = Float(state.distortion * 18)

        chain.delay.wetDryMix = Float(state.delay * 58)
        chain.delay.delayTime = 0.08 + state.delay * 0.46
        chain.delay.feedback = Float(state.delay <= 0.001 ? 0 : 14 + state.delay * 48)

        chain.reverb.wetDryMix = Float(state.reverb * 66)
        applyOutputVolume(for: kind)
    }

    private func updateAllOutputVolumes() {
        for kind in StemKind.allCases {
            applyOutputVolume(for: kind)
        }
    }

    private func updateTremoloVolumes() {
        guard effects.values.contains(where: { $0.tremolo > 0.001 }) else { return }
        updateAllOutputVolumes()
    }

    private func applyOutputVolume(for kind: StemKind) {
        guard let chain = nodes[kind] else { return }
        guard !monitoringMuted.contains(kind) else {
            chain.mixer.outputVolume = 0
            return
        }
        let base = volumes[kind] ?? 0
        let state = effects[kind] ?? .zero
        let depth = max(0, min(1, state.tremolo))
        guard depth > 0.001 else {
            chain.mixer.outputVolume = Float(base)
            return
        }

        let rate = 3.5 + depth * 5.5
        let phase = Date.timeIntervalSinceReferenceDate * rate * 2 * Double.pi
        let lfo = (sin(phase) + 1) * 0.5
        let multiplier = 1 - (depth * 0.82 * lfo)
        chain.mixer.outputVolume = Float(max(0, base * multiplier))
    }
}
