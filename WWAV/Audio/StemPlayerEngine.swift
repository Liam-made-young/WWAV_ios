import Foundation
import AVFoundation
import Combine
import MediaPlayer

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

    // MARK: – Engine guts
    private let engine = AVAudioEngine()
    private var nodes: [StemKind: (player: AVAudioPlayerNode, mixer: AVAudioMixerNode)] = [:]
    private var files: [StemKind: AVAudioFile] = [:]
    private var startSampleTime: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private var pausedFrame: AVAudioFramePosition = 0
    private var displayTimer: Timer?
    /// Bumped every time we cancel or replace the current schedule. Lets us
    /// ignore stale `dataPlayedBack` completion callbacks that AVAudioPlayerNode
    /// still fires after a `.stop()` — without this, pausing fires the "track
    /// ended" handler for the cancelled buffer and resets pausedFrame to 0.
    private var playGeneration: Int = 0

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
        nodes[kind]?.mixer.outputVolume = Float(v)
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
                newSampleRate = file.processingFormat.sampleRate
                newDuration = max(newDuration, Double(file.length) / newSampleRate)
            }
            // Commit only after every stem decoded successfully.
            files = newFiles
            sampleRate = newSampleRate
            duration = newDuration
            for kind in StemKind.allCases {
                guard let pair = nodes[kind] else { continue }
                pair.mixer.outputVolume = Float(volumes[kind] ?? 0.8)
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
            scheduleAllAndPlay(fromFrame: pausedFrame)
        } catch {
            print("StemPlayerEngine.resume error: \(error)")
        }
    }

    func seek(to seconds: Double) {
        guard currentTrack != nil else { return }
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
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
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
            let mixer  = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(mixer)
            engine.connect(player, to: mixer, format: nil)
            engine.connect(mixer, to: engine.mainMixerNode, format: nil)
            mixer.outputVolume = Float(volumes[kind] ?? 0.8)
            nodes[kind] = (player, mixer)
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
    }

    // MARK: – Position tracking

    private func currentFrame() -> AVAudioFramePosition {
        guard let pair = nodes[.vox],
              let nodeTime = pair.player.lastRenderTime,
              let playerTime = pair.player.playerTime(forNodeTime: nodeTime)
        else { return pausedFrame }
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
}
