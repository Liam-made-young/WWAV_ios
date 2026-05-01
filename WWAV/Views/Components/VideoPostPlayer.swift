import SwiftUI
import AVKit
import Combine

struct VideoPostPlayer: View {
    let post: Track
    @Environment(\.theme) private var theme
    @StateObject private var controller: VideoController

    init(post: Track) {
        self.post = post
        _controller = StateObject(wrappedValue: VideoController(url: post.videoURL))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = controller.player {
                VideoLayerView(player: player)
                    .ignoresSafeArea()
            } else {
                unavailableView
            }

            if controller.player != nil {
                tapZones
                centerPlayOverlay
                bufferingOverlay
                seekFeedbackOverlay
                if controller.isScrubbing {
                    scrubTimecode.transition(.opacity)
                }
                if controller.chromeVisible {
                    chrome.transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controller.chromeVisible)
        .animation(.spring(response: 0.30, dampingFraction: 0.78), value: controller.isPlaying)
        .animation(.easeInOut(duration: 0.20), value: controller.isBuffering)
        .animation(.easeInOut(duration: 0.18), value: controller.seekFeedback)
        .animation(.easeInOut(duration: 0.18), value: controller.isScrubbing)
        .onAppear { controller.play() }
        .onDisappear { controller.stop() }
    }

    // MARK: – Unavailable state

    private var unavailableView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "video.slash")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.white.opacity(0.55))
            Text("video unavailable")
                .wwavTitle(size: 22)
                .foregroundStyle(.white)
            Text("the source file could not be loaded")
                .font(.wwav(12, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: – Three tap zones (-10s / play-pause / +10s)

    private var tapZones: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        controller.seek(by: -10)
                        controller.flashSeek(.backward)
                        controller.revealChrome()
                    }
                    .frame(width: geo.size.width / 3)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        controller.togglePlay()
                        controller.revealChrome()
                    }
                    .frame(width: geo.size.width / 3)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        controller.seek(by: 10)
                        controller.flashSeek(.forward)
                        controller.revealChrome()
                    }
                    .frame(width: geo.size.width / 3)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: – Large center play indicator (when paused, not buffering)

    @ViewBuilder
    private var centerPlayOverlay: some View {
        if !controller.isPlaying && !controller.isBuffering {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 92, height: 92)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 4)
                Image(systemName: "play.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(x: 3) // visual centering for the play glyph
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }

    // MARK: – Buffering spinner

    @ViewBuilder
    private var bufferingOverlay: some View {
        if controller.isBuffering {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.4)
                .allowsHitTesting(false)
        }
    }

    // MARK: – Seek feedback (±10s bubble shown briefly)

    @ViewBuilder
    private var seekFeedbackOverlay: some View {
        if let direction = controller.seekFeedback {
            GeometryReader { geo in
                seekBubble(direction: direction)
                    .position(
                        x: direction == .backward ? geo.size.width * 0.22 : geo.size.width * 0.78,
                        y: geo.size.height * 0.5
                    )
            }
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private func seekBubble(direction: SeekDirection) -> some View {
        VStack(spacing: 4) {
            Image(systemName: direction == .backward ? "gobackward.10" : "goforward.10")
                .font(.system(size: 30, weight: .semibold))
            Text(direction == .backward ? "−10s" : "+10s")
                .font(.wwav(12, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(.ultraThinMaterial, in: Circle())
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
    }

    // MARK: – Floating timecode while scrubbing

    private var scrubTimecode: some View {
        VStack {
            Spacer().frame(height: 90)
            Text(formatTime(controller.scrubFraction * controller.duration))
                .font(.wwav(34, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.4), radius: 14, y: 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: – Glassy chrome overlay

    private var chrome: some View {
        VStack {
            Spacer()
            bottomPanel
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var bottomPanel: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.78)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 260)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(post.artist)
                            .font(.wwav(14, weight: .medium))
                            .foregroundStyle(.white)
                        Text(post.title)
                            .wwavTitle(size: 20)
                            .foregroundStyle(.white)
                        if !post.displayText.isEmpty {
                            Text(post.displayText)
                                .font(.wwav(12, weight: .light))
                                .foregroundStyle(.white.opacity(0.80))
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    muteButton
                }

                scrubberRow
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 36)
            .padding(.top, 12)
        }
        .background(.ultraThinMaterial.opacity(0.32), in: Rectangle())
    }

    // MARK: – Mute toggle

    private var muteButton: some View {
        Button {
            controller.toggleMute()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 38, height: 38)
                Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isMuted ? "Unmute" : "Mute")
    }

    // MARK: – Scrubber row (timecodes + bar)

    private var scrubberRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            scrubber
            HStack {
                Text(formatTime(displayedTime))
                    .font(.wwav(11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                Text(formatTime(controller.duration))
                    .font(.wwav(11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
    }

    private var displayedTime: Double {
        controller.isScrubbing
            ? controller.scrubFraction * controller.duration
            : controller.currentTime
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let fraction = controller.isScrubbing ? controller.scrubFraction : controller.progress
            let progressX = max(0, geo.size.width * fraction)
            let barHeight: CGFloat = controller.isScrubbing ? 5 : 3
            let thumbDiameter: CGFloat = controller.isScrubbing ? 14 : 10

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: barHeight)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white, .white.opacity(0.78)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: progressX, height: barHeight)

                Circle()
                    .fill(.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    .offset(x: progressX - thumbDiameter / 2)
            }
            .frame(height: 14)
            .contentShape(Rectangle().inset(by: -10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        controller.beginScrub()
                        let newFraction = max(0, min(1, v.location.x / geo.size.width))
                        controller.scrubFraction = newFraction
                        controller.revealChrome()
                    }
                    .onEnded { v in
                        let newFraction = max(0, min(1, v.location.x / geo.size.width))
                        controller.endScrub(fraction: newFraction)
                    }
            )
        }
        .frame(height: 14)
    }

    // MARK: – Time formatting

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: – Seek direction

enum SeekDirection: Equatable {
    case forward, backward
}

// MARK: – VideoLayerView / PlayerContainerView

/// Plain UIView host for AVPlayerLayer so the video fills the view edge to
/// edge with `.resizeAspect`. AVKit's `VideoPlayer` defaults to a
/// letterboxed look that doesn't match the TikTok style we want.
private struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

private final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// MARK: – VideoController

@MainActor
final class VideoController: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var progress: Double = 0
    @Published var scrubFraction: Double = 0
    @Published private(set) var chromeVisible: Bool = true
    @Published private(set) var isMuted: Bool
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBuffering: Bool = false
    @Published private(set) var isScrubbing: Bool = false
    @Published private(set) var seekFeedback: SeekDirection? = nil

    let player: AVPlayer?

    private static let mutedKey = "video.muted"

    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var fadeTask: Task<Void, Never>?
    private var seekFeedbackTask: Task<Void, Never>?
    private var timeControlObservation: NSKeyValueObservation?

    init(url: URL?) {
        let initialMuted = UserDefaults.standard.bool(forKey: Self.mutedKey)
        self.isMuted = initialMuted

        guard let url else {
            self.player = nil
            return
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        player.isMuted = initialMuted
        self.player = player

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        let interval = CMTime(seconds: 0.05, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let dur = item.duration.seconds
                guard dur.isFinite && dur > 0 else { return }
                self.duration = dur
                self.currentTime = time.seconds
                let frac = min(1, max(0, time.seconds / dur))
                self.progress = frac
                self.scrubFraction = frac
            }
        }

        timeControlObservation = player.observe(
            \.timeControlStatus, options: [.new, .initial]
        ) { [weak self] p, _ in
            let waiting = (p.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            Task { @MainActor [weak self] in
                self?.isBuffering = waiting
            }
        }

        scheduleFade()
    }

    // MARK: – Playback

    func play() {
        player?.play()
        isPlaying = true
        scheduleFade()
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            revealChrome()
        } else {
            player.play()
            isPlaying = true
            scheduleFade()
        }
    }

    func stop() {
        player?.pause()
        isPlaying = false
        fadeTask?.cancel()
        seekFeedbackTask?.cancel()
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        timeControlObservation?.invalidate()
        timeControlObservation = nil
    }

    // MARK: – Seek

    func seek(by seconds: Double) {
        guard let player, duration > 0 else { return }
        let current = player.currentTime().seconds
        let target = max(0, min(duration, current + seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func flashSeek(_ direction: SeekDirection) {
        seekFeedback = direction
        seekFeedbackTask?.cancel()
        seekFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.seekFeedback = nil
        }
    }

    // MARK: – Scrub

    func beginScrub() {
        if !isScrubbing {
            isScrubbing = true
            player?.pause()
        }
    }

    func endScrub(fraction: Double) {
        guard let player, duration > 0 else {
            isScrubbing = false
            return
        }
        let target = CMTime(seconds: fraction * duration, preferredTimescale: 600)
        player.seek(to: target) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isScrubbing = false
                if self.isPlaying { self.player?.play() }
            }
        }
    }

    // MARK: – Mute

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
        UserDefaults.standard.set(isMuted, forKey: Self.mutedKey)
    }

    // MARK: – Chrome fade

    func revealChrome() {
        chromeVisible = true
        scheduleFade()
    }

    private func scheduleFade() {
        fadeTask?.cancel()
        guard isPlaying else { return }
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.chromeVisible = false
        }
    }

    deinit {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeControlObservation?.invalidate()
    }
}
