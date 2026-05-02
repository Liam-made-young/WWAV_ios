import Foundation
import Combine
import AVFoundation

struct FollowIdentity: Codable, Hashable {
    let authorUserId: Int?
    let handle: String

    init?(authorUserId: Int?, handle: String) {
        let normalized = handle.normalizedHandle
        guard authorUserId != nil || !normalized.isEmpty else { return nil }
        self.authorUserId = authorUserId
        self.handle = normalized
    }

    var stableKey: String {
        if let authorUserId { return "user:\(authorUserId)" }
        return "handle:\(handle)"
    }

    func matches(authorUserId: Int?, handle rawHandle: String) -> Bool {
        if let lhs = self.authorUserId, let rhs = authorUserId {
            return lhs == rhs
        }
        let normalized = rawHandle.normalizedHandle
        return !handle.isEmpty && handle == normalized
    }
}

struct RadioSession: Identifiable, Codable, Equatable {
    var id: UUID = .init()
    var title: String
    var notes: String
    var hostName: String
    var hostHandle: String
    var queueTrackIds: [UUID]
    var currentIndex: Int = 0
    var isLive: Bool = false
    var startedAt: Date?
    var createdAt: Date = .init()

    var normalizedHostHandle: String {
        hostHandle.normalizedHandle
    }
}

enum FeedRanking {
    static func rank(_ tracks: [Track], referenceDate: Date = Date()) -> [Track] {
        tracks.sorted { lhs, rhs in
            let lhsScore = score(lhs, referenceDate: referenceDate)
            let rhsScore = score(rhs, referenceDate: referenceDate)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.plays != rhs.plays { return lhs.plays > rhs.plays }
            return lhs.createdAt > rhs.createdAt
        }
    }

    static func score(_ track: Track, referenceDate: Date = Date()) -> Double {
        let ageHours = max(0, referenceDate.timeIntervalSince(track.createdAt) / 3600)
        let views = Double(max(0, track.plays))
        let likes = Double(max(0, track.loves))
        let reposts = Double(max(0, track.reposts))
        let comments = Double(max(0, track.comments))
        let socialProof = log1p(views)
        let engagement = (likes * 2.4) + (comments * 3.2) + (reposts * 4.0)
        let engagementProof = log1p(engagement)
        let engagementRate = views > 0 ? min(1.0, engagement / max(views, 1)) : min(1.0, engagement / 4)

        // Fresh posts get a real audition window, then the boost fades.
        let recency = 28 * exp(-ageHours / 36)
        let firstDayOpportunity = max(0, 1 - (ageHours / 18)) * 10

        // Fast early traction matters more than slow accumulated views.
        let velocity = 30 * ((socialProof + engagementProof * 1.7) / pow(ageHours + 2, 0.65))

        // Old high-engagement posts still surface sometimes instead of
        // aging out completely.
        let evergreen = 4.5 * socialProof + 8.0 * engagementProof
        let quality = 12 * engagementRate * exp(-ageHours / 96)

        // Small deterministic rotation prevents permanent ties and gives
        // fresh low-view posts a little exploration without random UI jumps.
        let daySalt = Int(referenceDate.timeIntervalSince1970 / 86_400)
        let explorationWindow = ageHours <= 48 ? 5.0 : 2.0
        let exploration = stableNoise(for: track.id, salt: daySalt) * explorationWindow

        return recency + firstDayOpportunity + velocity + evergreen + quality + exploration
    }

    private static func stableNoise(for id: UUID, salt: Int) -> Double {
        var hash: UInt64 = 1_469_598_103_934_665_603
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        withUnsafeBytes(of: id.uuid) { buffer in
            for byte in buffer { mix(byte) }
        }

        var saltBits = UInt64(bitPattern: Int64(salt))
        for _ in 0..<8 {
            mix(UInt8(saltBits & 0xff))
            saltBits >>= 8
        }

        return Double(hash % 10_000) / 10_000
    }
}

/// Real, persisted track + profile store. No mock data.
///
/// On first launch it generates one playable sample track (4 synthetic stems)
/// so the audio engine and 3D player are immediately demonstrable. Everything
/// else is empty until the user uploads.
@MainActor
final class TrackLibrary: ObservableObject {
    @Published private(set) var myTracks: [Track] = []
    @Published private(set) var feed: [Track] = []
    @Published private(set) var profile: UserProfile
    @Published private(set) var radioSessions: [RadioSession] = []

    /// Tombstone set of every server-side trackId the user has deleted from
    /// this app. Persists across launches AND across app reinstalls (via
    /// the keychain — Application Support gets wiped when the app is
    /// uninstalled, so library.json alone is not enough). A server refresh
    /// can never resurrect a row the user explicitly removed.
    @Published private(set) var deletedTrackIds: Set<String> = []
    /// Tombstone set for non-music posts (image/text/video) by their local
    /// UUID — those don't have a server-side trackId.
    @Published private(set) var deletedPostUUIDs: Set<UUID> = []
    /// Tombstone set for server-backed image/text/video posts. This is the
    /// reinstall-safe guard: remote rows get fresh local UUIDs on a clean
    /// install, so UUID tombstones alone cannot prevent resurrection.
    @Published private(set) var deletedRemotePostIds: Set<Int> = []
    /// Per-track local edits keyed by remote trackId. Title / bio / cover
    /// changes the user makes on this device are written here AND mirrored
    /// to the keychain, so they survive an app reinstall even if the
    /// server-side metadata PUT silently failed. On every refresh we
    /// overlay these onto the server response — local edits always win.
    @Published private(set) var localEdits: [String: LocalEdit] = [:]
    /// Accounts the signed-in user follows from iOS. The server call is
    /// best-effort because deployed follow endpoints have varied over time;
    /// this set keeps the app's follow/following logic responsive locally.
    @Published private(set) var followedAccounts: Set<FollowIdentity> = []

    let storage: StorageService
    let separator: StemSeparationService

    private let stateURL: URL
    private let persistence: TrackLibraryPersistenceStore

    init(
        storage: StorageService = LocalDiskStorage(),
        separator: StemSeparationService
    ) {
        self.storage = storage
        self.separator = separator

        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.stateURL = base.appendingPathComponent("wwav/library.json")
        self.persistence = TrackLibraryPersistenceStore(url: stateURL)

        // One-time wipe of the pre-server-sync local library so old
        // half-broken/duplicate tracks don't haunt the feed forever. After
        // this, the server is the source of truth — `refresh(token:)` rebuilds
        // myTracks on every launch, and uploads round-trip through the cloud.
        let migrationKey = "wwav.didWipeLocalLibrary.v1"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            try? FileManager.default.removeItem(at: stateURL)
            UserDefaults.standard.set(true, forKey: migrationKey)
        }

        let state = persistence.load()
        self.profile = state.profile
        self.myTracks = state.myTracks
        self.feed = state.feed
        self.radioSessions = state.radioSessions
        self.deletedTrackIds = state.deletedTrackIds
        self.deletedPostUUIDs = state.deletedPostUUIDs
        self.deletedRemotePostIds = state.deletedRemotePostIds
        self.localEdits = state.localEdits
        self.followedAccounts = state.followedAccounts

        // Keychain is the durable source of truth for tombstones + edits
        // because it's the only thing on iOS that survives an app reinstall.
        // Union/merge with whatever was in library.json so the most
        // permissive set wins — a deletion stays a deletion, an edit stays
        // an edit, regardless of which store was around.
        if let restoredTombstones = WWAVKeychain.json(Set<String>.self, for: WWAVKeychainKeys.tombstones) {
            self.deletedTrackIds.formUnion(restoredTombstones)
        }
        if let restoredPostTombstones = WWAVKeychain.json(Set<Int>.self, for: WWAVKeychainKeys.postTombstones) {
            self.deletedRemotePostIds.formUnion(restoredPostTombstones)
        }
        if let restoredEdits = WWAVKeychain.json([String: LocalEdit].self, for: WWAVKeychainKeys.localEdits) {
            for (k, v) in restoredEdits {
                // If both stores have an edit for the same trackId, prefer
                // the one with the most non-nil fields (typically keychain).
                if let existing = self.localEdits[k] {
                    self.localEdits[k] = LocalEdit(
                        title:      v.title      ?? existing.title,
                        bio:        v.bio        ?? existing.bio,
                        coverArtUrl: v.coverArtUrl ?? existing.coverArtUrl
                    )
                } else {
                    self.localEdits[k] = v
                }
            }
        }
        if let restoredFollows = WWAVKeychain.json(Set<FollowIdentity>.self, for: WWAVKeychainKeys.followedAccounts) {
            self.followedAccounts.formUnion(restoredFollows)
        }

        // Defensive: scrub anything that survived in myTracks/feed despite
        // matching a tombstone we just restored from keychain.
        self.myTracks.removeAll { t in
            if self.deletedPostUUIDs.contains(t.id) { return true }
            if let tid = t.remoteTrackId, self.deletedTrackIds.contains(tid) { return true }
            if let pid = t.remotePostId, self.deletedRemotePostIds.contains(pid) { return true }
            return false
        }
        self.feed.removeAll { t in
            if self.deletedPostUUIDs.contains(t.id) { return true }
            if let tid = t.remoteTrackId, self.deletedTrackIds.contains(tid) { return true }
            if let pid = t.remotePostId, self.deletedRemotePostIds.contains(pid) { return true }
            return false
        }

