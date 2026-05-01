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

    func testRemoteUploadDecodesBackendShapeVariants() throws {
        let json = """
        {
          "id": 42,
          "trackId": "track_abc",
          "originalName": "song.wav",
          "status": "ready",
          "track": { "cover_art_url": "/api/images/cover.jpg" },
          "created_at": "2026-05-01T12:34:56.000Z"
        }
        """.data(using: .utf8)!

        let upload = try JSONDecoder().decode(WWAVRemoteUpload.self, from: json)

        XCTAssertEqual(upload.id, 42)
        XCTAssertEqual(upload.trackId, "track_abc")
        XCTAssertEqual(upload.coverArtUrl, "/api/images/cover.jpg")
        XCTAssertNotNil(upload.parsedCreatedAt)
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

    private func makeTrack(createdAt: Date, plays: Int) -> Track {
        Track(
            title: "post",
            artist: "tester",
            handle: "tester",
            bio: "",
            status: .ready,
            durationSeconds: 0,
            createdAt: createdAt,
            plays: plays
        )
    }
}
