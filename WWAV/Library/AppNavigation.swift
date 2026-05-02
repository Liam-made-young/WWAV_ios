import Foundation
import Combine

struct PublicProfileRoute: Identifiable, Equatable {
    let authorUserId: Int?
    let handle: String
    let displayName: String
    let profilePicture: String?

    var id: String {
        if let authorUserId { return "user-\(authorUserId)" }
        return "handle-\(handle.normalizedHandle)"
    }

    var profilePictureURL: URL? {
        Track.resolveImageURL(profilePicture)
    }
}

/// Single source of truth for the active tab. Any view can call
/// `nav.openPost(track, in: library, with: player)` to:
///   1. start the right kind of playback for the post (stems for music,
///      AVPlayer for video; image/text just sit in the feed)
///   2. switch the root tab bar to the Play tab when applicable
@MainActor
final class AppNavigation: ObservableObject {
    @Published var active: AppTab = .play
    /// The currently focused post for the play screen — used for video
    /// posts that take over the play tab. `nil` for music (the StemPlayer
    /// engine owns the music post on the play screen).
    @Published var activePost: Track?
    /// Whether an image post is currently expanded into a fullscreen viewer.
    @Published var imageViewerPost: Track?
    /// Album currently expanded into its track-list view.
    @Published var albumViewerPost: Track?
    /// Upload kind requested by another surface, such as the feed composer.
    /// `UploadView` consumes and clears this when it becomes visible.
    @Published var requestedUploadKind: PostKind?
    /// Public author profile shown from feed/search/video surfaces.
    @Published var publicProfile: PublicProfileRoute?

    var hidesTabBar: Bool {
        active == .play && activePost?.kind == .video
    }

    func goToPlay() {
        active = .play
    }

    func compose(_ kind: PostKind) {
        requestedUploadKind = kind
        active = .plus
    }

    func openProfile(for track: Track) {
        publicProfile = PublicProfileRoute(
            authorUserId: track.authorUserId,
            handle: track.handle.normalizedHandle,
            displayName: track.artist,
            profilePicture: track.authorProfilePicture
        )
    }

    func closeActivePost() {
        activePost = nil
        imageViewerPost = nil
        albumViewerPost = nil
        active = .home
    }

    /// Loads a music track into the stem engine and switches to the play tab.
    func playTrack(_ track: Track,
                   in library: TrackLibrary,
                   with player: StemPlayerEngine) {
        openPost(track, in: library, with: player)
    }

    /// Routes any post to its correct destination. Music → stem player.
    /// Video → play tab with the video player. Image → fullscreen carousel
    /// modal. Album → track-list view. Text → no-op (the feed item is
    /// already the full post).
    func openPost(_ track: Track,
                  in library: TrackLibrary,
                  with player: StemPlayerEngine) {
        switch track.kind {
        case .music:
            active = .play
            activePost = track
            // Pause the previous track immediately and flip the engine
            // into "preparing" so the play view shows a loading overlay
            // for the entire duration of the stem download — instead of
            // letting the old song keep going while we silently fetch.
            player.beginPreparing(track)
            Task {
                let primed = await library.prepareForPlayback(track) { p in
                    player.updatePrepareProgress(p)
                }
                guard let primed else {
                    player.endPreparing()
                    return
                }
                // If the user already navigated to a different track while
                // we were downloading, abort: that newer track owns the
                // preparing state now.
                guard player.preparingTrack?.id == track.id else { return }
                player.load(primed)
                player.endPreparing()
                library.incrementPlays(of: primed.id)
            }
        case .video:
            active = .play
            activePost = track
            // Pause the stem engine if it was running so audio doesn't fight
            // the video soundtrack.
            if player.isPlaying { player.pause() }
            // If the user was mid-download for a music track, cancel the
            // loading state so the video player doesn't sit behind a stale
            // overlay.
            player.endPreparing()
            library.incrementPlays(of: track.id)
        case .image:
            imageViewerPost = track
            library.incrementPlays(of: track.id)
        case .album:
            albumViewerPost = track
            library.incrementPlays(of: track.id)
        case .text:
            // Text posts live entirely in the feed; tapping is a no-op.
            break
        }
    }
}

private extension String {
    var normalizedHandle: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }
}
