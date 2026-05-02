import Foundation
import AVFoundation
import Combine

// MARK: – Broadcaster mode

enum BroadcastMode: Equatable {
    case talk
    case song(Track)
}

// MARK: – Broadcaster

/// Manages the host-side audio pipeline for a live radio session.
///
/// Responsibilities:
///   1. Configure `AVAudioSession` for `playAndRecord`.
///   2. Install an input tap on the mic and forward PCM buffers to the
///      `LiveRadioTransport` as talk audio.
///   3. When the DJ queues a song, switch to **song mode**: mute the mic tap,
///      emit `sendSongStart`, and broadcast `sendSongPosition` heartbeats at
///      ~1 Hz using a `Date()`-based clock (no additional AVAudioEngine needed).
///   4. Expose `@Published` state so the DJ Console view stays in sync.
@MainActor
final class LiveRadioBroadcaster: ObservableObject {

    // MARK: – Public state

    @Published private(set) var isLive: Bool = false
    @Published private(set) var mode: BroadcastMode = .talk
    /// Instantaneous RMS level [0…1] from the input tap, updated ~30 fps.
    @Published private(set) var talkLevel: Float = 0

    // MARK: – Dependencies

    private let transport: LiveRadioTransport

    // MARK: – Private state

    private var sessionId: UUID?
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var positionTimer: Timer?

    /// Song-mode clock: the `Date` when the current song started on the host.
    private var songStartDate: Date?
    private var currentSongId: UUID?
    private var currentSongDuration: Double = 0

    // MARK: – Init

    init(transport: LiveRadioTransport) {
        self.transport = transport
    }

    // MARK: – Go live / end live

    func goLive(sessionId: UUID) {
        guard !isLive else { return }
        self.sessionId = sessionId
        configureAudioSession()
        startMicTap()
        isLive = true
        mode = .talk
        transport.startBroadcast(sessionId: sessionId)
    }

    func endLive() {
        guard isLive, let sid = sessionId else { return }
        stopPositionTimer()
        stopMicTap()
        restoreAudioSession()
        isLive = false
        mode = .talk
        talkLevel = 0
        sessionId = nil
        songStartDate = nil
        currentSongId = nil
        transport.stopBroadcast(sessionId: sid)
    }

    // MARK: – Song mode

    /// Switch from talk → song. The mic tap is silenced (buffers are no longer
    /// forwarded) and position heartbeats begin immediately.
    func playSong(_ track: Track) {
        guard isLive, let sid = sessionId, let stems = track.stems else { return }
        stopPositionTimer()
        currentSongId = track.id
        currentSongDuration = track.durationSeconds
        songStartDate = Date()
        mode = .song(track)
        transport.sendSongStart(songId: track.id, stems: stems, sessionId: sid)
        startPositionTimer(songId: track.id)
    }

    /// Return from song → talk mode (DJ presses "back to live").
    func returnToTalk() {
        guard isLive, let sid = sessionId else { return }
        stopPositionTimer()
        mode = .talk
        songStartDate = nil
        currentSongId = nil
        transport.sendSongEnd(sessionId: sid)
    }

    // MARK: – Audio session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // playAndRecord lets us capture mic AND play audio simultaneously.
            // defaultToSpeaker keeps the DJ monitor audible; allowBluetooth
            // allows AirPods; mixWithOthers avoids killing background audio.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
            )
            try session.setActive(true)
        } catch {
            print("[Broadcaster] AVAudioSession config error: \(error)")
        }
    }

    private func restoreAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Restore to simple playback for the rest of the app.
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("[Broadcaster] AVAudioSession restore error: \(error)")
        }
    }

    // MARK: – Mic tap

    private func startMicTap() {
        guard !tapInstalled else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            print("[Broadcaster] AVAudioEngine start error: \(error)")
            return
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isLive else { return }
                // Compute RMS for the VU meter (always, regardless of mode).
                self.talkLevel = Self.rms(buffer: buffer)
                // Only forward audio to the transport in talk mode.
                if case .talk = self.mode, let sid = self.sessionId {
                    self.transport.sendTalkAudio(buffer, sessionId: sid)
                }
            }
        }
        tapInstalled = true
    }

    private func stopMicTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapInstalled = false
    }

    // MARK: – Position heartbeat

    private func startPositionTimer(songId: UUID) {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let sid = self.sessionId, let startDate = self.songStartDate else { return }
                let elapsed = Date().timeIntervalSince(startDate)
                if elapsed >= self.currentSongDuration {
                    // Song ended naturally — return to talk.
                    self.returnToTalk()
                } else {
                    self.transport.sendSongPosition(songId: songId, elapsed: elapsed, sessionId: sid)
                }
            }
        }
        if let t = positionTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    // MARK: – RMS helper

    /// Compute peak RMS across all channels in the buffer, returning [0…1].
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
        // Clamp to [0,1] — bursts can briefly exceed 1.0 on hot mics.
        return min(1.0, maxRms)
    }
}
