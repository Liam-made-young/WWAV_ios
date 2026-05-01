import Foundation

enum StemKind: String, CaseIterable, Codable, Identifiable {
    case vox, bass, drum, synth
    var id: String { rawValue }
    /// Demucs canonical filenames are vocals/bass/drums/other.
    /// We map "synth" → "other".
    var demucsName: String {
        switch self {
        case .vox: return "vocals"
        case .bass: return "bass"
        case .drum: return "drums"
        case .synth: return "other"
        }
    }
    var label: String {
        switch self {
        case .vox: return "vox"
        case .bass: return "bass"
        case .drum: return "drum"
        case .synth: return "synth"
        }
    }
}

/// A 4-stem bundle. URLs are local file:// URLs the audio engine reads from.
/// Object keys point to where the same file lives in remote storage (S3 etc).
struct StemBundle: Codable, Equatable {
    var vox: URL
    var bass: URL
    var drum: URL
    var synth: URL

    func url(for kind: StemKind) -> URL {
        switch kind {
        case .vox: return vox
        case .bass: return bass
        case .drum: return drum
        case .synth: return synth
        }
    }
}

enum UploadPhase: String, Codable, Equatable {
    case compressing, saving, finalizing
    var label: String { rawValue }
}

enum TrackStatus: Codable, Equatable {
    case ready
    case separating(Double)   // 0...1
    case uploading(phase: UploadPhase, progress: Double)
    case failed(String)
    case sourceOnly
}

enum RemoteProcessingState: Equatable {
    case ready
    case processing(progress: Double)
    case failed(String)
    case unknown

    init(serverStatus: String) {
        switch serverStatus {
        case "ready":
            self = .ready
        case "processing":
            self = .processing(progress: 0.5)
        case "failed":
            self = .failed("server reported failed")
        default:
            self = .unknown
        }
    }

    var trackStatus: TrackStatus {
        switch self {
        case .ready:
            return .ready
        case .processing(let progress):
            return .separating(progress)
        case .failed(let message):
            return .failed(message)
        case .unknown:
            return .separating(0.0)
        }
    }

    var isRenderableRemoteRow: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// One of four post kinds. `music` is the original stem-player upload; the
/// other three are simple media posts that share Track's metadata fields
/// (title, bio, social counters) but skip stem separation.
enum PostKind: String, Codable, CaseIterable, Identifiable {
    case music
    case image
    case text
    case video
    var id: String { rawValue }

    var label: String {
        switch self {
        case .music: return "music"
        case .image: return "image"
        case .text:  return "text"
        case .video: return "video"
        }
    }
}

struct Track: Identifiable, Codable, Equatable {
    var id: UUID = .init()
    /// Which of the four post types this is. Defaults to `.music` so older
    /// persisted libraries (without this field) decode as music posts.
    var kind: PostKind = .music
    var title: String
    var artist: String
    var handle: String
    /// Server-side user id for the creator, when the API provides it.
    var authorUserId: Int?
    /// Raw profile-picture path/key/URL for the creator.
    var authorProfilePicture: String?
    var bio: String
    /// Local cache URL for the original mix (or nil for the bundled sample).
    var sourceURL: URL?
    /// Remote object key for the source file (e.g. S3 key). nil for the bundled sample.
    var sourceObjectKey: String?
    /// Server-side trackId (e.g. `track_172...abc123`). Set when the track is
    /// uploaded via `MiWwavStemService` so refresh-from-server can dedupe.
    var remoteTrackId: String?
    /// Server-side numeric primary key from `UserUpload`. Required by the
    /// `/api/social/like` endpoint, which keys likes by `userUploadId`.
    var userUploadId: Int?
    /// Server-side `PublishedTrack.id` for tracks discovered through the
    /// public browse feed. Used when a cross-user track no longer has a
    /// visible `UserUpload.id` on this client.
    var publishedTrackId: Int?
    /// Cover art URL (server-relative like `/api/images/123.jpg`, or a
    /// full URL). Resolved into a fetchable `URL` via `coverImageURL`.
    var coverArtUrl: String?
    /// Local cache URLs for the four stems, once available.
    var stems: StemBundle?
    /// Remote object keys for the four stems, mirroring `stems`.
    var stemObjectKeys: [String: String]?
    /// Image URLs for `.image` posts — a carousel of one or more images.
    /// Each entry follows the same conventions as `coverArtUrl` (full URL,
    /// server-relative `/api/images/…`, or bare key).
    var imageUrls: [String]?
    /// Local or remote URL for the video file. Set to the server proxy URL
    /// after the video is uploaded; falls back to a local file URL.
    var videoURL: URL?
    /// Duration of the compressed video in seconds, set after VideoOptimizer runs.
    var videoDuration: Double?
    /// Server-side `TextPost.id` for image/text/video posts. Set after the
    /// post is successfully created on the server. Used for metadata updates,
    /// deletes, and refresh deduplication.
    var remotePostId: Int?
    /// Optional text body for `.text` posts (also reusable as a long caption
    /// for image / video posts when present alongside `bio`).
    var textBody: String?
    var status: TrackStatus
    var durationSeconds: Double
    var createdAt: Date = .init()
    var plays: Int = 0
    var loves: Int = 0
    var reposts: Int = 0
    /// Whether the signed-in user has liked this track. Mirrored from
    /// `/api/social/is-liked` and toggled via `/api/social/like`.
    var liked: Bool = false
    /// Local-only repost state until the backend repost endpoint exists.
    var reposted: Bool = false

