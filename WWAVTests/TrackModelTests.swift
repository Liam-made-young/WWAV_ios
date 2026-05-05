import XCTest
@testable import WWAV

final class TrackModelTests: XCTestCase {
    override func tearDown() {
        AppEnvironment.current = .production
        API.environment = .production
        super.tearDown()
    }

    func testImageURLResolutionUsesConfiguredEnvironment() {
        API.environment = AppEnvironment(apiBaseURL: URL(string: "https://example.test")!)

        XCTAssertEqual(
            Track.resolveImageURL("/api/images/cover.jpg")?.absoluteString,
            "https://example.test/api/images/cover.jpg"
        )
        XCTAssertEqual(
            Track.resolveImageURL("profile_pictures/avatar.jpg")?.absoluteString,
            "https://example.test/api/images/avatar.jpg"
        )
    }

    func testPersistedLocalObjectKeyExtractsStableStorageKey() {
        let raw = "file:///Users/liam/Library/Developer/CoreSimulator/Devices/DEVICE/data/Containers/Data/Application/OLD/Library/Application%20Support/wwav/objects/uploads/track-1/image%201.jpg"

        XCTAssertEqual(
            TrackLibrary.persistedLocalObjectKey(from: raw),
            "uploads/track-1/image 1.jpg"
        )
    }

    func testLocalDiskStorageReportsCurrentCachedURL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wwav-storage-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalDiskStorage(root: root)
        let key = "uploads/track-1/cover.jpg"

        let saved = try await storage.put(Data([1, 2, 3]), key: key, contentType: "image/jpeg")

