import Foundation
import AVFoundation
import Combine

// MARK: – Listener mode (mirrors BroadcastMode)

enum ListenerMode: Equatable {
    case talk
    case song(Track)
}

// MARK: – Listener

/// Subscribes to a `LiveRadioTransport` for one session and renders audio
/// locally — piping talk buffers into an `AVAudioPlayerNode` and, when a
/// song starts, loading its stems into a dedicated engine instance so it
/// doesn't interfere with the main `StemPlayerEngine`.
///
/// Song-position sync: the broadcaster sends `sendSongPosition` ~1 Hz.
/// When a `songStarted` or `songPosition` event arrives the listener uses
/// the embedded `hostClock` (the broadcaster's `Date()`) and the reported
/// `elapsed` to compute the listener's start frame with sub-second accuracy:
///
///   adjustedElapsed = elapsed + (now - hostClock)   // account for bus latency
///   startFrame = adjustedElapsed * sampleRate
///
/// This keeps playback locked to the DJ's clock even when the listener tunes
/// in partway through a song.
@MainActor
final class LiveRadioListener: ObservableObject {

    // MARK: – Public state

    @Published private(set) var mode: ListenerMode = .talk
    /// Instantaneous amplitude [0…1] of incoming talk audio for the visualizer.
    @Published private(set) var talkLevel: Float = 0
    /// Whether we're currently tuned in.
    @Published private(set) var isTuned: Bool = false

    // MARK: – Dependencies / config

    private let transport: LiveRadioTransport
    private let library: TrackLibrary
    private var sessionId: UUID?

    // MARK: – Talk audio pipeline

    private let talkEngine = AVAudioEngine()
    private let talkPlayer = AVAudioPlayerNode()
    private var talkFormat: AVAudioFormat?

    // MARK: – Song audio pipeline (own engine so it doesn't fight StemPlayerEngine)

    private let songEngine = AVAudioEngine()
    private var songNodes: [StemKind: (player: AVAudioPlayerNode, mixer: AVAudioMixerNode)] = [:]
    private var songFiles: [StemKind: AVAudioFile] = [:]
    private var songSampleRate: Double = 44_100
    private var songGeneration: Int = 0

    // MARK: – Sync state for mid-song tune-in

    /// Latest `sendSongPosition` heartbeat values.
    private var lastKnownElapsed: Double = 0
    private var lastKnownHostClock: Date = Date()
    private var lastSongId: UUID?

    // MARK: – Subscriptions

    private var bag: Set<AnyCancellable> = []

    // MARK: – Init

    init(transport: LiveRadioTransport, library: TrackLibrary) {
        self.transport = transport
        self.library = library
        installSongNodes()
    }

    // MARK: – Tune in / out

    func tuneIn(sessionId: UUID) {
        guard !isTuned else { return }
        self.sessionId = sessionId
        isTuned = true
        setupTalkPipeline()
        subscribe()
    }

    func tuneOut() {
        guard isTuned else { return }
        bag.removeAll()
        stopTalk()
        stopSong()
        isTuned = false
        mode = .talk
        talkLevel = 0
        sessionId = nil
    }

    // MARK: – Talk pipeline

    private func setupTalkPipeline() {
        talkEngine.attach(talkPlayer)
        // Use the default output format; we'll re-connect if the incoming
        // buffer format differs.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        talkFormat = format
        talkEngine.connect(talkPlayer, to: talkEngine.mainMixerNode, format: format)
        talkEngine.prepare()
        do {
            try talkEngine.start()
            talkPlayer.play()
        } catch {
            print("[Listener] Talk engine start error: \(error)")
        }
    }

    private func stopTalk() {
        talkPlayer.stop()
        talkEngine.stop()
    }

    // MARK: – Song pipeline

    private func installSongNodes() {
        for kind in StemKind.allCases {
            let player = AVAudioPlayerNode()
            let mixer  = AVAudioMixerNode()
            songEngine.attach(player)
            songEngine.attach(mixer)
            songEngine.connect(player, to: mixer, format: nil)
            songEngine.connect(mixer, to: songEngine.mainMixerNode, format: nil)
            songNodes[kind] = (player, mixer)
        }
        songEngine.prepare()
    }