    /// Resolved cover-art URL ready for `AsyncImage`, or nil if no cover.
    var coverImageURL: URL? {
        Track.resolveImageURL(coverArtUrl)
    }

    var authorProfilePictureURL: URL? {
        Track.resolveImageURL(authorProfilePicture)
    }

    /// Resolved URLs for each carousel image on an image post.
    var resolvedImageURLs: [URL] {
        (imageUrls ?? []).compactMap { Track.resolveImageURL($0) }
    }

    /// Best-guess thumbnail across post types — cover for music/video,
    /// first carousel image for image posts, nil for text.
    var thumbnailURL: URL? {
        switch kind {
        case .music, .video: return coverImageURL
        case .image:         return resolvedImageURLs.first ?? coverImageURL
        case .text:          return nil
        }
    }

    /// Plain-text content for text posts (or caption fallback).
    var displayText: String {
        if let t = textBody, !t.isEmpty { return t }
        return bio
    }

    static func resolveImageURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        // Local file URLs come from the on-device cache (image-post images
        // and video-post covers stored via LocalDiskStorage). Pass them
        // through directly so AsyncImage can read them off disk.
        if raw.hasPrefix("file://") {
            return URL(string: raw)
        }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        if raw.hasPrefix("/") {
            // Bare absolute filesystem path (no scheme) — also a local file.
            if FileManager.default.fileExists(atPath: raw) {
                return URL(fileURLWithPath: raw)
            }
            return URL(string: "\(AppEnvironment.current.apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(raw)")
        }
        let filename = raw.split(separator: "/").last.map(String.init) ?? raw
        return URL(string: "\(AppEnvironment.current.apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/images/\(filename)")
    }

    // MARK: – Codable with backward compatibility
    //
    // Older library.json files persisted before the multi-post overhaul are
    // missing `kind`, `imageUrls`, `videoURL`, and `textBody`. Using
    // `decodeIfPresent` with sensible defaults keeps those rows decodable so
    // existing music tracks survive the upgrade.

    enum CodingKeys: String, CodingKey {
        case id, kind, title, artist, handle, authorUserId, authorProfilePicture, bio
        case sourceURL, sourceObjectKey, remoteTrackId, userUploadId, publishedTrackId
        case coverArtUrl, stems, stemObjectKeys
        case imageUrls, videoURL, videoDuration, remotePostId, textBody
        case status, durationSeconds, createdAt
        case plays, loves, reposts, liked, reposted
    }

