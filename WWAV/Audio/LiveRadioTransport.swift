import Foundation
import AVFoundation
import Combine

// MARK: – Events flowing from broadcaster → listeners

struct LiveRadioMessage: Identifiable, Equatable {
    var id: UUID = .init()
    var sessionId: UUID
    var senderName: String
    var senderHandle: String
    var text: String
    var sentAt: Date = .init()
}

/// Every event type the broadcast bus can emit.
enum LiveRadioEvent {
    /// The host started broadcasting.
    case broadcastStarted(sessionId: UUID)
    /// The host stopped broadcasting.
    case broadcastStopped(sessionId: UUID)
    /// A raw PCM buffer captured from the host mic.
    case talkAudio(buffer: AVAudioPCMBuffer, sessionId: UUID)
    /// The host started playing a queued song.
    case songStarted(songId: UUID, stems: StemBundle, sessionId: UUID, hostClock: Date)
    /// ~1 Hz heartbeat so listeners who tune in mid-song can sync.
    case songPosition(songId: UUID, elapsed: Double, sessionId: UUID, hostClock: Date)
    /// The song finished (or was interrupted by the host).
    case songEnded(sessionId: UUID)
    /// A listener sent a message into the live broadcast.
    case listenerMessage(LiveRadioMessage)
}

// MARK: – Transport protocol

/// Defines the contract between a broadcaster and any number of listeners.
///
/// The in-process implementation (`InProcessLiveRadioTransport`) ties them
/// together on the same device via Combine. A future `RemoteLiveRadioTransport`
/// would replace the publish calls with WebSocket / HLS pushes and the
/// subscribe side with WebSocket / HLS receive, without changing any call sites.
@MainActor
protocol LiveRadioTransport: AnyObject {
    /// Combine publisher all subscribers observe.
    var events: AnyPublisher<LiveRadioEvent, Never> { get }

    func startBroadcast(sessionId: UUID)
    func stopBroadcast(sessionId: UUID)
    func sendTalkAudio(_ buffer: AVAudioPCMBuffer, sessionId: UUID)
    func sendSongStart(songId: UUID, stems: StemBundle, sessionId: UUID)
    func sendSongPosition(songId: UUID, elapsed: Double, sessionId: UUID)
    func sendSongEnd(sessionId: UUID)
    func sendListenerMessage(_ message: LiveRadioMessage)
}

// MARK: – In-process implementation

/// Single-device pub/sub bus. Both the host's broadcaster and any listener
/// objects share one instance injected via the SwiftUI environment.
///
/// TODO: Replace with `RemoteLiveRadioTransport` once a streaming server
/// (e.g. WebSocket relay or Agora/LiveKit room) is available. The broadcaster
/// and listener classes only depend on the `LiveRadioTransport` protocol,
/// so the swap is a one-line change at the injection site in WWAVApp.
@MainActor
final class InProcessLiveRadioTransport: LiveRadioTransport, ObservableObject {

    // Backing subject — all events flow through here.
    private let subject = PassthroughSubject<LiveRadioEvent, Never>()

    var events: AnyPublisher<LiveRadioEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    func startBroadcast(sessionId: UUID) {
        subject.send(.broadcastStarted(sessionId: sessionId))
    }

    func stopBroadcast(sessionId: UUID) {
        subject.send(.broadcastStopped(sessionId: sessionId))
    }

    func sendTalkAudio(_ buffer: AVAudioPCMBuffer, sessionId: UUID) {
        subject.send(.talkAudio(buffer: buffer, sessionId: sessionId))
    }

    func sendSongStart(songId: UUID, stems: StemBundle, sessionId: UUID) {
        subject.send(.songStarted(songId: songId, stems: stems, sessionId: sessionId, hostClock: Date()))
    }

    func sendSongPosition(songId: UUID, elapsed: Double, sessionId: UUID) {
        subject.send(.songPosition(songId: songId, elapsed: elapsed, sessionId: sessionId, hostClock: Date()))
    }

    func sendSongEnd(sessionId: UUID) {
        subject.send(.songEnded(sessionId: sessionId))
    }

    func sendListenerMessage(_ message: LiveRadioMessage) {
        subject.send(.listenerMessage(message))
    }
}