        // Apply any local edits to whatever's already in the cache so the
        // first frame after launch matches the user's last-known state,
        // not stale server data.
        for (i, t) in self.myTracks.enumerated() {
            guard let tid = t.remoteTrackId, let edit = self.localEdits[tid] else { continue }
            var updated = t
            if let title = edit.title, !title.isEmpty { updated.title = title }
            if let bio = edit.bio { updated.bio = bio }
            if let cover = edit.coverArtUrl, !cover.isEmpty { updated.coverArtUrl = cover }
            self.myTracks[i] = updated
        }
        for (i, t) in self.feed.enumerated() {
            guard let tid = t.remoteTrackId, let edit = self.localEdits[tid] else { continue }
            var updated = t
            if let title = edit.title, !title.isEmpty { updated.title = title }
            if let bio = edit.bio { updated.bio = bio }
            if let cover = edit.coverArtUrl, !cover.isEmpty { updated.coverArtUrl = cover }
            self.feed[i] = updated
        }
    }

    // MARK: – Derived counters (no fake data, computed live)

    var myPosts: [Track] {
        myTracks.filter(isAuthoredByCurrentUser).sorted { $0.createdAt > $1.createdAt }
    }

    var albumCandidateTracks: [Track] {
        uniqueTracks(from: myTracks + feed)
            .filter { track in
                guard track.kind == .music else { return false }
                if case .ready = track.status { return true }
                return false
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var liveRadioSessions: [RadioSession] {
        radioSessions
            .filter(\.isLive)
            .sorted { lhs, rhs in
                (lhs.startedAt ?? lhs.createdAt) > (rhs.startedAt ?? rhs.createdAt)
            }
    }

    var trackCount: Int { myPosts.count }
    var totalPlays: Int { myPosts.reduce(0) { $0 + $1.plays } }
    var totalLoves: Int { myPosts.reduce(0) { $0 + $1.loves } }

    func albumTracks(for album: Track) -> [Track] {
        tracks(for: album.albumTrackIds ?? [])
    }

    func tracks(for session: RadioSession) -> [Track] {
        tracks(for: session.queueTrackIds)
    }

    func currentTrack(for session: RadioSession) -> Track? {
        let queued = tracks(for: session)
        guard !queued.isEmpty else { return nil }
        let safeIndex = min(max(0, session.currentIndex), queued.count - 1)
        return queued[safeIndex]
    }

    private func tracks(for ids: [UUID]) -> [Track] {
        guard !ids.isEmpty else { return [] }
        let pool = uniqueTracks(from: myTracks + feed)
        let byID = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    func posts(for route: PublicProfileRoute) -> [Track] {
        posts(authorUserId: route.authorUserId, handle: route.handle)
    }

    func posts(authorUserId: Int?, handle: String) -> [Track] {
        let normalizedHandle = handle.normalizedHandle
        var seen: Set<UUID> = []
        let pool = (feed + myTracks).filter { track in
            guard seen.insert(track.id).inserted else { return false }
            if let authorUserId, let trackAuthorId = track.authorUserId {
                return authorUserId == trackAuthorId
            }
            guard !normalizedHandle.isEmpty else { return false }
            return track.handle.normalizedHandle == normalizedHandle
                || track.artist.normalizedHandle == normalizedHandle
        }
        return pool.sorted { $0.createdAt > $1.createdAt }
    }

    func feed(for tab: Int) -> [Track] {
        switch tab {
        case 1:
            return FeedRanking.rank(feed.filter(isFollowedAuthor))
        case 2:
            return FeedRanking.rank(feed.filter { track in
                isAuthoredByCurrentUser(track)
                    || isFollowedAuthor(track)
                    || track.liked
                    || track.reposted
            })
        default:
            return feed
        }
    }

    var likedPosts: [Track] {
        uniqueTracks(from: feed + myTracks)
            .filter(\.liked)
            .sorted { $0.createdAt > $1.createdAt }
    }

    var remixedPosts: [Track] {
        uniqueTracks(from: feed + myTracks)
            .filter(\.reposted)
            .sorted { $0.createdAt > $1.createdAt }
    }

    func isAuthoredByCurrentUser(_ track: Track) -> Bool {
        isCurrentUser(authorUserId: track.authorUserId, handle: track.handle)
    }

    func isCurrentUser(authorUserId: Int?, handle: String) -> Bool {
        if let currentId = profile.remoteUserId, let authorUserId {
            return currentId == authorUserId
        }
        guard authorUserId == nil else { return false }
        return handle.normalizedHandle == profile.handle.normalizedHandle
    }

    func canFollow(authorUserId: Int?, handle: String) -> Bool {
        FollowIdentity(authorUserId: authorUserId, handle: handle) != nil
            && !isCurrentUser(authorUserId: authorUserId, handle: handle)
    }

    func canFollow(_ track: Track) -> Bool {
        canFollow(authorUserId: track.authorUserId, handle: track.handle)
    }

    func isFollowing(authorUserId: Int?, handle: String) -> Bool {
        guard canFollow(authorUserId: authorUserId, handle: handle) else { return false }
        return followedAccounts.contains { $0.matches(authorUserId: authorUserId, handle: handle) }
    }

    func isFollowing(_ track: Track) -> Bool {
        isFollowing(authorUserId: track.authorUserId, handle: track.handle)
    }

    func isFollowedAuthor(_ track: Track) -> Bool {
        isFollowing(track)
    }

    private func uniqueTracks(from tracks: [Track]) -> [Track] {
        var seen: Set<UUID> = []
        return tracks.filter { seen.insert($0.id).inserted }
    }

    private func orderedUnique(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: – Profile editing

    func updateProfile(name: String, handle: String, bio: String) {
        profile.name = name
        profile.handle = handle
        profile.bio = bio
        persist()
    }

    // MARK: – Upload

    /// Updates the local profile from the signed-in remote user. Called from
    /// the app shell when auth state changes so uploads + the profile screen
    /// reflect the same identity.
    func syncProfile(from remote: RemoteUser) {
        profile.remoteUserId = remote.id
        profile.name = remote.username
        profile.handle = remote.username
        if let bio = remote.bio, !bio.isEmpty { profile.bio = bio }
        profile.profilePicture = remote.profilePicture
        persist()
    }

    private var currentAuthor: WWAVRemoteAuthor {
        WWAVRemoteAuthor(
            id: profile.remoteUserId,
            username: profile.handle.isEmpty ? profile.name : profile.handle,
            profilePicture: profile.profilePicture
        )
    }

    private func applyAuthor(_ author: WWAVRemoteAuthor?, to track: inout Track) {
        guard let author, author.hasIdentity else { return }
        if let name = author.displayName {
            track.artist = name
            track.handle = name
        }
        if let id = author.id {
            track.authorUserId = id
        }
        if let picture = author.profilePicture, !picture.isEmpty {
            track.authorProfilePicture = picture
        }
    }

    private func authorName(_ author: WWAVRemoteAuthor?) -> String {
        author?.displayName ?? "wwav user"
    }

    /// Begins a music upload: copies the source into storage, kicks off Demucs,
    /// then resolves stem URLs once separation completes. If `coverImage`
    /// is provided, it's uploaded after separation succeeds and attached to
    /// the track via `PUT /api/tracks/<trackId>/metadata`.
    @discardableResult
    func startUpload(
        sourceURL: URL,
        title: String,
        bio: String,
        coverImage: Data? = nil,
        token: String? = nil
    ) -> UUID {
        let id = UUID()
        let track = Track(
            id: id,
            kind: .music,
            title: title.isEmpty ? "untitled" : title,
            artist: profile.name,
            handle: profile.handle,
            authorUserId: profile.remoteUserId,
            authorProfilePicture: profile.profilePicture,
            bio: bio,
            sourceURL: nil,
            sourceObjectKey: nil,
            stems: nil,
            stemObjectKeys: nil,
            status: .separating(0.0),
            durationSeconds: 0
        )
        myTracks.insert(track, at: 0)
        rebuildFeed()
        persist()

        Task { [weak self] in
            guard let self else { return }
            do {
                // 1. Get a stable copy in storage (so we keep it after the picker URL expires).
                let scoped = sourceURL.startAccessingSecurityScopedResource()
                defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
                let key = "uploads/\(id.uuidString)/source.\(sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension)"
                let cached = try await self.storage.putFile(
                    at: sourceURL, key: key, contentType: "audio/wav"
                )
                self.update(id: id) {
                    $0.sourceURL = cached
                    $0.sourceObjectKey = key
                }

                // 2. Run separation. The trackId callback fires as soon as
                // the server assigns one — we stamp it onto the local Track
                // immediately so any refresh in-flight matches by trackId
                // instead of creating a duplicate row.
                let result = try await self.separator.separate(
                    sourceURL: cached,
                    displayName: track.title,
                    onTrackIdAssigned: { tid in
                        self.update(id: id) { $0.remoteTrackId = tid }
                    }
                ) { p in
                    self.updateProgress(id: id, progress: p)
                }
                let bundle = result.bundle
                if let tid = result.remoteTrackId {
                    self.update(id: id) { $0.remoteTrackId = tid }
                }

                // 3. Persist each stem under a stable key.
                var keys: [String: String] = [:]
                var saved = bundle
                for kind in StemKind.allCases {
                    let stemURL = bundle.url(for: kind)
                    let stemKey = "uploads/\(id.uuidString)/stems/\(kind.demucsName).wav"
                    let cachedStem = try await self.storage.putFile(
                        at: stemURL, key: stemKey, contentType: "audio/wav"
                    )
                    keys[kind.demucsName] = stemKey
                    switch kind {
                    case .vox:   saved.vox = cachedStem
                    case .bass:  saved.bass = cachedStem
                    case .drum:  saved.drum = cachedStem
                    case .synth: saved.synth = cachedStem
                    }
                }
                self.update(id: id) {
                    $0.stems = saved
                    $0.stemObjectKeys = keys
                    $0.status = .ready
                }

                // 4. Optional cover art — upload to /api/upload-image, then
                // PUT the returned URL onto the track's metadata. Non-fatal
                // if it fails; the track is already playable.
                if let img = coverImage,
                   let token,
                   let trackId = await MainActor.run(body: { self.myTracks.first(where: { $0.id == id })?.remoteTrackId }) {
                    do {
                        let coverPath = try await Self.uploadCoverImage(img, token: token)
                        // Apply locally + write keychain edit BEFORE the
                        // metadata PUT, so the cover persists across
                        // reinstalls even if the PUT below fails.
                        self.update(id: id) { $0.coverArtUrl = coverPath }
                        var edit = await MainActor.run { self.localEdits[trackId] ?? LocalEdit() }
                        edit.coverArtUrl = coverPath
                        await MainActor.run {
                            self.localEdits[trackId] = edit
                            self.persist()
                        }
                        do {
                            try await Self.putCoverOnTrack(trackId: trackId, coverPath: coverPath, token: token)
                        } catch {
                            print("[Library] cover metadata PUT failed (local override stays): \(error)")
                        }
                    } catch {
                        print("[Library] cover upload failed: \(error)")
                    }
                }
            } catch {
                self.markFailed(id: id, message: error.localizedDescription)
            }
        }
        return id
    }

    /// Publishes four user-recorded stems directly into the stem player.
    /// This is the multitrack recording path: no Demucs split is needed
    /// because the user already recorded vox / bass / drum / synth lanes.
    @discardableResult
    func startMultitrackUpload(
        stemURLs: [StemKind: URL],
        title: String,
        bio: String,
        coverImage: Data? = nil,
        token: String? = nil
    ) -> UUID {
        let id = UUID()
        let track = Track(
            id: id,
            kind: .music,
            title: title.isEmpty ? "untitled" : title,
            artist: profile.name,
            handle: profile.handle,
            authorUserId: profile.remoteUserId,
            authorProfilePicture: profile.profilePicture,
            bio: bio,
            stems: nil,
            stemObjectKeys: nil,
            status: .uploading(phase: .saving, progress: 0),
            durationSeconds: 0
        )
        myTracks.insert(track, at: 0)
        rebuildFeed()
        persist()

        Task { [weak self] in
            guard let self else { return }
            do {
                var savedURLs: [StemKind: URL] = [:]
                var keys: [String: String] = [:]
                var maxDuration: Double = 0
                let total = Double(StemKind.allCases.count)

                for (index, kind) in StemKind.allCases.enumerated() {
                    guard let source = stemURLs[kind] else {
                        throw StemSeparationError.incompleteStems
                    }
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    let ext = source.pathExtension.isEmpty ? "wav" : source.pathExtension
                    let key = "uploads/\(id.uuidString)/recorded_stems/\(kind.demucsName).\(ext)"
                    let cached = try await self.storage.putFile(
                        at: source,
                        key: key,
                        contentType: "audio/wav"
                    )
                    savedURLs[kind] = cached
                    keys[kind.demucsName] = key
                    maxDuration = max(maxDuration, Self.audioDuration(url: cached))
                    let progress = Double(index + 1) / total
                    self.update(id: id) { $0.status = .uploading(phase: .saving, progress: progress) }
                }

                guard let vox = savedURLs[.vox],
                      let bass = savedURLs[.bass],
                      let drum = savedURLs[.drum],
                      let synth = savedURLs[.synth] else {
                    throw StemSeparationError.incompleteStems
                }

                var coverPath: String?
                if let coverImage {
                    if let token {
                        coverPath = try? await Self.uploadCoverImage(coverImage, token: token)
                    }
                    if coverPath == nil {
                        let coverKey = "uploads/\(id.uuidString)/cover.jpg"
                        if let local = try? await self.storage.put(coverImage, key: coverKey, contentType: "image/jpeg") {
                            coverPath = local.absoluteString
                        }
                    }
                }

                let bundle = StemBundle(vox: vox, bass: bass, drum: drum, synth: synth)
                self.update(id: id) {
                    $0.stems = bundle
                    $0.stemObjectKeys = keys
                    $0.coverArtUrl = coverPath
                    $0.durationSeconds = maxDuration
                    $0.status = .ready
                }
            } catch {
                self.markFailed(id: id, message: error.localizedDescription)
            }
        }

        return id
    }

    /// Creates an image post — a single-or-multi-image carousel. Each image
    /// is uploaded to `/api/upload-image` (so it persists server-side and is
    /// reachable by `/api/images/<key>`); if any upload fails we fall back
    /// to local file URLs so the post still appears in the feed.
    @discardableResult
    func createImagePost(
        images: [Data],
        title: String,
        caption: String,
        token: String? = nil
    ) -> UUID {
        let id = UUID()
        let track = Track(
            id: id,
            kind: .image,
            title: title.isEmpty ? "image post" : title,
            artist: profile.name,
            handle: profile.handle,
            authorUserId: profile.remoteUserId,
            authorProfilePicture: profile.profilePicture,
            bio: caption,
            imageUrls: nil,
            status: .separating(0.0),
            durationSeconds: 0
        )
        myTracks.insert(track, at: 0)
        rebuildFeed()
        persist()

        Task { [weak self] in
            guard let self else { return }
            var remoteUrls: [String] = []
            var anyUploaded = false
            if let token {
                for (idx, data) in images.enumerated() {
                    do {
                        let path = try await Self.uploadCoverImage(data, token: token)
                        remoteUrls.append(path)
                        anyUploaded = true
                        let progress = Double(idx + 1) / Double(images.count)
                        self.updateProgress(id: id, progress: progress)
                    } catch {
                        print("[Library] image upload failed (\(idx)): \(error)")
                    }
                }
            }
            // Fall back to caching locally for any image that didn't upload.
            if !anyUploaded || remoteUrls.count != images.count {
                for (idx, data) in images.enumerated() {
                    if idx < remoteUrls.count { continue }
                    let key = "uploads/\(id.uuidString)/image_\(idx).jpg"
                    do {
                        let local = try await self.storage.put(data, key: key, contentType: "image/jpeg")
                        remoteUrls.append(local.absoluteString)
                    } catch {
                        print("[Library] local image cache failed: \(error)")
                    }
                }
            }
            self.update(id: id) {
                $0.imageUrls = remoteUrls
                $0.coverArtUrl = remoteUrls.first
                $0.status = .ready
            }
            // Create server record so the post survives reinstall. Only use
            // platform URLs for the remote row; file:// fallbacks stay local
            // and will be retried by `syncPendingRemotePosts`.
            let platformUrls = remoteUrls.filter(Self.isPlatformAssetPath)
            if let token, platformUrls.count == images.count {
                let capturedTitle = title.isEmpty ? "image post" : title
                if let postId = await Self.createRemotePost(
                    kind: "image", title: capturedTitle, content: caption.isEmpty ? nil : caption,
                    images: platformUrls, coverImageUrl: platformUrls.first, token: token
                ) {
                    self.update(id: id) { $0.remotePostId = postId }
                    self.persist()
                }
            }
        }
        return id
    }

    @discardableResult
    func createTextPost(title: String, body: String, token: String? = nil) -> UUID {
        let id = UUID()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmedTitle.isEmpty ? "text post" : trimmedTitle
        let track = Track(
            id: id,
            kind: .text,
            title: finalTitle,
            artist: profile.name,
            handle: profile.handle,
            authorUserId: profile.remoteUserId,
            authorProfilePicture: profile.profilePicture,
            bio: "",
            textBody: body,
            status: .ready,
            durationSeconds: 0
        )
        myTracks.insert(track, at: 0)
        rebuildFeed()
        persist()
        if let token {
            Task { [weak self] in
                guard let self else { return }
                if let postId = await Self.createRemotePost(
                    kind: "text", title: finalTitle, content: body, token: token
                ) {
                    self.update(id: id) { $0.remotePostId = postId }
                    self.persist()
                }
            }
        }
        return id
    }

    /// Creates a video post — copies the file into local storage and
    /// publishes a TikTok-style post that takes over the play screen when
    /// tapped. Video uploads are local-only for now.
    @discardableResult
    func createVideoPost(
        videoURL: URL,
        title: String,
        caption: String,
        coverImage: Data? = nil,
        token: String? = nil
    ) -> UUID {
        let id = UUID()
        let track = Track(
            id: id,
            kind: .video,
            title: title.isEmpty ? "video" : title,
            artist: profile.name,
            handle: profile.handle,
            authorUserId: profile.remoteUserId,
            authorProfilePicture: profile.profilePicture,
            bio: caption,
            status: .uploading(phase: .compressing, progress: 0),
            durationSeconds: 0
        )
        myTracks.insert(track, at: 0)
        rebuildFeed()
        persist()

        Task { [weak self] in
            guard let self else { return }
            do {
                let scoped = videoURL.startAccessingSecurityScopedResource()
                defer { if scoped { videoURL.stopAccessingSecurityScopedResource() } }

                // Phase 1: Compress to H.264 720p.
                let out = try await VideoOptimizer.compress(source: videoURL) { [weak self] p in
                    self?.update(id: id) { $0.status = .uploading(phase: .compressing, progress: p) }
                }

                // Phase 2: Upload compressed file to S3 (or local fallback).
                self.update(id: id) { $0.status = .uploading(phase: .saving, progress: 0) }
                var rampProgress: Double = 0
                let rampTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        guard !Task.isCancelled else { break }
                        rampProgress = min(rampProgress + 0.05, 0.95)
                        self?.update(id: id) { $0.status = .uploading(phase: .saving, progress: rampProgress) }
                    }
                }

                var finalVideoURL: URL
                var s3Key: String? = nil
                if let token {
                    // Try S3 upload for server persistence.
                    do {
                        let (signedURL, key) = try await Self.signVideoUpload(token: token)
                        try await Self.putToS3(fileURL: out.url, signedURL: signedURL)
                        finalVideoURL = URL(string: "\(API.base)/api/videos/\(key.dropFirst(7))")
                            ?? out.url
                        s3Key = key
                    } catch {
                        print("[Library] S3 video upload failed, falling back to local: \(error)")
                        let key = "uploads/\(id.uuidString)/video.mp4"
                        finalVideoURL = (try? await self.storage.putFile(
                            at: out.url, key: key, contentType: "video/mp4"
                        )) ?? out.url
                    }
                } else {
                    let key = "uploads/\(id.uuidString)/video.mp4"
                    finalVideoURL = (try? await self.storage.putFile(
                        at: out.url, key: key, contentType: "video/mp4"
                    )) ?? out.url
                }
                rampTask.cancel()
                try? FileManager.default.removeItem(at: out.url)

                // Phase 3: Finalize — create server post record.
                self.update(id: id) { $0.status = .uploading(phase: .finalizing, progress: 1.0) }

                var coverPath: String? = nil
                if let img = coverImage, let token {
                    coverPath = try? await Self.uploadCoverImage(img, token: token)
                    if coverPath == nil {
                        let coverKey = "uploads/\(id.uuidString)/cover.jpg"
                        if let local = try? await self.storage.put(img, key: coverKey, contentType: "image/jpeg") {
                            coverPath = local.absoluteString
                        }
                    }
                }

                let capturedTitle = title.isEmpty ? "video" : title
                let remoteCoverPath = coverPath.flatMap { Self.isPlatformAssetPath($0) ? $0 : nil }
                if let token, let key = s3Key {
                    if let postId = await Self.createRemotePost(
                        kind: "video", title: capturedTitle,
                        content: caption.isEmpty ? nil : caption,
                        videoUrl: key, coverImageUrl: remoteCoverPath, token: token
                    ) {
                        self.update(id: id) { $0.remotePostId = postId }
                    }
                }

                self.update(id: id) {
                    $0.videoURL = finalVideoURL
                    $0.sourceObjectKey = s3Key
                    $0.videoDuration = out.duration
                    $0.durationSeconds = out.duration
                    $0.coverArtUrl = coverPath
                    $0.status = .ready
                }
                self.persist()
            } catch {
                self.markFailed(id: id, message: error.localizedDescription)
            }
        }
        return id
    }

    @discardableResult
    func createAlbumPost(
        title: String,
        caption: String,
        trackIds: [UUID],
        coverImage: Data? = nil,
        token: String? = nil
    ) -> UUID {
        let uniqueTrackIds = orderedUnique(trackIds)
        let albumTracks = tracks(for: uniqueTrackIds)
        let fallbackCover = albumTracks.first?.coverArtUrl
        let id = UUID()
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "untitled album"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalDuration = albumTracks.reduce(0) { $0 + $1.durationSeconds }
        let track = Track(
            id: id,
            kind: .album,
            title: finalTitle,
            artist: profile.name,
            handle: profile.handle,
            authorUserId: profile.remoteUserId,
            authorProfilePicture: profile.profilePicture,
            bio: caption,
            coverArtUrl: fallbackCover,
            albumTrackIds: uniqueTrackIds,
            status: .ready,
            durationSeconds: totalDuration
        )
        myTracks.insert(track, at: 0)
        rebuildFeed()
        persist()

        Task { [weak self] in
            guard let self else { return }
            var coverPath = fallbackCover
            if let coverImage {
                if let token {
                    coverPath = (try? await Self.uploadCoverImage(coverImage, token: token)) ?? coverPath
                }
                if coverPath == nil {
                    let coverKey = "uploads/\(id.uuidString)/album_cover.jpg"
                    if let local = try? await self.storage.put(coverImage, key: coverKey, contentType: "image/jpeg") {
                        coverPath = local.absoluteString
                    }
                }
            }
            if let coverPath {
                self.update(id: id) { $0.coverArtUrl = coverPath }
            }
            if let token {
                let platformCover = coverPath.flatMap { Self.isPlatformAssetPath($0) ? $0 : nil }
                if let postId = await Self.createRemotePost(
                    kind: "album",
                    title: finalTitle,
                    content: caption.isEmpty ? nil : caption,
                    coverImageUrl: platformCover,
                    trackIds: uniqueTrackIds.map(\.uuidString),
                    token: token
                ) {
                    self.update(id: id) { $0.remotePostId = postId }
                }
            }
        }

        return id
    }

    func updateAlbumTracklist(id: UUID, trackIds: [UUID], token: String? = nil) {
        let uniqueTrackIds = orderedUnique(trackIds)
        let selectedTracks = tracks(for: uniqueTrackIds)
        let totalDuration = selectedTracks.reduce(0) { $0 + $1.durationSeconds }
        let fallbackCover = selectedTracks.first?.coverArtUrl
        update(id: id) {
            $0.albumTrackIds = uniqueTrackIds
            $0.durationSeconds = totalDuration
            if ($0.coverArtUrl ?? "").isEmpty {
                $0.coverArtUrl = fallbackCover
            }
        }

        guard let token,
              let postId = myTracks.first(where: { $0.id == id })?.remotePostId else { return }
        Task {
            _ = try? await API.request(
                "/api/posts/\(postId)",
                method: "PATCH",
                body: ["trackIds": uniqueTrackIds.map(\.uuidString)],
                token: token
            )
        }
    }

    func startRadio(title: String, notes: String, queueTrackIds: [UUID]) -> UUID {
        let queue = orderedUnique(queueTrackIds)
        guard !queue.isEmpty else { return UUID() }
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(profile.name)'s radio"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = radioSessions.firstIndex(where: {
            $0.normalizedHostHandle == profile.handle.normalizedHandle
        }) {
            radioSessions[idx].title = finalTitle
            radioSessions[idx].notes = notes
            radioSessions[idx].hostName = profile.name
            radioSessions[idx].hostHandle = profile.handle
            radioSessions[idx].queueTrackIds = queue
            radioSessions[idx].currentIndex = min(radioSessions[idx].currentIndex, max(0, queue.count - 1))
            radioSessions[idx].isLive = true
            radioSessions[idx].startedAt = radioSessions[idx].startedAt ?? Date()
            persist()
            return radioSessions[idx].id
        }

        let session = RadioSession(
            title: finalTitle,
            notes: notes,
            hostName: profile.name,
            hostHandle: profile.handle,
            queueTrackIds: queue,
            currentIndex: 0,
            isLive: true,
            startedAt: Date()
        )
        radioSessions.insert(session, at: 0)
        persist()
        return session.id
    }

    func updateRadioSession(id: UUID, title: String, notes: String, queueTrackIds: [UUID]) {
        guard let idx = radioSessions.firstIndex(where: { $0.id == id }) else { return }
        let queue = orderedUnique(queueTrackIds)
        radioSessions[idx].title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? radioSessions[idx].title
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        radioSessions[idx].notes = notes
        radioSessions[idx].queueTrackIds = queue
        radioSessions[idx].currentIndex = min(radioSessions[idx].currentIndex, max(0, queue.count - 1))
        persist()
    }

    func stopRadio(id: UUID) {
        guard let idx = radioSessions.firstIndex(where: { $0.id == id }) else { return }
        radioSessions[idx].isLive = false
        radioSessions[idx].startedAt = nil
        persist()
    }

    func advanceRadio(id: UUID) {
        guard let idx = radioSessions.firstIndex(where: { $0.id == id }),
              !radioSessions[idx].queueTrackIds.isEmpty else { return }
        radioSessions[idx].currentIndex =
            (radioSessions[idx].currentIndex + 1) % radioSessions[idx].queueTrackIds.count
        persist()
    }

    // MARK: – Metadata editing

    /// Edits title, bio, and (optionally) text body of any post in place.
    /// For music posts with a server-side `remoteTrackId`, also pushes the
    /// title to the server so refresh-from-server keeps the new value.
    func updateMetadata(
        id: UUID,
        title: String,
        bio: String,
        textBody: String? = nil,
        token: String? = nil
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmedTitle.isEmpty ? "untitled" : trimmedTitle
        update(id: id) {
            $0.title = finalTitle
            $0.bio = bio
            if let textBody { $0.textBody = textBody }
        }

        guard let track = myTracks.first(where: { $0.id == id }) else { return }
        persist()

        if track.kind == .music, let trackId = track.remoteTrackId {
            var edit = localEdits[trackId] ?? LocalEdit()
            edit.title = finalTitle
            edit.bio = bio
            localEdits[trackId] = edit
            persist()
            if let token {
                Task {
                    do {
                        _ = try await API.request(
                            "/api/tracks/\(trackId)/metadata",
                            method: "PUT",
                            body: ["title": finalTitle, "originalName": finalTitle, "bio": bio],
                            token: token
                        )
                    } catch {
                        print("[Library] metadata push failed (local override stays): \(error)")
                    }
                }
            }
        } else if track.kind != .music, let postId = track.remotePostId, let token {
            Task {
                var body: [String: Any] = ["title": finalTitle, "content": bio]
                if let tb = textBody { body["content"] = tb }
                _ = try? await API.request("/api/posts/\(postId)", method: "PATCH", body: body, token: token)
            }
        }
    }

    /// Replaces the cover image on any post. Uploads to `/api/upload-image`
    /// when a token is available, falling back to a local cache otherwise.
    /// For music posts with a remoteTrackId, also pushes the cover to the
    /// server so it persists across devices.
    func replaceCover(id: UUID, image: Data, token: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            var savedPath: String?
            // Always try the server upload first so we get a stable path
            // (`/api/images/...`) that survives reinstall — local file://
            // URLs would be wiped when Application Support is cleared.
            if let token {
                do {
                    savedPath = try await Self.uploadCoverImage(image, token: token)
                } catch {
                    print("[Library] cover upload failed: \(error)")
                }
            }
            if savedPath == nil {
                let coverKey = "uploads/\(id.uuidString)/cover.jpg"
                if let local = try? await self.storage.put(image, key: coverKey, contentType: "image/jpeg") {
                    savedPath = local.absoluteString
                }
            }
            guard let path = savedPath else { return }
            self.update(id: id) { $0.coverArtUrl = path }

            // Mirror to localEdits so the cover survives reinstall even if
            // the metadata PUT below fails — this is what was missing.
            if let track = self.myTracks.first(where: { $0.id == id }),
               track.kind == .music,
               let trackId = track.remoteTrackId {
                var edit = self.localEdits[trackId] ?? LocalEdit()
                edit.coverArtUrl = path
                self.localEdits[trackId] = edit
                self.persist()

                if let token {
                    do {
                        try await Self.putCoverOnTrack(trackId: trackId, coverPath: path, token: token)
                    } catch {
                        print("[Library] cover metadata PUT failed (local override stays): \(error)")
                    }
                }
            } else if let track = self.myTracks.first(where: { $0.id == id }),
                      track.kind != .music,
                      let postId = track.remotePostId,
                      let token,
                      Self.isPlatformAssetPath(path) {
                Task {
                    _ = try? await API.request(
                        "/api/posts/\(postId)",
                        method: "PATCH",
                        body: ["coverImageUrl": path],
                        token: token
                    )
                }
            }
        }
    }

    /// Replaces the carousel images for an `.image` post.
    func replaceImages(id: UUID, images: [Data], token: String? = nil) {
        guard let track = myTracks.first(where: { $0.id == id }), track.kind == .image else { return }
        Task { [weak self] in
            guard let self else { return }
            var newUrls: [String] = []
            if let token {
                for data in images {
                    if let path = try? await Self.uploadCoverImage(data, token: token) {
                        newUrls.append(path)
                    }
                }
            }
            // Local fallback for any that didn't upload.
            for (idx, data) in images.enumerated() {
                if idx < newUrls.count { continue }
                let key = "uploads/\(id.uuidString)/image_\(idx)_\(Int(Date().timeIntervalSince1970)).jpg"
                if let local = try? await self.storage.put(data, key: key, contentType: "image/jpeg") {
                    newUrls.append(local.absoluteString)
                }
            }
            self.update(id: id) {
                $0.imageUrls = newUrls
                $0.coverArtUrl = newUrls.first ?? $0.coverArtUrl
            }
            let platformUrls = newUrls.filter(Self.isPlatformAssetPath)
            if let token, let postId = track.remotePostId, platformUrls.count == images.count {
                _ = try? await API.request(
                    "/api/posts/\(postId)",
                    method: "PATCH",
                    body: ["images": platformUrls, "coverImageUrl": platformUrls.first as Any],
                    token: token
                )
            }
        }
    }

    /// Replaces the video file for a `.video` post.
    func replaceVideo(id: UUID, videoURL: URL, token: String? = nil) {
        guard let track = myTracks.first(where: { $0.id == id && $0.kind == .video }) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let scoped = videoURL.startAccessingSecurityScopedResource()
                defer { if scoped { videoURL.stopAccessingSecurityScopedResource() } }

                self.update(id: id) { $0.status = .uploading(phase: .compressing, progress: 0) }
                let out = try await VideoOptimizer.compress(source: videoURL) { [weak self] p in
                    self?.update(id: id) { $0.status = .uploading(phase: .compressing, progress: p) }
                }

                self.update(id: id) { $0.status = .uploading(phase: .saving, progress: 0) }
                var rampProgress: Double = 0
                let rampTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        guard !Task.isCancelled else { break }
                        rampProgress = min(rampProgress + 0.05, 0.95)
                        self?.update(id: id) { $0.status = .uploading(phase: .saving, progress: rampProgress) }
                    }
                }
                var finalVideoURL: URL
                var objectKey: String
                if let token {
                    do {
                        let (signedURL, key) = try await Self.signVideoUpload(token: token)
                        try await Self.putToS3(fileURL: out.url, signedURL: signedURL)
                        objectKey = key
                        let stripped = key.hasPrefix("videos/") ? String(key.dropFirst(7)) : key
                        finalVideoURL = URL(string: "\(API.base)/api/videos/\(stripped)") ?? out.url
                    } catch {
                        print("[Library] remote video replace failed, falling back to local: \(error)")
                        let key = "uploads/\(id.uuidString)/video_\(Int(Date().timeIntervalSince1970)).mp4"
                        finalVideoURL = try await self.storage.putFile(at: out.url, key: key, contentType: "video/mp4")
                        objectKey = key
                    }
                } else {
                    let key = "uploads/\(id.uuidString)/video_\(Int(Date().timeIntervalSince1970)).mp4"
                    finalVideoURL = try await self.storage.putFile(at: out.url, key: key, contentType: "video/mp4")
                    objectKey = key
                }
                rampTask.cancel()
                try? FileManager.default.removeItem(at: out.url)

                self.update(id: id) {
                    $0.videoURL = finalVideoURL
                    $0.sourceObjectKey = objectKey
                    $0.videoDuration = out.duration
                    $0.durationSeconds = out.duration
                    $0.status = .ready
                }
                if let token, let postId = track.remotePostId, objectKey.hasPrefix("videos/") {
                    _ = try? await API.request(
                        "/api/posts/\(postId)",
                        method: "PATCH",
                        body: ["videoUrl": objectKey],
                        token: token
                    )
                }
            } catch {
                print("[Library] video replace failed: \(error)")
            }
        }
    }

    /// Replaces the audio source on a music post. The track is reset to
    /// `.separating` and a fresh separation is kicked off — when it
    /// completes, stems and `remoteTrackId` are swapped in.
    func replaceAudio(id: UUID, sourceURL: URL, token: String? = nil) {
        guard let track = myTracks.first(where: { $0.id == id }), track.kind == .music else { return }
        update(id: id) {
            $0.status = .separating(0.0)
            $0.stems = nil
            $0.stemObjectKeys = nil
            $0.remoteTrackId = nil
            $0.userUploadId = nil
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let scoped = sourceURL.startAccessingSecurityScopedResource()
                defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
                let key = "uploads/\(id.uuidString)/source_\(Int(Date().timeIntervalSince1970)).\(sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension)"
                let cached = try await self.storage.putFile(
                    at: sourceURL, key: key, contentType: "audio/wav"
                )
                self.update(id: id) {
                    $0.sourceURL = cached
                    $0.sourceObjectKey = key
                }

                let result = try await self.separator.separate(
                    sourceURL: cached,
                    displayName: track.title,
                    onTrackIdAssigned: { tid in
                        self.update(id: id) { $0.remoteTrackId = tid }
                    }
                ) { p in
                    self.updateProgress(id: id, progress: p)
                }
                let bundle = result.bundle
                if let tid = result.remoteTrackId {
                    self.update(id: id) { $0.remoteTrackId = tid }
                }

                var keys: [String: String] = [:]
                var saved = bundle
                for kind in StemKind.allCases {
                    let stemURL = bundle.url(for: kind)
                    let stemKey = "uploads/\(id.uuidString)/stems/\(kind.demucsName)_\(Int(Date().timeIntervalSince1970)).wav"
                    let cachedStem = try await self.storage.putFile(
                        at: stemURL, key: stemKey, contentType: "audio/wav"
                    )
                    keys[kind.demucsName] = stemKey
                    switch kind {
                    case .vox:   saved.vox = cachedStem
                    case .bass:  saved.bass = cachedStem
                    case .drum:  saved.drum = cachedStem
                    case .synth: saved.synth = cachedStem
                    }
                }
                self.update(id: id) {
                    $0.stems = saved
                    $0.stemObjectKeys = keys
                    $0.status = .ready
                }

                // If the original cover existed and the new server-side track
                // doesn't carry it forward, push it again.
                if let token,
                   let cover = await MainActor.run(body: { self.myTracks.first(where: { $0.id == id })?.coverArtUrl }),
                   let trackId = await MainActor.run(body: { self.myTracks.first(where: { $0.id == id })?.remoteTrackId }) {
                    try? await Self.putCoverOnTrack(trackId: trackId, coverPath: cover, token: token)
                }
            } catch {
                self.markFailed(id: id, message: error.localizedDescription)
            }
        }
    }

    // MARK: – Remix

    /// Creates a remixed music track from four user-supplied stem URLs.
    /// The stems are copied into local storage, a new `Track` is stamped
    /// with `parentTrackId` / `parentRemoteTrackId`, inserted into myTracks
    /// and returned. A server upload is attempted when a token is available.
    @discardableResult
    func createRemix(
        parent: Track,
        title: String,
        bio: String,
        newStems: [StemKind: URL],
        cover: Data? = nil,
        token: String? = nil
    ) -> UUID {
        let id = UUID()
        let track = Track(
            id: id,
            kind: .music,
            title: title.isEmpty ? "remix of \(parent.title)" : title,
            artist: profile.name,
            handle: profile.handle,
            authorUserId: profile.remoteUserId,
            authorProfilePicture: profile.profilePicture,
            bio: bio,
            stems: nil,
            status: .uploading(phase: .saving, progress: 0),
            durationSeconds: parent.durationSeconds,
            parentTrackId: parent.id,
            parentRemoteTrackId: parent.remoteTrackId
        )
        myTracks.insert(track, at: 0)
        rebuildFeed()
        persist()

        Task { [weak self] in
            guard let self else { return }
            do {
                // Copy each user-supplied stem into stable local storage.
                var keys: [String: String] = [:]
                var voxURL = newStems[.vox]     ?? parent.stems?.vox
                var bassURL = newStems[.bass]   ?? parent.stems?.bass
                var drumURL = newStems[.drum]   ?? parent.stems?.drum
                var synthURL = newStems[.synth] ?? parent.stems?.synth

                guard let v = voxURL, let b = bassURL, let d = drumURL, let s = synthURL else {
                    self.markFailed(id: id, message: "missing stem files")
                    return
                }

                for kind in StemKind.allCases {
                    let srcURL: URL
                    switch kind {
                    case .vox: srcURL = v
                    case .bass: srcURL = b
                    case .drum: srcURL = d
                    case .synth: srcURL = s
                    }
                    let stemKey = "uploads/\(id.uuidString)/stems/\(kind.demucsName).wav"
                    let scoped = srcURL.startAccessingSecurityScopedResource()
                    defer { if scoped { srcURL.stopAccessingSecurityScopedResource() } }
                    let cached = try await self.storage.putFile(at: srcURL, key: stemKey, contentType: "audio/wav")
                    keys[kind.demucsName] = stemKey
                    switch kind {
                    case .vox:   voxURL = cached
                    case .bass:  bassURL = cached
                    case .drum:  drumURL = cached
                    case .synth: synthURL = cached
                    }
                }

                guard let fv = voxURL, let fb = bassURL, let fd = drumURL, let fs = synthURL else {
                    self.markFailed(id: id, message: "stem cache failed")
                    return
                }

                let savedBundle = StemBundle(vox: fv, bass: fb, drum: fd, synth: fs)
                self.update(id: id) {
                    $0.stems = savedBundle
                    $0.stemObjectKeys = keys
                    $0.status = .ready
                }

                // Optional cover art.
                if let img = cover, let token {
                    if let coverPath = try? await Self.uploadCoverImage(img, token: token) {
                        self.update(id: id) { $0.coverArtUrl = coverPath }
                    }
                }
                self.persist()
            } catch {
                self.markFailed(id: id, message: error.localizedDescription)
            }
        }
        return id
    }

    /// Returns the parent track of a remix by searching `feed + myTracks`.
    /// Prefers matching by local UUID (`parentTrackId`), then falls back to
    /// the server-side remote track ID (`parentRemoteTrackId`).
    func parentTrack(of remix: Track) -> Track? {
        let pool = feed + myTracks
        if let localId = remix.parentTrackId,
           let found = pool.first(where: { $0.id == localId }) {
            return found
        }
        if let remoteId = remix.parentRemoteTrackId,
           let found = pool.first(where: { $0.remoteTrackId == remoteId }) {
            return found
        }
        return nil
    }

    /// Removes a post and guarantees it never reappears in iOS again,
    /// regardless of what the server says on subsequent refreshes.
    ///
    /// Three things happen, in this order:
    ///   1. The post is removed from `myTracks` and `feed` immediately so
    ///      the UI updates without waiting on the network.
    ///   2. The post's identifier is recorded in a persistent tombstone
    ///      set (`deletedTrackIds` for music, `deletedPostUUIDs` for
    ///      everything else). `applyRemote` consults these sets and
    ///      filters out matching server rows on every refresh — so even
    ///      if the server still has the row, iOS will keep ignoring it.
    ///   3. For server-backed music posts, a best-effort
    ///      `DELETE /api/uploads/<id>` is fired so the upload also vanishes
    ///      from any other client. We don't wait for or surface this —
    ///      the iOS-side promise is already kept by the tombstone.
    func deletePost(id: UUID, token: String? = nil) {
        let target = myTracks.first(where: { $0.id == id })
        myTracks.removeAll { $0.id == id }
        feed.removeAll { $0.id == id }

        if let target {
            if let trackId = target.remoteTrackId {
                deletedTrackIds.insert(trackId)
                // Drop any local edits for this trackId — once it's
                // tombstoned, we'll never render it again, so the override
                // is dead weight.
                localEdits.removeValue(forKey: trackId)
            }
            if let postId = target.remotePostId {
                deletedRemotePostIds.insert(postId)
            }
            // Always tombstone the local UUID too — for non-music posts it
            // is the only identifier, and for music posts it's a cheap
            // belt-and-braces guard against trackId-less duplicates.
            deletedPostUUIDs.insert(target.id)

            // Fire-and-forget server delete. Music → UserUpload endpoint;
            // image/text/video → TextPost endpoint.
            if let token {
                if target.kind == .music, let uploadId = target.userUploadId {
                    Task { await Self.deleteServerUpload(uploadId: uploadId, token: token) }
                } else if target.kind != .music, let postId = target.remotePostId {
                    Task {
                        try? await API.request(
                            "/api/posts/\(postId)", method: "DELETE", token: token
                        )
                    }
                }
            }
        }

        persist()  // mirrors tombstones to keychain via persist's tail
    }

    /// Best-effort server delete for a music upload. Tries a small set of
    /// likely endpoint shapes since the API contract for delete isn't
    /// documented yet — the first 2xx wins, everything else is logged and
    /// dropped. Failure here is non-fatal: the iOS tombstone is what
    /// actually guarantees the post stays hidden.
    private static func deleteServerUpload(uploadId: Int, token: String) async {
        let candidates = [
            "/api/uploads/\(uploadId)",
            "/api/user/uploads/\(uploadId)",
            "/api/upload/\(uploadId)",
        ]
        for path in candidates {
            do {
                _ = try await API.request(path, method: "DELETE", token: token)
                return
            } catch {
                continue
            }
        }
        print("[Library] server-side delete unavailable for upload \(uploadId); tombstoned locally")
    }

    // MARK: – Cover-art helpers

    /// POSTs a multipart image to `/api/upload-image` and returns the
    /// server-relative path the server assigns it (e.g. `/api/images/abc.jpg`).
    private static func uploadCoverImage(_ data: Data, token: String) async throws -> String {
        guard let url = URL(string: "\(API.base)/api/upload-image") else {
            throw APIError.unknown
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let boundary = "WWAV-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"cover.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let (respData, response) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server((response as? HTTPURLResponse)?.statusCode ?? -1, nil)
        }
        struct Resp: Decodable { let url: String }
        let parsed = try JSONDecoder().decode(Resp.self, from: respData)
        return parsed.url
    }

    /// Attaches an uploaded cover URL to the track's metadata so it
    /// persists on the platform and shows up across devices on refresh.
    private static func putCoverOnTrack(
        trackId: String, coverPath: String, token: String
    ) async throws {
        _ = try await API.request(
            "/api/tracks/\(trackId)/metadata",
            method: "PUT",
            body: ["coverArtUrl": coverPath],
            token: token
        )
    }

    private static func audioDuration(url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(file.length) / sampleRate
    }

    func incrementPlays(of id: UUID) {
        update(id: id) { $0.plays += 1 }
    }

    // MARK: – Social actions

    @MainActor
    func toggleFollow(track: Track, token: String?) async {
        await toggleFollow(
            authorUserId: track.authorUserId,
            handle: track.handle,
            token: token
        )
    }

    @MainActor
    func toggleFollow(route: PublicProfileRoute, token: String?) async {
        await toggleFollow(
            authorUserId: route.authorUserId,
            handle: route.handle,
            token: token
        )
    }

    @MainActor
    func toggleFollow(authorUserId: Int?, handle: String, token: String?) async {
        guard canFollow(authorUserId: authorUserId, handle: handle),
              let identity = FollowIdentity(authorUserId: authorUserId, handle: handle) else { return }
        let wasFollowing = isFollowing(authorUserId: authorUserId, handle: handle)
        if wasFollowing {
            followedAccounts = Set(followedAccounts.filter {
                !$0.matches(authorUserId: authorUserId, handle: handle)
            })
        } else {
            followedAccounts.insert(identity)
        }
        rebuildFeed()
        persist()

        guard let token else { return }
        do {
            try await Self.pushFollow(identity: identity, shouldFollow: !wasFollowing, token: token)
        } catch {
            print("[Library] follow sync failed for \(identity.stableKey): \(error)")
        }
    }

    /// Toggles a like for `track` on the server and reflects the new state
    /// locally. Optimistic — updates the UI immediately, then reverts on
    /// network failure so the heart never gets stuck "filled" if the
    /// request didn't actually go through.
    @MainActor
    func toggleLike(track: Track, token: String?) async {
        if track.kind != .music, let postId = track.remotePostId, let token {
            await toggleRemotePostLike(track: track, postId: postId, token: token)
            return
        }

        if track.kind == .music,
           track.userUploadId == nil,
           let publishedTrackId = track.publishedTrackId,
           let token {
            await toggleRemotePublishedLike(track: track, publishedTrackId: publishedTrackId, token: token)
            return
        }

        // Local-only posts (image/text/video without a remote post id) just
        // toggle in-memory.
        if track.kind != .music || track.userUploadId == nil {
            let prev = track.liked
            update(id: track.id) {
                $0.liked = !prev
                $0.loves = max(0, $0.loves + (prev ? -1 : 1))
            }
            return
        }
        guard let token, let uploadId = track.userUploadId else { return }

        // Optimistic flip.
        let prevLiked = track.liked
        let prevLoves = track.loves
        update(id: track.id) {
            $0.liked = !prevLiked
            $0.loves = max(0, prevLoves + (prevLiked ? -1 : 1))
        }

        struct Resp: Decodable { let liked: Bool }
        do {
            let data = try await API.post(
                "/api/social/like/\(uploadId)?type=upload",
                token: token
            )
            let resp = try JSONDecoder().decode(Resp.self, from: data)
            // Server is the truth. If our optimistic guess matches, no-op;
            // otherwise reconcile.
            update(id: track.id) {
                if $0.liked != resp.liked {
                    $0.liked = resp.liked
                    $0.loves = max(0, prevLoves + (resp.liked ? 1 : 0)
                                              - (prevLiked ? 1 : 0))
                }
            }
        } catch {
            // Revert.
            update(id: track.id) {
                $0.liked = prevLiked
                $0.loves = prevLoves
            }
            print("[Library] toggleLike failed: \(error)")
        }
    }

    @MainActor
    private func toggleRemotePublishedLike(track: Track, publishedTrackId: Int, token: String) async {
        let prevLiked = track.liked
        let prevLoves = track.loves
        update(id: track.id) {
            $0.liked = !prevLiked
            $0.loves = max(0, prevLoves + (prevLiked ? -1 : 1))
        }

        struct Resp: Decodable { let liked: Bool }
        do {
            let data = try await API.post(
                "/api/social/like/\(publishedTrackId)?type=published",
                token: token
            )
            let resp = try JSONDecoder().decode(Resp.self, from: data)
            update(id: track.id) {
                if $0.liked != resp.liked {
                    $0.liked = resp.liked
                    $0.loves = max(0, prevLoves + (resp.liked ? 1 : 0)
                                              - (prevLiked ? 1 : 0))
                }
            }
        } catch {
            update(id: track.id) {
                $0.liked = prevLiked
                $0.loves = prevLoves
            }
            print("[Library] published like failed: \(error)")
        }
    }

    @MainActor
    private func toggleRemotePostLike(track: Track, postId: Int, token: String) async {
        let prevLiked = track.liked
        let prevLoves = track.loves
        update(id: track.id) {
            $0.liked = !prevLiked
            $0.loves = max(0, prevLoves + (prevLiked ? -1 : 1))
        }

        struct Resp: Decodable { let liked: Bool }
        let candidateTypes = ["post", "textpost", "textPost"]
        for type in candidateTypes {
            do {
                let data = try await API.post(
                    "/api/social/like/\(postId)?type=\(type)",
                    token: token
                )
                let resp = try JSONDecoder().decode(Resp.self, from: data)
                update(id: track.id) {
                    if $0.liked != resp.liked {
                        $0.liked = resp.liked
                        $0.loves = max(0, prevLoves + (resp.liked ? 1 : 0)
                                                  - (prevLiked ? 1 : 0))
                    }
                }
                return
            } catch {
                continue
            }
        }

        // Keep the local optimistic value if the backend hasn't exposed post
        // likes yet; comments still use the server-backed post id.
        print("[Library] post like endpoint unavailable for post \(postId)")
    }

    /// Local-only repost toggle. The backend doesn't have a repost endpoint
    /// yet — when one lands, swap this for an API call mirroring `toggleLike`.
    @MainActor
    func toggleRepost(track: Track) {
        let prev = track.reposted
        update(id: track.id) {
            $0.reposted = !prev
            $0.reposts = max(0, $0.reposts + (prev ? -1 : 1))
        }
    }

    private struct FollowRequestCandidate {
        let path: String
        let method: String
        let body: [String: Any]?
    }

    private static func pushFollow(
        identity: FollowIdentity,
        shouldFollow: Bool,
        token: String
    ) async throws {
        var candidates: [FollowRequestCandidate] = []
        if let userId = identity.authorUserId {
            candidates.append(contentsOf: [
                FollowRequestCandidate(path: "/api/social/follow/\(userId)", method: shouldFollow ? "POST" : "DELETE", body: nil),
                FollowRequestCandidate(path: "/api/users/\(userId)/follow", method: shouldFollow ? "POST" : "DELETE", body: nil),
                FollowRequestCandidate(path: "/api/follow/\(userId)", method: shouldFollow ? "POST" : "DELETE", body: nil),
                FollowRequestCandidate(path: "/api/social/follow", method: shouldFollow ? "POST" : "DELETE", body: ["userId": userId]),
            ])
        }
        candidates.append(contentsOf: [
            FollowRequestCandidate(path: "/api/social/follow/@\(identity.handle)", method: shouldFollow ? "POST" : "DELETE", body: nil),
            FollowRequestCandidate(path: "/api/follow/@\(identity.handle)", method: shouldFollow ? "POST" : "DELETE", body: nil),
            FollowRequestCandidate(path: "/api/social/follow", method: shouldFollow ? "POST" : "DELETE", body: ["handle": identity.handle]),
        ])

        var lastError: Error?
        for candidate in candidates {
            do {
                _ = try await API.request(
                    candidate.path,
                    method: candidate.method,
                    body: candidate.body,
                    token: token
                )
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? APIError.unknown
    }

    /// Returns a Track whose `.stems` are guaranteed to be on disk and ready
    /// for the audio engine. Server-fetched tracks have nil `stems` until the
    /// user taps play; in that case we download all four stems from
    /// `mi-wwav.com/stems/<trackId>/<name>.mp3` before returning.
    @MainActor
    func prepareForPlayback(
        _ track: Track,
        onProgress: ((Double) -> Void)? = nil
    ) async -> Track? {
        if track.kind != .music { return track }
        if track.stems != nil {
            onProgress?(1)
            return track
        }
        guard let trackId = track.remoteTrackId else { return nil }

        let dir: URL
        do {
            dir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("stems/\(trackId)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("[Library] prepareForPlayback dir error: \(error)")
            return nil
        }

        let totalStems = Double(StemKind.allCases.count)
        var saved: [StemKind: URL] = [:]
        for (idx, kind) in StemKind.allCases.enumerated() {
            let remote = "\(API.base)/stems/\(trackId)/\(kind.demucsName).mp3"
            guard let url = URL(string: remote) else { return nil }
            do {
                let (tmp, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    return nil
                }
                let dest = dir.appendingPathComponent("\(kind.demucsName).mp3")
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tmp, to: dest)
                saved[kind] = dest
                onProgress?(Double(idx + 1) / totalStems)
            } catch {
                print("[Library] stem download failed (\(kind.demucsName)): \(error)")
                return nil
            }
        }

        guard let vox = saved[.vox], let bass = saved[.bass],
              let drum = saved[.drum], let synth = saved[.synth] else {
            return nil
        }
        let bundle = StemBundle(vox: vox, bass: bass, drum: drum, synth: synth)
        update(id: track.id) { $0.stems = bundle }
        var primed = track
        primed.stems = bundle
        return primed
    }

    // MARK: – Server sync
    //
    // The mi-wwav.com backend is the source of truth for social content.
    // `refresh(token:)` prefers global app-wide endpoints so Home is a real
    // multi-user feed, then falls back to user-scoped endpoints if the server
    // has not deployed the global route yet.

    /// Pulls the user's uploads from the server and merges with local state.
    /// - Local copies of in-flight (`.separating`) uploads are preserved so a
    ///   refresh during a pending separation doesn't overwrite progress.
    /// - Local copies of stem files (downloaded for playback) survive refresh.
    /// - Local non-music posts (image/text/video) are preserved verbatim.
    /// - Remote uploads not yet seen locally are appended at the top.
    @MainActor
    func refresh(token: String?) async {
        guard let token else { return }
        // Music uploads (Demucs pipeline)
        do {
            let remote = try await API.client.globalUploads(token: token)
            applyRemote(remote, token: token, fallbackAuthor: currentAuthor)
        } catch {
            print("[Library] global music refresh failed, falling back to user uploads: \(error)")
            do {
                let remote = try await API.client.userUploads(token: token)
                applyRemote(remote, token: token, fallbackAuthor: currentAuthor)
            } catch {
                print("[Library] music refresh failed: \(error)")
            }
        }
        // Image / text / video posts (TextPost)
        do {
            let posts = try await API.client.globalPosts(token: token)
            applyRemotePosts(posts, fallbackAuthor: currentAuthor)
        } catch {
            print("[Library] global posts refresh failed, falling back to user posts: \(error)")
            do {
                let posts = try await API.client.userPosts(token: token)
                applyRemotePosts(posts, fallbackAuthor: currentAuthor)
            } catch {
                print("[Library] posts refresh failed: \(error)")
            }
        }
        await syncPendingRemotePosts(token: token)
    }

    private struct RemoteUpload: Decodable {
        let id: Int                 // UserUpload primary key — needed for likes
        let trackId: String
        let originalName: String?
        let status: String          // processing | ready | failed | "..."
        let coverArtUrl: String?
        let createdAtRaw: String?

        var parsedCreatedAt: Date? {
            guard let s = createdAtRaw else { return nil }
            // Try ISO8601 with fractional seconds (Sequelize default), then
            // without, then a plain date — defensive so we don't drop data.
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFrac.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let d = plain.date(from: s) { return d }
            return nil
        }

        // The server returns either `createdAt` (camelCase) or `created_at`
        // (snake_case) depending on Sequelize config — accept both. Cover art
        // can show up in three places depending on which join the API
        // pulls: the upload row itself, a nested `track` object, or a
        // sibling `metadata` blob. Try them all in priority order.
        enum CodingKeys: String, CodingKey {
            case id
            case trackId, originalName, status
            case coverArtUrl, cover_art_url
            case track, metadata
            case createdAt
            case created_at
        }

        private struct CoverWrapper: Decodable {
            let coverArtUrl: String?
            let cover_art_url: String?
            var any: String? { coverArtUrl ?? cover_art_url }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            trackId = try c.decode(String.self, forKey: .trackId)
            originalName = try c.decodeIfPresent(String.self, forKey: .originalName)
            status = try c.decode(String.self, forKey: .status)
            let directCover = (try? c.decode(String.self, forKey: .coverArtUrl))
                ?? (try? c.decode(String.self, forKey: .cover_art_url))
            let trackCover = (try? c.decode(CoverWrapper.self, forKey: .track))?.any
            let metaCover  = (try? c.decode(CoverWrapper.self, forKey: .metadata))?.any
            coverArtUrl = directCover ?? trackCover ?? metaCover
            createdAtRaw = (try? c.decode(String.self, forKey: .createdAt))
                ?? (try? c.decode(String.self, forKey: .created_at))
        }
    }

    private func applyRemote(
        _ remote: [WWAVRemoteUpload],
        token: String?,
        fallbackAuthor: WWAVRemoteAuthor?
    ) {
        // Index existing local rows by their (now-stamped) remoteTrackId so
        // we can reuse local state — stems already cached, plays count,
        // liked/reposted toggles, locally-edited title — when the server
        // confirms the same upload.
        var localByTrackId: [String: Track] = [:]
        for t in myTracks where t.kind == .music {
            if let tid = t.remoteTrackId { localByTrackId[tid] = t }
        }

        // Local in-flight uploads that haven't received their server-side
        // trackId yet (rare; happens between sign() and the callback). Keep
        // them around so the user sees progress.
        let inFlightUntagged = myTracks.filter { t in
            guard t.kind == .music else { return false }
            if case .separating = t.status, t.remoteTrackId == nil { return true }
            return false
        }

        // Non-music posts live entirely client-side — preserve them verbatim.
        let nonMusicLocal = myTracks.filter { $0.kind != .music }

        // Track which uploaded covers the server is missing so we can push
        // them up after the merge. This is what makes covers persist across
        // a clean reinstall: any cover the user attached locally that
        // didn't make it to the server gets re-attached on the next refresh.
        var coversToPush: [(trackId: String, path: String)] = []

        // Build a fresh list from the server response. Drop server rows
        // whose stems aren't actually available — the server marks an
        // upload as "ready" only after Replicate flips the status, so any
        // non-ready row from `/api/user/uploads` means there is no playable
        // track on disk on the server side. The lone exception: the user's
        // own in-flight upload that's still mid-processing — we keep that
        // row visible so they see its progress bar through the next poll.
        var rebuilt: [Track] = []
        for r in remote {
            // Tombstone check: if the user has explicitly deleted this
            // upload from iOS, never resurrect it — even if the server
            // still has the row.
            if deletedTrackIds.contains(r.trackId) { continue }
            if deletedPostUUIDs.contains(uuidFromTrackId(r.trackId)) { continue }

            let remoteState = RemoteProcessingState(serverStatus: r.status)
            let trackStatus = remoteState.trackStatus

            // Skip non-ready server rows unless this device is mid-upload
            // for the same trackId. This is what hides web-app uploads
            // that never finished separation — the broken-link case.
            if !remoteState.isRenderableRemoteRow {
                let local = localByTrackId[r.trackId]
                let isOurInFlight: Bool = {
                    guard let local else { return false }
                    if case .separating = local.status { return true }
                    return false
                }()
                if !isOurInFlight {
                    continue
                }
            }

            let stemKeys: [String: String] = [
                StemKind.vox.demucsName:   "stems/\(r.trackId)/vocals.mp3",
                StemKind.bass.demucsName:  "stems/\(r.trackId)/bass.mp3",
                StemKind.drum.demucsName:  "stems/\(r.trackId)/drums.mp3",
                StemKind.synth.demucsName: "stems/\(r.trackId)/other.mp3",
            ]

            if var existing = localByTrackId[r.trackId] {
                // Reuse the local row (preserve stems cache, plays, likes…).
                if case .separating = existing.status {
                    // Mid-separation locally — don't clobber with server status.
                } else {
                    existing.status = trackStatus
                }
                existing.userUploadId = r.id
                existing.publishedTrackId = r.publishedTrackId
                existing.stemObjectKeys = stemKeys
                applyAuthor(r.author ?? fallbackAuthor, to: &existing)
                if let plays = r.plays {
                    existing.plays = max(existing.plays, plays)
                }
                if let loves = r.loves {
                    existing.loves = max(existing.loves, loves)
                }
                if let reposts = r.reposts {
                    existing.reposts = max(existing.reposts, reposts)
                }
                if let comments = r.comments {
                    existing.comments = max(existing.comments, comments)
                }
                if let liked = r.liked {
                    existing.liked = liked
                }
                if let reposted = r.reposted {
                    existing.reposted = reposted
                }

                // Server cover only fills in when the local row has none;
                // anything else is overridden by `localEdits` below.
                if (existing.coverArtUrl ?? "").isEmpty,
                   let serverCover = r.coverArtUrl, !serverCover.isEmpty {
                    existing.coverArtUrl = serverCover
                }
                rebuilt.append(existing)
            } else {
                // Brand new from server.
                let id = uuidFromTrackId(r.trackId)
                let author = r.author ?? fallbackAuthor
                let name = authorName(author)
                let new = Track(
                    id: id,
                    kind: .music,
                    title: cleanedDisplayTitle(from: r.originalName),
                    artist: name,
                    handle: name,
                    authorUserId: author?.id,
                    authorProfilePicture: author?.profilePicture,
                    bio: "",
                    sourceURL: nil,
                    sourceObjectKey: "stems/\(r.trackId)",
                    remoteTrackId: r.trackId,
                    userUploadId: r.id,
                    publishedTrackId: r.publishedTrackId,
                    coverArtUrl: r.coverArtUrl,
                    stems: nil,
                    stemObjectKeys: stemKeys,
                    status: trackStatus,
                    durationSeconds: 0,
                    createdAt: r.parsedCreatedAt ?? Date(),
                    plays: r.plays ?? 0,
                    loves: r.loves ?? 0,
                    reposts: r.reposts ?? 0,
                    comments: r.comments ?? 0,
                    liked: r.liked ?? false,
                    reposted: r.reposted ?? false
                )
                rebuilt.append(new)
            }
        }

        // Local edits always win. This is what makes a renamed title or a
        // replaced cover survive an app reinstall: even if the matching
        // server PUT failed, the iOS-side override here re-applies it.
        // We also use this pass to flag covers the server doesn't know
        // about so we can re-push them.
        for i in rebuilt.indices {
            guard let tid = rebuilt[i].remoteTrackId,
                  let edit = localEdits[tid] else { continue }
            if let title = edit.title, !title.isEmpty {
                rebuilt[i].title = title
            }
            if let bio = edit.bio {
                rebuilt[i].bio = bio
            }
            if let cover = edit.coverArtUrl, !cover.isEmpty {
                rebuilt[i].coverArtUrl = cover
            }
            // If the server's cover is missing or different from our edit,
            // queue a push so the server eventually catches up.
            if let editedCover = edit.coverArtUrl, !editedCover.isEmpty {
                let serverHas = (remote.first(where: { $0.trackId == tid })?.coverArtUrl ?? "")
                if serverHas != editedCover {
                    coversToPush.append((trackId: tid, path: editedCover))
                }
            }
        }

        // In-flight uploads at the top so the user sees their progress;
        // followed by local non-music posts, then server rows newest first.
        myTracks = inFlightUntagged + nonMusicLocal + rebuilt
        myTracks.sort { $0.createdAt > $1.createdAt }
        rebuildFeed()
        persist()

        // Push any covers the server didn't know about. Best-effort — we
        // don't surface failures because the local cover still renders
        // fine; the worst case is the next reinstall sees no cover.
        if let token, !coversToPush.isEmpty {
            Task {
                for (tid, path) in coversToPush {
                    do {
                        try await Self.putCoverOnTrack(trackId: tid, coverPath: path, token: token)
                    } catch {
                        print("[Library] cover propagation failed for \(tid): \(error)")
                    }
                }
            }
        }
    }

    /// Some server uploads (older builds of the iOS client) stored a
    /// normalized cache filename like "source.wav" as `originalName`.
    /// Treat those as no-name and fall back to "untitled".
    private func cleanedDisplayTitle(from originalName: String?) -> String {
        guard let raw = originalName?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return "untitled" }
        let lower = raw.lowercased()
        let badNames: Set<String> = [
            "source.wav", "source.mp3", "source.m4a", "source.aiff", "source.flac",
            "input.wav", "input.mp3",
        ]
        if badNames.contains(lower) { return "untitled" }
        return raw
    }

    /// Stable UUID seeded by the remote trackId so refresh→refresh is idempotent.
    private func uuidFromTrackId(_ tid: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let utf8 = Array(tid.utf8)
        for i in 0..<min(16, utf8.count) { bytes[i] = utf8[i] }
        // Set RFC-4122 version 4 + variant bits to make it a valid UUID.
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: – Remote posts (image / text / video)

    private struct RemotePost: Decodable {
        let id: Int
        let kind: String?
        let title: String?
        let content: String?
        let images: [String]?
        let videoUrl: String?
        let coverImageUrl: String?
        let createdAtRaw: String?

        var parsedCreatedAt: Date? {
            guard let s = createdAtRaw else { return nil }
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFrac.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: s)
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, title, content, images, videoUrl, coverImageUrl
            case created_at, createdAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id           = try c.decode(Int.self, forKey: .id)
            kind         = try c.decodeIfPresent(String.self, forKey: .kind)
            title        = try c.decodeIfPresent(String.self, forKey: .title)
            content      = try c.decodeIfPresent(String.self, forKey: .content)
            images       = try c.decodeIfPresent([String].self, forKey: .images)
            videoUrl     = try c.decodeIfPresent(String.self, forKey: .videoUrl)
            coverImageUrl = try c.decodeIfPresent(String.self, forKey: .coverImageUrl)
            createdAtRaw = (try? c.decode(String.self, forKey: .created_at))
                ?? (try? c.decode(String.self, forKey: .createdAt))
        }
    }

    private func applyRemotePosts(
        _ remotePosts: [WWAVRemotePost],
        fallbackAuthor: WWAVRemoteAuthor?
    ) {
        var localByPostId: [Int: Track] = [:]
        for t in myTracks where t.kind != .music {
            if let pid = t.remotePostId { localByPostId[pid] = t }
        }

        var rebuilt: [Track] = []
        for r in remotePosts {
            // Skip tombstoned posts
            if deletedRemotePostIds.contains(r.id) { continue }
            if let existing = localByPostId[r.id], deletedPostUUIDs.contains(existing.id) { continue }

            let kind: PostKind = {
                switch r.kind {
                case "album": return .album
                case "image": return .image
                case "video": return .video
                default: return .text
                }
            }()

            if var existing = localByPostId[r.id] {
                // Refresh existing local post from server, preserving in-flight state.
                if case .uploading = existing.status { rebuilt.append(existing); continue }
                existing.title = r.title ?? existing.title
                existing.bio = r.content ?? existing.bio
                applyAuthor(r.author ?? fallbackAuthor, to: &existing)
                if let plays = r.plays {
                    existing.plays = max(existing.plays, plays)
                }
                if let loves = r.loves {
                    existing.loves = max(existing.loves, loves)
                }
                if let reposts = r.reposts {
                    existing.reposts = max(existing.reposts, reposts)
                }
                if let comments = r.comments {
                    existing.comments = max(existing.comments, comments)
                }
                if let liked = r.liked {
                    existing.liked = liked
                }
                if let reposted = r.reposted {
                    existing.reposted = reposted
                }
                if kind == .image, let imgs = r.images, !imgs.isEmpty {
                    existing.imageUrls = imgs
                    existing.coverArtUrl = r.coverImageUrl ?? imgs.first ?? existing.coverArtUrl
                }
                if kind == .video, let vKey = r.videoUrl {
                    let stripped = vKey.hasPrefix("videos/") ? String(vKey.dropFirst(7)) : vKey
                    existing.videoURL = URL(string: "\(API.base)/api/videos/\(stripped)")
                    existing.coverArtUrl = r.coverImageUrl ?? existing.coverArtUrl
                }
                if kind == .album {
                    existing.albumTrackIds = localAlbumTrackIds(from: r.trackIds) ?? existing.albumTrackIds
                    existing.coverArtUrl = r.coverImageUrl ?? existing.coverArtUrl
                }
                if kind == .text { existing.textBody = r.content ?? existing.textBody }
                rebuilt.append(existing)
            } else {
                // Post only exists on server (fresh install / other device).
                let author = r.author ?? fallbackAuthor
                let name = authorName(author)
                var t = Track(
                    id: UUID(),
                    kind: kind,
                    title: r.title ?? defaultTitle(for: kind),
                    artist: name,
                    handle: name,
                    authorUserId: author?.id,
                    authorProfilePicture: author?.profilePicture,
                    bio: r.content ?? "",
                    remotePostId: r.id,
                    albumTrackIds: kind == .album ? localAlbumTrackIds(from: r.trackIds) : nil,
                    status: .ready,
                    durationSeconds: 0,
                    createdAt: r.parsedCreatedAt ?? Date(),
                    plays: r.plays ?? 0,
                    loves: r.loves ?? 0,
                    reposts: r.reposts ?? 0,
                    comments: r.comments ?? 0,
                    liked: r.liked ?? false,
                    reposted: r.reposted ?? false
                )
                switch kind {
                case .album:
                    t.coverArtUrl = r.coverImageUrl
                case .image:
                    t.imageUrls = r.images
                    t.coverArtUrl = r.coverImageUrl ?? r.images?.first
                case .video:
                    if let vKey = r.videoUrl {
                        let stripped = vKey.hasPrefix("videos/") ? String(vKey.dropFirst(7)) : vKey
                        t.videoURL = URL(string: "\(API.base)/api/videos/\(stripped)")
                    }
                    t.coverArtUrl = r.coverImageUrl
                case .text:
                    t.textBody = r.content
                    t.coverArtUrl = r.coverImageUrl
                default: break
                }
                rebuilt.append(t)
            }
        }

        // Keep local-only posts (no remotePostId yet — in-flight or offline)
        // and replace remotePostId-tracked ones with fresh server data.
        let localOnly = myTracks.filter { t in
            guard t.kind != .music else { return false }
            return t.remotePostId == nil
        }
        let musicTracks = myTracks.filter { $0.kind == .music }
        myTracks = musicTracks + localOnly + rebuilt
        myTracks.sort { $0.createdAt > $1.createdAt }
        rebuildFeed()
        persist()
    }

    private func defaultTitle(for kind: PostKind) -> String {
        switch kind {
        case .music: return "untitled"
        case .album: return "untitled album"
        case .image: return "image post"
        case .text: return "text post"
        case .video: return "video"
        }
    }

    private func localAlbumTrackIds(from rawTrackIds: [String]?) -> [UUID]? {
        guard let rawTrackIds else { return nil }
        let ids = rawTrackIds.compactMap { raw -> UUID? in
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            if let uuid = UUID(uuidString: cleaned) { return uuid }
            return uuidFromTrackId(cleaned)
        }
        return ids.isEmpty ? nil : orderedUnique(ids)
    }

    /// Publishes local-only image/text/video posts once the user is signed in.
    /// This closes the offline/partial-upload gap: local rows remain visible
    /// immediately, then become platform-backed as soon as their assets can be
    /// uploaded and a `/api/posts` row can be created.
    @MainActor
    private func syncPendingRemotePosts(token: String) async {
        let candidates = myTracks.filter { track in
            guard track.kind != .music, track.remotePostId == nil else { return false }
            return !deletedPostUUIDs.contains(track.id)
        }

        for track in candidates {
            guard let postId = await publishLocalPost(track, token: token) else { continue }
            update(id: track.id) { $0.remotePostId = postId }
        }
    }

    private func publishLocalPost(_ track: Track, token: String) async -> Int? {
        switch track.kind {
        case .text:
            return await Self.createRemotePost(
                kind: "text",
                title: track.title,
                content: track.displayText,
                token: token
            )
        case .image:
            guard let uploaded = await uploadImageURLsForPlatform(track.imageUrls ?? [], token: token),
                  !uploaded.isEmpty else { return nil }
            return await Self.createRemotePost(
                kind: "image",
                title: track.title,
                content: track.bio.isEmpty ? nil : track.bio,
                images: uploaded,
                coverImageUrl: uploaded.first,
                token: token
            )
        case .video:
            guard let videoURL = track.videoURL,
                  let videoKey = await uploadVideoURLForPlatform(videoURL, token: token) else { return nil }
            let cover = await uploadOptionalImageForPlatform(track.coverArtUrl, token: token)
            return await Self.createRemotePost(
                kind: "video",
                title: track.title,
                content: track.bio.isEmpty ? nil : track.bio,
                videoUrl: videoKey,
                coverImageUrl: cover,
                token: token
            )
        case .album:
            let cover = await uploadOptionalImageForPlatform(track.coverArtUrl, token: token)
            return await Self.createRemotePost(
                kind: "album",
                title: track.title,
                content: track.bio.isEmpty ? nil : track.bio,
                coverImageUrl: cover,
                trackIds: (track.albumTrackIds ?? []).map(\.uuidString),
                token: token
            )
        case .music:
            return nil
        }
    }

    private func uploadImageURLsForPlatform(_ rawURLs: [String], token: String) async -> [String]? {
        var uploaded: [String] = []
        for raw in rawURLs {
            if Self.isPlatformAssetPath(raw) {
                uploaded.append(raw)
                continue
            }
            guard let data = Self.dataFromLocalURLString(raw) else { return nil }
            do {
                uploaded.append(try await Self.uploadCoverImage(data, token: token))
            } catch {
                print("[Library] pending image upload failed: \(error)")
                return nil
            }
        }
        return uploaded
    }

    private func uploadOptionalImageForPlatform(_ raw: String?, token: String) async -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if Self.isPlatformAssetPath(raw) {
            return raw
        }
        guard let data = Self.dataFromLocalURLString(raw) else { return nil }
        return try? await Self.uploadCoverImage(data, token: token)
    }

    private func uploadVideoURLForPlatform(_ url: URL, token: String) async -> String? {
        do {
            let (signedURL, key) = try await Self.signVideoUpload(token: token)
            try await Self.putToS3(fileURL: url, signedURL: signedURL)
            return key
        } catch {
            print("[Library] pending video upload failed: \(error)")
            return nil
        }
    }

    private static func dataFromLocalURLString(_ raw: String) -> Data? {
        if raw.hasPrefix("file://"), let url = URL(string: raw) {
            return try? Data(contentsOf: url)
        }
        if FileManager.default.fileExists(atPath: raw) {
            return try? Data(contentsOf: URL(fileURLWithPath: raw))
        }
        return nil
    }

    private static func isPlatformAssetPath(_ raw: String) -> Bool {
        raw.hasPrefix("http://")
            || raw.hasPrefix("https://")
            || raw.hasPrefix("/api/images/")
    }

    // MARK: – Server post helpers

    /// POSTs a new TextPost record and returns its server id.
    private static func createRemotePost(
        kind: String,
        title: String,
        content: String? = nil,
        images: [String]? = nil,
        videoUrl: String? = nil,
        coverImageUrl: String? = nil,
        trackIds: [String]? = nil,
        token: String
    ) async -> Int? {
        var body: [String: Any] = ["kind": kind, "title": title]
        if let content { body["content"] = content }
        if let images  { body["images"]  = images  }
        if let videoUrl     { body["videoUrl"]     = videoUrl     }
        if let coverImageUrl { body["coverImageUrl"] = coverImageUrl }
        if let trackIds { body["trackIds"] = trackIds }
        struct Resp: Decodable { let id: Int }
        do {
            let data = try await API.post("/api/posts", body: body, token: token)
            return try JSONDecoder().decode(Resp.self, from: data).id
        } catch {
            print("[Library] createRemotePost failed: \(error)")
            return nil
        }
    }

    /// Gets a presigned S3 URL for a video upload. Returns (signedURL, s3Key).
    private static func signVideoUpload(token: String) async throws -> (URL, String) {
        struct Resp: Decodable { let signedUrl: String; let s3Key: String }
        let data = try await API.get("/api/upload/sign-video", token: token)
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let url = URL(string: resp.signedUrl) else { throw APIError.unknown }
        return (url, resp.s3Key)
    }

    /// Uploads a local file directly to an S3 presigned URL via HTTP PUT.
    private static func putToS3(fileURL: URL, signedURL: URL) async throws {
        var req = URLRequest(url: signedURL)
        req.httpMethod = "PUT"
        req.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: req, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server((response as? HTTPURLResponse)?.statusCode ?? -1, nil)
        }
    }

    // MARK: – Internal mutations

    private func update(id: UUID, _ mutate: (inout Track) -> Void) {
        if let idx = myTracks.firstIndex(where: { $0.id == id }) {
            mutate(&myTracks[idx])
        }
        if let idx = feed.firstIndex(where: { $0.id == id }) {
            mutate(&feed[idx])
        }
        rebuildFeed()
        persist()
    }

    private func updateProgress(id: UUID, progress: Double) {
        update(id: id) { $0.status = .separating(progress) }
    }

    private func markFailed(id: UUID, message: String) {
        update(id: id) { $0.status = .failed(message) }
    }

    private func rebuildFeed() {
        // The feed includes any post that's ready to display — music tracks
        // show stems, image/text/video posts always render once status is
        // ready. (Image / video flip to .ready after upload completes.)
        let displayable = myTracks.filter {
            if case .ready = $0.status { return true }
            // Text posts default to .ready; this shouldn't filter them out.
            if $0.kind == .text { return true }
            return false
        }
        feed = FeedRanking.rank(displayable)
    }

    // MARK: – Persistence

    private struct State: Codable {
        var profile: UserProfile
        var myTracks: [Track]
        var feed: [Track]
        var radioSessions: [RadioSession] = []
        // Tombstones + local edits live in library.json AND in the keychain
        // (mirrored on every persist). Keychain is the durable store across
        // app reinstalls; library.json is the fast session-level cache.
        // `decodeIfPresent` keeps older library.json files loadable.
        var deletedTrackIds: Set<String> = []
        var deletedPostUUIDs: Set<UUID> = []
        var deletedRemotePostIds: Set<Int> = []
        var localEdits: [String: LocalEdit] = [:]
        var followedAccounts: Set<FollowIdentity> = []

        enum CodingKeys: String, CodingKey {
            case profile, myTracks, feed, radioSessions
            case deletedTrackIds, deletedPostUUIDs, deletedRemotePostIds, localEdits, followedAccounts
        }

        init(profile: UserProfile, myTracks: [Track], feed: [Track],
             radioSessions: [RadioSession] = [],
             deletedTrackIds: Set<String> = [], deletedPostUUIDs: Set<UUID> = [],
             deletedRemotePostIds: Set<Int> = [],
             localEdits: [String: LocalEdit] = [:],
             followedAccounts: Set<FollowIdentity> = []) {
            self.profile = profile
            self.myTracks = myTracks
            self.feed = feed
            self.radioSessions = radioSessions
            self.deletedTrackIds = deletedTrackIds
            self.deletedPostUUIDs = deletedPostUUIDs
            self.deletedRemotePostIds = deletedRemotePostIds
            self.localEdits = localEdits
            self.followedAccounts = followedAccounts
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.profile = try c.decode(UserProfile.self, forKey: .profile)
            self.myTracks = try c.decode([Track].self, forKey: .myTracks)
            self.feed = try c.decode([Track].self, forKey: .feed)
            self.radioSessions = try c.decodeIfPresent([RadioSession].self, forKey: .radioSessions) ?? []
            self.deletedTrackIds = try c.decodeIfPresent(Set<String>.self, forKey: .deletedTrackIds) ?? []
            self.deletedPostUUIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .deletedPostUUIDs) ?? []
            self.deletedRemotePostIds = try c.decodeIfPresent(Set<Int>.self, forKey: .deletedRemotePostIds) ?? []
            self.localEdits = try c.decodeIfPresent([String: LocalEdit].self, forKey: .localEdits) ?? [:]
            self.followedAccounts = try c.decodeIfPresent(Set<FollowIdentity>.self, forKey: .followedAccounts) ?? []
        }
    }

    private static func defaultProfile() -> UserProfile {
        UserProfile(name: "you", handle: "you", bio: "")
    }

    private static func loadState(from url: URL) -> State {
        TrackLibraryPersistenceStore(url: url).load()
    }

    @MainActor
    private struct TrackLibraryPersistenceStore {
        let url: URL

        func load() -> State {
            loadState(from: url)
        }

        func save(_ state: State, durableBits: DurableLibraryBits) {
            if let data = try? JSONEncoder().encode(state) {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try? data.write(to: url, options: .atomic)
            }

            WWAVKeychain.setJSON(durableBits.deletedTrackIds, for: WWAVKeychainKeys.tombstones)
            WWAVKeychain.setJSON(durableBits.deletedRemotePostIds, for: WWAVKeychainKeys.postTombstones)
            WWAVKeychain.setJSON(durableBits.localEdits, for: WWAVKeychainKeys.localEdits)
            WWAVKeychain.setJSON(durableBits.followedAccounts, for: WWAVKeychainKeys.followedAccounts)
        }

        private func loadState(from url: URL) -> State {
            let fallback = State(
                profile: defaultProfile(),
                myTracks: [],
                feed: []
            )
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(State.self, from: data) else {
                return fallback
            }
            var cleaned = decoded
            cleaned.myTracks.removeAll { TrackLibrary.isTombstoned($0, in: decoded) }
            cleaned.feed.removeAll { TrackLibrary.isTombstoned($0, in: decoded) }
            return cleaned
        }
    }

    private struct DurableLibraryBits {
        var deletedTrackIds: Set<String>
        var deletedRemotePostIds: Set<Int>
        var localEdits: [String: LocalEdit]
        var followedAccounts: Set<FollowIdentity>
    }

    private static func legacyLoadState(from url: URL) -> State {
        let fallback = State(
            profile: defaultProfile(),
            myTracks: [],
            feed: []
        )
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(State.self, from: data) else {
            return fallback
        }
        // Defensive: if a tombstoned post somehow snuck back into the
        // persisted arrays (older build, partial write), scrub it now so
        // the in-memory state lines up with the tombstone contract.
        var cleaned = decoded
        cleaned.myTracks.removeAll { TrackLibrary.isTombstoned($0, in: decoded) }
        cleaned.feed.removeAll { TrackLibrary.isTombstoned($0, in: decoded) }
        return cleaned
    }

    private static func isTombstoned(_ t: Track, in state: State) -> Bool {
        if state.deletedPostUUIDs.contains(t.id) { return true }
        if let tid = t.remoteTrackId, state.deletedTrackIds.contains(tid) { return true }
        if let pid = t.remotePostId, state.deletedRemotePostIds.contains(pid) { return true }
        return false
    }

    private func persist() {
        let state = State(
            profile: profile, myTracks: myTracks, feed: feed,
            radioSessions: radioSessions,
            deletedTrackIds: deletedTrackIds, deletedPostUUIDs: deletedPostUUIDs,
            deletedRemotePostIds: deletedRemotePostIds,
            localEdits: localEdits,
            followedAccounts: followedAccounts
        )
        persistence.save(
            state,
            durableBits: DurableLibraryBits(
                deletedTrackIds: deletedTrackIds,
                deletedRemotePostIds: deletedRemotePostIds,
                localEdits: localEdits,
                followedAccounts: followedAccounts
            )
        )
    }
}

private extension String {
    var normalizedHandle: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }
}