    init(
        id: UUID = .init(),
        kind: PostKind = .music,
        title: String,
        artist: String,
        handle: String,
        authorUserId: Int? = nil,
        authorProfilePicture: String? = nil,
        bio: String,
        sourceURL: URL? = nil,
        sourceObjectKey: String? = nil,
        remoteTrackId: String? = nil,
        userUploadId: Int? = nil,
        publishedTrackId: Int? = nil,
        coverArtUrl: String? = nil,
        stems: StemBundle? = nil,
        stemObjectKeys: [String: String]? = nil,
        imageUrls: [String]? = nil,
        videoURL: URL? = nil,
        videoDuration: Double? = nil,
        remotePostId: Int? = nil,
        textBody: String? = nil,
        status: TrackStatus,
        durationSeconds: Double,
        createdAt: Date = .init(),
        plays: Int = 0,
        loves: Int = 0,
        reposts: Int = 0,
        liked: Bool = false,
        reposted: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.artist = artist
        self.handle = handle
        self.authorUserId = authorUserId
        self.authorProfilePicture = authorProfilePicture
        self.bio = bio
        self.sourceURL = sourceURL
        self.sourceObjectKey = sourceObjectKey
        self.remoteTrackId = remoteTrackId
        self.userUploadId = userUploadId
        self.publishedTrackId = publishedTrackId
        self.coverArtUrl = coverArtUrl
        self.stems = stems
        self.stemObjectKeys = stemObjectKeys
        self.imageUrls = imageUrls
        self.videoURL = videoURL
        self.videoDuration = videoDuration
        self.remotePostId = remotePostId
        self.textBody = textBody
        self.status = status
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.plays = plays
        self.loves = loves
        self.reposts = reposts
        self.liked = liked
        self.reposted = reposted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(UUID.self, forKey: .id)
        self.kind            = try c.decodeIfPresent(PostKind.self, forKey: .kind) ?? .music
        self.title           = try c.decode(String.self, forKey: .title)
        self.artist          = try c.decode(String.self, forKey: .artist)
        self.handle          = try c.decode(String.self, forKey: .handle)
        self.authorUserId    = try c.decodeIfPresent(Int.self, forKey: .authorUserId)
        self.authorProfilePicture = try c.decodeIfPresent(String.self, forKey: .authorProfilePicture)
        self.bio             = try c.decode(String.self, forKey: .bio)
        self.sourceURL       = try c.decodeIfPresent(URL.self, forKey: .sourceURL)
        self.sourceObjectKey = try c.decodeIfPresent(String.self, forKey: .sourceObjectKey)
        self.remoteTrackId   = try c.decodeIfPresent(String.self, forKey: .remoteTrackId)
        self.userUploadId    = try c.decodeIfPresent(Int.self, forKey: .userUploadId)
        self.publishedTrackId = try c.decodeIfPresent(Int.self, forKey: .publishedTrackId)
        self.coverArtUrl     = try c.decodeIfPresent(String.self, forKey: .coverArtUrl)
        self.stems           = try c.decodeIfPresent(StemBundle.self, forKey: .stems)
        self.stemObjectKeys  = try c.decodeIfPresent([String: String].self, forKey: .stemObjectKeys)
        self.imageUrls       = try c.decodeIfPresent([String].self, forKey: .imageUrls)
        self.videoURL        = try c.decodeIfPresent(URL.self, forKey: .videoURL)
        self.videoDuration   = try c.decodeIfPresent(Double.self, forKey: .videoDuration)
        self.remotePostId    = try c.decodeIfPresent(Int.self, forKey: .remotePostId)
        self.textBody        = try c.decodeIfPresent(String.self, forKey: .textBody)
        self.status          = try c.decode(TrackStatus.self, forKey: .status)
        self.durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        self.createdAt       = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.plays           = try c.decodeIfPresent(Int.self, forKey: .plays) ?? 0
        self.loves           = try c.decodeIfPresent(Int.self, forKey: .loves) ?? 0
        self.reposts         = try c.decodeIfPresent(Int.self, forKey: .reposts) ?? 0
        self.liked           = try c.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        self.reposted        = try c.decodeIfPresent(Bool.self, forKey: .reposted) ?? false
    }
}