        XCTAssertEqual(storage.cachedURLIfPresent(for: key), saved)
        XCTAssertNil(storage.cachedURLIfPresent(for: "uploads/missing.jpg"))
    }

    func testRemoteUploadDecodesBackendShapeVariants() throws {
        let json = """
        {
          "id": 42,
          "trackId": "track_abc",
          "originalName": "song.wav",
          "status": "ready",
          "track": { "cover_art_url": "/api/images/cover.jpg" },
          "User": { "id": 2, "username": "liam_made_young", "profilePicture": "/api/images/avatar.jpg" },
          "created_at": "2026-05-01T12:34:56.000Z"
        }
        """.data(using: .utf8)!

        let upload = try JSONDecoder().decode(WWAVRemoteUpload.self, from: json)

        XCTAssertEqual(upload.id, 42)
        XCTAssertNil(upload.publishedTrackId)
        XCTAssertEqual(upload.trackId, "track_abc")
        XCTAssertEqual(upload.coverArtUrl, "/api/images/cover.jpg")
        XCTAssertEqual(upload.author?.id, 2)
        XCTAssertEqual(upload.author?.displayName, "liam_made_young")
        XCTAssertNotNil(upload.parsedCreatedAt)
    }

    func testBrowseUploadDecodesPublishedAndUploadIds() throws {
        let json = """
        {
          "id": 77,
          "itemType": "single",
          "trackId": "track_browse",
          "title": "browse song",
          "userUploadId": 41,
          "uploaderId": 9,
          "uploader": { "username": "LMY_testing" },
          "playCount": 12
        }
        """.data(using: .utf8)!

        let upload = try JSONDecoder().decode(WWAVRemoteUpload.self, from: json)

        XCTAssertEqual(upload.id, 41)
        XCTAssertEqual(upload.publishedTrackId, 77)
        XCTAssertEqual(upload.originalName, "browse song")
        XCTAssertEqual(upload.status, "ready")
        XCTAssertEqual(upload.author?.id, 9)
        XCTAssertEqual(upload.author?.displayName, "LMY_testing")
        XCTAssertEqual(upload.plays, 12)
    }

    func testRemoteProcessingStateMapping() {
        XCTAssertEqual(RemoteProcessingState(serverStatus: "ready"), .ready)
        XCTAssertEqual(RemoteProcessingState(serverStatus: "processing"), .processing(progress: 0.5))
        XCTAssertEqual(RemoteProcessingState(serverStatus: "failed"), .failed("server reported failed"))
        XCTAssertEqual(RemoteProcessingState(serverStatus: "mystery"), .unknown)
    }

    func testRemotePostDecodesViewsAsPlays() throws {
        let json = """
        {
          "id": 7,
          "kind": "text",
          "title": "note",
          "content": "hello",
          "views": "123",
          "createdAt": "2026-05-01T12:34:56.000Z"
        }
        """.data(using: .utf8)!

        let post = try JSONDecoder().decode(WWAVRemotePost.self, from: json)

        XCTAssertEqual(post.plays, 123)
    }

    func testRemotePostDecodesEngagementMetrics() throws {
        let json = """
        {
          "id": 9,
          "kind": "video",
          "title": "clip",
          "views": 40,
          "likeCount": "12",
          "comment_count": 4,
          "remixCount": 2,
          "likedByMe": true,
          "reposted_by_me": "1"
        }
        """.data(using: .utf8)!

        let post = try JSONDecoder().decode(WWAVRemotePost.self, from: json)

        XCTAssertEqual(post.plays, 40)
        XCTAssertEqual(post.loves, 12)
        XCTAssertEqual(post.comments, 4)
        XCTAssertEqual(post.reposts, 2)
        XCTAssertEqual(post.liked, true)
        XCTAssertEqual(post.reposted, true)
    }

    func testRemotePostDecodesAlbumTrackIds() throws {
        let json = """
        {
          "id": 11,
          "kind": "album",
          "title": "tape",
          "trackIds": ["11111111-1111-1111-1111-111111111111", "track_remote"]
        }
        """.data(using: .utf8)!

        let post = try JSONDecoder().decode(WWAVRemotePost.self, from: json)

        XCTAssertEqual(post.kind, "album")
        XCTAssertEqual(post.trackIds, [
            "11111111-1111-1111-1111-111111111111",
            "track_remote",
        ])
    }

    func testRemotePostDecodesStoryShape() throws {
        let json = """
        {
          "id": 21,
          "kind": "story",
          "title": "story",
          "images": ["/api/images/story.jpg"],
          "User": { "id": 3, "username": "story_user" },
          "created_at": "2026-05-01T12:34:56.000Z"
        }
        """.data(using: .utf8)!

        let post = try JSONDecoder().decode(WWAVRemotePost.self, from: json)

        XCTAssertEqual(post.kind, "story")
        XCTAssertEqual(post.images?.first, "/api/images/story.jpg")
        XCTAssertEqual(post.author?.id, 3)
        XCTAssertEqual(post.author?.displayName, "story_user")
        XCTAssertNotNil(post.parsedCreatedAt)
    }

    func testStoryCodablePreservesRemotePostId() throws {
        let story = WWAVStory(
            authorName: "tester",
            handle: "tester",
            authorProfilePicture: nil,
            imageUrl: "/api/images/story.jpg",
            remotePostId: 21
        )

        let decoded = try JSONDecoder().decode(WWAVStory.self, from: JSONEncoder().encode(story))

        XCTAssertEqual(decoded.remotePostId, 21)
        XCTAssertEqual(decoded.imageUrl, "/api/images/story.jpg")
    }

    func testAlbumTrackCodablePreservesTracklist() throws {
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let album = Track(
            kind: .album,
            title: "album",
            artist: "tester",
            handle: "tester",
            bio: "notes",
            albumTrackIds: [first, second],
            status: .ready,
            durationSeconds: 120
        )

        let decoded = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(album))

        XCTAssertEqual(decoded.kind, .album)
        XCTAssertEqual(decoded.albumTrackIds, [first, second])
        XCTAssertEqual(decoded.thumbnailURL, nil)
    }

    func testRemotePostDecodesRootAuthorVariants() throws {
        let json = """
        {
          "id": 8,
          "kind": "text",
          "title": "note",
          "content": "hello",
          "user_id": "9",
          "handle": "@LMY_testing",
          "profile_picture": "profile_pictures/testing.jpg"
        }
        """.data(using: .utf8)!

        let post = try JSONDecoder().decode(WWAVRemotePost.self, from: json)

        XCTAssertEqual(post.author?.id, 9)
        XCTAssertEqual(post.author?.displayName, "LMY_testing")
        XCTAssertEqual(post.author?.profilePicture, "profile_pictures/testing.jpg")
    }

    func testFeedRankingGivesFreshPostsAnAudition() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = makeTrack(
            createdAt: now.addingTimeInterval(-60 * 60),
            plays: 0
        )
        let stale = makeTrack(
            createdAt: now.addingTimeInterval(-10 * 24 * 60 * 60),
            plays: 40
        )

        XCTAssertEqual(FeedRanking.rank([stale, fresh], referenceDate: now).first?.id, fresh.id)
    }

    func testFeedRankingLetsEvergreenHitsCompete() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = makeTrack(
            createdAt: now.addingTimeInterval(-2 * 60 * 60),
            plays: 0
        )
        let evergreen = makeTrack(
            createdAt: now.addingTimeInterval(-45 * 24 * 60 * 60),
            plays: 10_000
        )

        XCTAssertEqual(FeedRanking.rank([fresh, evergreen], referenceDate: now).first?.id, evergreen.id)
    }

    func testFeedRankingPromotesEngagementOverPureChronology() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let newer = makeTrack(
            createdAt: now.addingTimeInterval(-60 * 60),
            plays: 2
        )
        let engaged = makeTrack(
            createdAt: now.addingTimeInterval(-48 * 60 * 60),
            plays: 100,
            loves: 30,
            reposts: 5,
            comments: 10
        )

        XCTAssertEqual(FeedRanking.rank([newer, engaged], referenceDate: now).first?.id, engaged.id)
    }

    func testFollowIdentityMatchesByUserIdAcrossHandleChanges() {
        let identity = FollowIdentity(authorUserId: 12, handle: "old_name")

        XCTAssertEqual(identity?.stableKey, "user:12")
        XCTAssertEqual(identity?.matches(authorUserId: 12, handle: "new_name"), true)
        XCTAssertEqual(identity?.matches(authorUserId: 13, handle: "old_name"), false)
    }

    private func makeTrack(
        createdAt: Date,
        plays: Int,
        loves: Int = 0,
        reposts: Int = 0,
        comments: Int = 0
    ) -> Track {
        Track(
            title: "post",
            artist: "tester",
            handle: "tester",
            bio: "",
            status: .ready,
            durationSeconds: 0,
            createdAt: createdAt,
            plays: plays,
            loves: loves,
            reposts: reposts,
            comments: comments
        )
    }
}