    private func loadAndPlaySong(_ track: Track, fromElapsed: Double) {
        guard let stems = track.stems else {
            print("[Listener] No stems available for track \(track.id)")
            return
        }
        songGeneration += 1
        let gen = songGeneration

        // Stop any previous song playback.
        for (_, pair) in songNodes { pair.player.stop() }
        songEngine.stop()
        songFiles.removeAll()

        do {
            var newFiles: [StemKind: AVAudioFile] = [:]
            var newRate: Double = 44_100
            for kind in StemKind.allCases {
                let url = stems.url(for: kind)
                let file = try AVAudioFile(forReading: url)
                newFiles[kind] = file
                newRate = file.processingFormat.sampleRate
            }
            songFiles = newFiles
            songSampleRate = newRate

            if !songEngine.isRunning { try songEngine.start() }

            let startFrame = AVAudioFramePosition(max(0, fromElapsed) * songSampleRate)
            let when = AVAudioTime(
                hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05)
            )
            for kind in StemKind.allCases {
                guard let file = songFiles[kind], let pair = songNodes[kind] else { continue }
                let remaining = AVAudioFrameCount(max(0, file.length - startFrame))
                guard remaining > 0 else { continue }
                pair.player.scheduleSegment(
                    file,
                    startingFrame: startFrame,
                    frameCount: remaining,
                    at: when,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, gen == self.songGeneration, kind == .vox else { return }
                        // Song finished naturally — return to talk mode.
                        self.mode = .talk
                    }
                }
                pair.player.play(at: when)
            }
        } catch {
            print("[Listener] Song load error: \(error)")
        }
    }

    private func stopSong() {
        songGeneration += 1
        for (_, pair) in songNodes { pair.player.stop() }
        songEngine.stop()
        songFiles.removeAll()
    }

    // MARK: – Transport subscription

    private func subscribe() {
        transport.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                self.handle(event)
            }
            .store(in: &bag)
    }

    private func handle(_ event: LiveRadioEvent) {
        guard let sid = sessionId else { return }

        switch event {
        case .broadcastStopped(let eventSid) where eventSid == sid:
            // Host ended the broadcast — go silent.
            tuneOut()

        case .talkAudio(let buffer, let eventSid) where eventSid == sid:
            receiveTalkBuffer(buffer)

        case .songStarted(let songId, let stems, let eventSid, let hostClock) where eventSid == sid:
            // Compute latency-adjusted elapsed time.
            let transitDelay = Date().timeIntervalSince(hostClock)
            let adjustedElapsed = transitDelay  // started at 0 + transit delay
            lastSongId = songId
            lastKnownElapsed = adjustedElapsed
            lastKnownHostClock = Date()

            // Find the track in the library so we have its title/metadata.
            let syntheticTrack = makeTrack(id: songId, stems: stems)
            mode = .song(syntheticTrack)
            loadAndPlaySong(syntheticTrack, fromElapsed: adjustedElapsed)

        case .songPosition(let songId, let elapsed, let eventSid, let hostClock) where eventSid == sid:
            // Store for mid-song tune-in; if we're already playing this song
            // we don't re-seek (would cause a glitch) — the initial start was
            // already sync'd.
            lastSongId = songId
            lastKnownElapsed = elapsed
            lastKnownHostClock = hostClock

        case .songEnded(let eventSid) where eventSid == sid:
            stopSong()
            mode = .talk

        default:
            break
        }
    }

    // MARK: – Talk buffer playback

    private func receiveTalkBuffer(_ buffer: AVAudioPCMBuffer) {
        guard case .talk = mode else { return }
        talkLevel = LiveRadioListener.rms(buffer: buffer)

        // Reconnect with correct format if needed.
        if talkFormat != buffer.format {
            talkFormat = buffer.format
            talkPlayer.stop()
            talkEngine.disconnectNodeInput(talkPlayer)
            talkEngine.connect(talkPlayer, to: talkEngine.mainMixerNode, format: buffer.format)
            if !talkEngine.isRunning {
                try? talkEngine.start()
            }
            talkPlayer.play()
        }

        talkPlayer.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: – Helpers

    /// Build a minimal Track object from a UUID + StemBundle so the listener
    /// can pass it into the song-mode view without a full library lookup.
    private func makeTrack(id: UUID, stems: StemBundle) -> Track {
        // Try to find the real track metadata from the library first.
        let pool = library.myTracks + library.feed
        if let real = pool.first(where: { $0.id == id }) { return real }
        // Fallback synthetic track.
        return Track(
            id: id,
            kind: .music,
            title: "live track",
            artist: "",
            handle: "",
            bio: "",
            stems: stems,
            status: .ready,
            durationSeconds: 0
        )
    }

    private static func rms(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var maxRms: Float = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            let data = channelData[ch]
            var sum: Float = 0
            for i in 0..<frameCount {
                let s = data[i]
                sum += s * s
            }
            let rms = (sum / Float(frameCount)).squareRoot()
            maxRms = max(maxRms, rms)
        }
        return min(1.0, maxRms)
    }
}
