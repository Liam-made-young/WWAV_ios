import SwiftUI
import AVKit
import Combine

/// TikTok-style fullscreen video player. Shows the video filling the
/// available area, with a tap-to-play/pause overlay, a progress bar at the
/// bottom, and the post's title + caption pinned over the bottom-left in
/// the way the user expects from short-form video apps.
struct VideoPostPlayer: View {
    let post: Track
    @Environment(\.theme) private var theme
    @StateObject private var controller: VideoController

    init(post: Track) {
        self.post = post
        _controller = StateObject(wrappedValue: VideoController(url: post.videoURL))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()

            if let player = controller.player {
                VideoLayerView(player: player)
                    .ignoresSafeArea()
                    .onTapGesture {
                        controller.togglePlay()
                    }
            } else {
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

            // Big tap-feedback play icon when paused.
            if !controller.isPlaying && controller.player != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.6), radius: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 6) {
                Spacer()
                Text(post.artist)
                    .font(.wwav(15, weight: .medium))
                    .foregroundStyle(.white)
                Text(post.title)
                    .wwavTitle(size: 22)
                    .foregroundStyle(.white)
                if !post.displayText.isEmpty {
                    Text(post.displayText)
                        .font(.wwav(13, weight: .light))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(3)
                }

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 3)
                    GeometryReader { geo in
                        Capsule()
                            .fill(.white)
                            .frame(width: geo.size.width * controller.progress,
                                   height: 3)
                    }
                    .frame(height: 3)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            )
        }
        .onAppear { controller.play() }
        .onDisappear { controller.stop() }
    }
}

/// Plain UIView host for AVPlayerLayer so the video fills the view edge to
/// edge with `.resizeAspectFill`. AVKit's `VideoPlayer` defaults to a
/// letterboxed look that doesn't match the TikTok style we want.
private struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView()
        v.playerLayer.player = player
        // `resizeAspect` preserves the video's natural orientation and
        // aspect ratio: vertical clips fill the height, horizontal clips
        // fill the width with letterbox bars top/bottom. The previous
        // `.resizeAspectFill` cropped horizontal videos to a vertical
        // window, which is what the user was seeing.
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

@MainActor
final class VideoController: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var progress: Double = 0
    let player: AVPlayer?

    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?

    init(url: URL?) {
        guard let url else {
            self.player = nil
            return
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        // Loop the video TikTok-style.
        player.actionAtItemEnd = .none
        self.player = player

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
            let dur = item.duration.seconds
            guard dur.isFinite && dur > 0 else { return }
            let frac = min(1, max(0, time.seconds / dur))
            Task { @MainActor [weak self] in
                self?.progress = frac
            }
        }
    }

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

    deinit {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }
}
