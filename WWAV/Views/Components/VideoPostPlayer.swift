import SwiftUI
import AVKit
import Combine

/// TikTok-style fullscreen video player with a glassy themed bottom panel,
/// tap-zone seek controls, chrome auto-fade, and a draggable scrubber.
struct VideoPostPlayer: View {
    let post: Track
    @Environment(\.theme) private var theme
    @StateObject private var controller: VideoController
    @AppStorage("video.muted") private var muted: Bool = false

    @State private var chromeVisible: Bool = true
    @State private var fadeTask: Task<Void, Never>?

    init(post: Track) {
        self.post = post
        _controller = StateObject(wrappedValue: VideoController(url: post.videoURL))
    }

    // MARK: – Chrome helpers

    private func scheduleFade() {
        fadeTask?.cancel()
        fadeTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.4)) { chromeVisible = false }
                }
            }
        }
    }

    private func revealChrome() {
        withAnimation(.easeOut(duration: 0.2)) { chromeVisible = true }
        scheduleFade()
    }

    // MARK: – Time formatting

    private func formatTime(_ s: Double) -> String {
        let total = Int(s.isFinite && s >= 0 ? s : 0)
        let m = total / 60
        let r = total % 60
        return String(format: "%d:%02d", m, r)
    }

    // MARK: – Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = controller.player {
                // 1. Full-bleed video layer
                VideoLayerView(player: player)
                    .ignoresSafeArea()

                // 2. Tap zones (three vertical thirds)
                tapZonesOverlay

                // 3. Big play icon when paused (no hit testing)
                if !controller.isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.6), radius: 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }

                // 4. Chrome (mute button + glassy panel)
                chromeOverlay

            } else {
                // Video unavailable error state
                VStack(spacing: 8) {
                    Spacer()
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
        }
        .onAppear {
            controller.play()
            controller.setMuted(muted)
            revealChrome()
        }
        .onDisappear {
            controller.stop()
            fadeTask?.cancel()
        }
        .onChange(of: muted) { newValue in
            controller.setMuted(newValue)
        }
    }

    // MARK: – Tap zones

    @ViewBuilder
    private var tapZonesOverlay: some View {
        HStack(spacing: 0) {
            // Left third: seek -10s
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if controller.duration > 0 {
                        controller.seek(by: -10)
                    }
                    revealChrome()
                }

            // Center third: toggle play
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    controller.togglePlay()
                    revealChrome()
                }

            // Right third: seek +10s
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if controller.duration > 0 {
                        controller.seek(by: +10)
                    }
                    revealChrome()
                }
        }
        .ignoresSafeArea()
    }

    // MARK: – Chrome overlay

    @ViewBuilder
    private var chromeOverlay: some View {
        ZStack(alignment: .bottom) {
            // Mute button – top-right
            VStack {
                HStack {
                    Spacer()
                    muteButton
                        .padding(.trailing, 16)
                        .padding(.top, 16)
                }
                Spacer()
            }

            // Glassy bottom panel
            glassyPanel
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
        .opacity(chromeVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: chromeVisible)
        .allowsHitTesting(chromeVisible)
    }

    // MARK: – Mute button

    @ViewBuilder
    private var muteButton: some View {
        Button {
            muted.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 36, height: 36)
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: – Glassy bottom panel

    private var displayedFraction: Double {
        controller.scrubFraction ?? controller.progress
    }

    private var displayedCurrentTime: Double {
        controller.scrubFraction.map { $0 * controller.duration } ?? controller.currentTime
    }

    @ViewBuilder
    private var glassyPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Artist
            Text(post.artist)
                .font(.wwav(15, weight: .light))
                .foregroundStyle(theme.muted)

            // Title
            Text(post.title)
                .wwavTitle(size: 22)
                .foregroundStyle(theme.ink)

            // Optional caption
            if !post.displayText.isEmpty {
                Text(post.displayText)
                    .font(.wwav(13, weight: .light))
                    .foregroundStyle(theme.ink.opacity(0.85))
                    .lineLimit(3)
            }

            // Time label
            HStack {
                Text("\(formatTime(displayedCurrentTime)) / \(formatTime(controller.duration))")
                    .font(.wwav(11, weight: .light))
                    .foregroundStyle(theme.muted)
                Spacer()
            }
            .padding(.top, 4)

            // Scrubber
            scrubber
                .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(
                    colors: [theme.sand.opacity(0.55), theme.sandDeep.opacity(0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(theme.clayDeep.opacity(0.4), lineWidth: 0.5)
                )
        )
    }

    // MARK: – Scrubber

    @ViewBuilder
    private var scrubber: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.muted.opacity(0.25))
                Capsule()
                    .fill(LinearGradient(
                        colors: [theme.accent, theme.clayDeep],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: geo.size.width * displayedFraction)
                Circle()
                    .fill(theme.accent)
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, geo.size.width * displayedFraction - 6))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = max(0, min(1, v.location.x / max(1, geo.size.width)))
                        controller.beginScrub(fraction: f)
                        fadeTask?.cancel()
                    }
                    .onEnded { v in
                        let f = max(0, min(1, v.location.x / max(1, geo.size.width)))
                        controller.endScrub(fraction: f)
                        revealChrome()
                    }
            )
        }
        .frame(height: 16)
    }
}

// MARK: – VideoLayerView

/// Plain UIView host for AVPlayerLayer so the video fills the view edge-to-edge
/// with `.resizeAspect`. AVKit's `VideoPlayer` defaults to a letterboxed look
/// that doesn't match the TikTok style we want.
private struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView()
        v.playerLayer.player = player
        // `.resizeAspect` preserves the video's natural orientation and aspect
        // ratio: vertical clips fill the height, horizontal clips fill the width
        // with letterbox bars top/bottom.
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

// MARK: – PlayerContainerView

private final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// MARK: – VideoController

@MainActor
final class VideoController: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published var scrubFraction: Double? = nil

    let player: AVPlayer?

    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?

    init(url: URL?) {
        guard let url else {
            self.player = nil
            return
        }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        // Loop the video TikTok-style.
        player.actionAtItemEnd = .none
        self.player = player

        // Load duration asynchronously from the asset.
        Task {
            let dur = (try? await asset.load(.duration).seconds) ?? 0
            self.duration = dur.isFinite && dur > 0 ? dur : 0
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let dur = item.duration.seconds
            guard dur.isFinite && dur > 0 else { return }
            let secs = time.seconds
            let frac = min(1, max(0, secs / dur))
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Update duration in case it wasn't ready on init.
                if self.duration <= 0 { self.duration = dur }
                // Only update currentTime/progress while not scrubbing.
                if self.scrubFraction == nil {
                    self.currentTime = secs.isFinite ? secs : 0
                    self.progress = frac
                }
            }
        }
    }

    // MARK: – Playback

    func play() {
        player?.play()
        isPlaying = true
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        player?.pause()
        isPlaying = false
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    // MARK: – Seeking

    func seek(by delta: TimeInterval) {
        guard duration > 0 else { return }
        let target = max(0, min(duration, currentTime + delta))
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
        progress = duration > 0 ? target / duration : 0
    }

    // MARK: – Scrubbing

    func beginScrub(fraction: Double) {
        scrubFraction = max(0, min(1, fraction))
    }

    func endScrub(fraction: Double) {
        guard duration > 0 else { scrubFraction = nil; return }
        let f = max(0, min(1, fraction))
        let target = duration * f
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
        progress = f
        scrubFraction = nil
    }

    // MARK: – Audio

    func setMuted(_ flag: Bool) {
        player?.isMuted = flag
    }

    // MARK: – Lifecycle

    deinit {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }
}
