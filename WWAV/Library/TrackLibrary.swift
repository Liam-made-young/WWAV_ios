import Foundation
import Combine

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

    /// Tombstone set of every server-side trackId the user has deleted from
    /// this app. Persists across launches AND across app reinstalls (via
    /// the keychain — Application Support gets wiped when the app is
    /// uninstalled, so library.json alone is not enough). A server refresh
    /// can never resurrect a row the user explicitly removed.
    @Published private(set) var deletedTrackIds: Set<String> = []
    /// Tombstone set for non-music posts (image/text/video) by their local
    /// UUID — those don't have a server-side trackId.
    @Published private(set) var deletedPostUUIDs: Set<UUID> = []
    /// Per-track local edits keyed by remote trackId. Title / bio / cover
    /// changes the user makes on this device are written here AND mirrored
    /// to the keychain, so they survive an app reinstall even if the
    /// server-side metadata PUT silently failed. On every refresh we
    /// overlay these onto the server response — local edits always win.
    @Published private(set) var localEdits: [String: LocalEdit] = [:]

    let storage: StorageService
    let separator: StemSeparationService

    private let stateURL: URL

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

        // One-time wipe of the pre-server-sync local library so old
        // half-broken/duplicate tracks don't haunt the feed forever. After
        // this, the server is the source of truth — `refresh(token:)` rebuilds
        // myTracks on every launch, and uploads round-trip through the cloud.
        let migrationKey = "wwav.didWipeLocalLibrary.v1"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            try? FileManager.default.removeItem(at: stateURL)
            UserDefaults.standard.set(true, forKey: migrationKey)
        }

        let state = TrackLibrary.loadState(from: stateURL)
        self.profile = state.profile
        self.myTracks = state.myTracks
        self.feed = state.feed
        self.deletedTrackIds = state.deletedTrackIds
        self.deletedPostUUIDs = state.deletedPostUUIDs
        self.localEdits = state.localEdits

        // Keychain is the durable source of truth for tombstones + edits
        // because it's the only thing on iOS that survives an app reinstall.
        // Union/merge with whatever was in library.json so the most
        // permissive set wins — a deletion stays a deletion, an edit stays
        // an edit, regardless of which store was around.
        if let restoredTombstones = WWAVKeychain.json(Set<String>.self, for: WWAVKeychainKeys.tombstones) {
            self.deletedTrackIds.formUnion(restoredTombstones)
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

        // Defensive: scrub anything that survived in myTracks/feed despite
        // matching a tombstone we just restored from keychain.
        self.myTracks.removeAll { t in
            if self.deletedPostUUIDs.contains(t.id) { return true }
            if let tid = t.remoteTrackId, self.deletedTrackIds.contains(tid) { return true }
            return false
        }
        self.feed.removeAll { t in
            if self.deletedPostUUIDs.contains(t.id) { return true }
            if let tid = t.remoteTrackId, self.deletedTrackIds.contains(tid) { return true }
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

    var trackCount: Int { myTracks.count }
    var totalPlays: Int { myTracks.reduce(0) { $0 + $1.plays } }
    var totalLoves: Int { myTracks.reduce(0) { $0 + $1.loves } }

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
        profile.name = remote.username
        profile.handle = remote.username
        if let bio = remote.bio, !bio.isEmpty { profile.bio = bio }
        persist()
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
        }
        return id
    }

    /// Creates a text-only post. Stays client-side until a backend endpoint exists.
    @discardableResult
    func createTextPost(title: String, body: String) -> UUID {
        let id = UUID()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let track = Track(
            id: id,
            kind: .text,
            title: trimmedTitle.isEmpty ? "text post" : trimmedTitle,
            artist: profile.name,
            handle: profile.handle,
            bio: "",
            textBody: body,
            status: .ready,
            durationSeconds: 0
        )
        myTracks.insert(track, at: 0)
        rebuildFeed()
        persist()
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
            bio: caption,
            status: .separating(0.0),
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
                let ext = videoURL.pathExtension.isEmpty ? "mp4" : videoURL.pathExtension
                let key = "uploads/\(id.uuidString)/video.\(ext)"
                let cached = try await self.storage.putFile(
                    at: videoURL, key: key, contentType: "video/mp4"
                )
                self.update(id: id) {
                    $0.videoURL = cached
                    $0.sourceObjectKey = key
                    $0.status = .ready
                }

                if let img = coverImage, let token {
                    do {
                        let coverPath = try await Self.uploadCoverImage(img, token: token)
                        self.update(id: id) { $0.coverArtUrl = coverPath }
                    } catch {
                        print("[Library] video cover upload failed: \(error)")
                        // Cache the cover locally if upload failed.
                        let coverKey = "uploads/\(id.uuidString)/cover.jpg"
                        if let local = try? await self.storage.put(img, key: coverKey, contentType: "image/jpeg") {
                            self.update(id: id) { $0.coverArtUrl = local.absoluteString }
                        }
                    }
                }
            } catch {
                self.markFailed(id: id, message: error.localizedDescription)
            }
        }
        return id
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

        // Persist the edit locally + keychain BEFORE the network call. That
        // way even if the PUT fails (or the user kills the app mid-flight),
        // the change still wins on next refresh and survives reinstall.
        if let track = myTracks.first(where: { $0.id == id }),
           track.kind == .music,
           let trackId = track.remoteTrackId {
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
            _ = track // silence unused
        }
    }

    /// Replaces the video file for a `.video` post.
    func replaceVideo(id: UUID, videoURL: URL) {
        guard let track = myTracks.first(where: { $0.id == id }), track.kind == .video else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let scoped = videoURL.startAccessingSecurityScopedResource()
                defer { if scoped { videoURL.stopAccessingSecurityScopedResource() } }
                let ext = videoURL.pathExtension.isEmpty ? "mp4" : videoURL.pathExtension
                let key = "uploads/\(id.uuidString)/video_\(Int(Date().timeIntervalSince1970)).\(ext)"
                let cached = try await self.storage.putFile(
                    at: videoURL, key: key, contentType: "video/mp4"
                )
                self.update(id: id) {
                    $0.videoURL = cached
                    $0.sourceObjectKey = key
                }
            } catch {
                print("[Library] video replace failed: \(error)")
            }
            _ = track
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
            // Always tombstone the local UUID too — for non-music posts it
            // is the only identifier, and for music posts it's a cheap
            // belt-and-braces guard against trackId-less duplicates.
            deletedPostUUIDs.insert(target.id)

            // Fire-and-forget server delete for music uploads. Whether or
            // not this succeeds, the tombstone keeps iOS clean.
            if target.kind == .music,
               let token,
               let uploadId = target.userUploadId {
                Task {
                    await Self.deleteServerUpload(uploadId: uploadId, token: token)
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

    func incrementPlays(of id: UUID) {
        update(id: id) { $0.plays += 1 }
    }

    // MARK: – Social actions

    /// Toggles a like for `track` on the server and reflects the new state
    /// locally. Optimistic — updates the UI immediately, then reverts on
    /// network failure so the heart never gets stuck "filled" if the
    /// request didn't actually go through.
    @MainActor
    func toggleLike(track: Track, token: String?) async {
        // Local-only posts (image/text/video without a userUploadId) just
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
    // The mi-wwav.com backend is the source of truth for uploaded music tracks.
    // Image/text/video posts are local-only for now and survive refresh.
    // `refresh(token:)` fetches `/api/user/uploads` and reconciles with the
    // local cache so a fresh build on a new device immediately sees your
    // upload history.

    /// Pulls the user's uploads from the server and merges with local state.
    /// - Local copies of in-flight (`.separating`) uploads are preserved so a
    ///   refresh during a pending separation doesn't overwrite progress.
    /// - Local copies of stem files (downloaded for playback) survive refresh.
    /// - Local non-music posts (image/text/video) are preserved verbatim.
    /// - Remote uploads not yet seen locally are appended at the top.
    @MainActor
    func refresh(token: String?) async {
        guard let token else { return }
        do {
            let data = try await API.get("/api/user/uploads", token: token)
            let remote = try JSONDecoder().decode([RemoteUpload].self, from: data)
            applyRemote(remote, token: token)
        } catch {
            print("[Library] refresh failed: \(error)")
        }
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

    private func applyRemote(_ remote: [RemoteUpload], token: String?) {
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

            let trackStatus: TrackStatus
            switch r.status {
            case "ready":      trackStatus = .ready
            case "processing": trackStatus = .separating(0.5)
            case "failed":     trackStatus = .failed("server reported failed")
            default:           trackStatus = .separating(0.0)
            }

            // Skip non-ready server rows unless this device is mid-upload
            // for the same trackId. This is what hides web-app uploads
            // that never finished separation — the broken-link case.
            if r.status != "ready" {
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
                existing.stemObjectKeys = stemKeys

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
                let new = Track(
                    id: id,
                    kind: .music,
                    title: cleanedDisplayTitle(from: r.originalName),
                    artist: profile.name,
                    handle: profile.handle,
                    bio: "",
                    sourceURL: nil,
                    sourceObjectKey: "stems/\(r.trackId)",
                    remoteTrackId: r.trackId,
                    userUploadId: r.id,
                    coverArtUrl: r.coverArtUrl,
                    stems: nil,
                    stemObjectKeys: stemKeys,
                    status: trackStatus,
                    durationSeconds: 0,
                    createdAt: r.parsedCreatedAt ?? Date()
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
            if let editedCover = edit.coverArtUrl, !editedCover.isEmpty,
               (rebuilt[i].coverArtUrl ?? "") != "" {
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

    // MARK: – Internal mutations

    private func update(id: UUID, _ mutate: (inout Track) -> Void) {
        if let idx = myTracks.firstIndex(where: { $0.id == id }) {
            mutate(&myTracks[idx])
        }
        if let idx = feed.firstIndex(where: { $0.id == id }) {
            mutate(&feed[idx])
        }
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
        feed = myTracks.filter {
            if case .ready = $0.status { return true }
            // Text posts default to .ready; this shouldn't filter them out.
            if $0.kind == .text { return true }
            return false
        }
    }

    // MARK: – Persistence

    private struct State: Codable {
        var profile: UserProfile
        var myTracks: [Track]
        var feed: [Track]
        // Tombstones + local edits live in library.json AND in the keychain
        // (mirrored on every persist). Keychain is the durable store across
        // app reinstalls; library.json is the fast session-level cache.
        // `decodeIfPresent` keeps older library.json files loadable.
        var deletedTrackIds: Set<String> = []
        var deletedPostUUIDs: Set<UUID> = []
        var localEdits: [String: LocalEdit] = [:]

        enum CodingKeys: String, CodingKey {
            case profile, myTracks, feed
            case deletedTrackIds, deletedPostUUIDs, localEdits
        }

        init(profile: UserProfile, myTracks: [Track], feed: [Track],
             deletedTrackIds: Set<String> = [], deletedPostUUIDs: Set<UUID> = [],
             localEdits: [String: LocalEdit] = [:]) {
            self.profile = profile
            self.myTracks = myTracks
            self.feed = feed
            self.deletedTrackIds = deletedTrackIds
            self.deletedPostUUIDs = deletedPostUUIDs
            self.localEdits = localEdits
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.profile = try c.decode(UserProfile.self, forKey: .profile)
            self.myTracks = try c.decode([Track].self, forKey: .myTracks)
            self.feed = try c.decode([Track].self, forKey: .feed)
            self.deletedTrackIds = try c.decodeIfPresent(Set<String>.self, forKey: .deletedTrackIds) ?? []
            self.deletedPostUUIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .deletedPostUUIDs) ?? []
            self.localEdits = try c.decodeIfPresent([String: LocalEdit].self, forKey: .localEdits) ?? [:]
        }
    }

    private static func defaultProfile() -> UserProfile {
        UserProfile(name: "you", handle: "you", bio: "")
    }

    private static func loadState(from url: URL) -> State {
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
        return false
    }

    private func persist() {
        let state = State(
            profile: profile, myTracks: myTracks, feed: feed,
            deletedTrackIds: deletedTrackIds, deletedPostUUIDs: deletedPostUUIDs,
            localEdits: localEdits
        )
        if let data = try? JSONEncoder().encode(state) {
            try? FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: stateURL, options: .atomic)
        }

        // Mirror the durable bits into the keychain so they survive an
        // app reinstall. Application Support gets wiped on uninstall;
        // keychain entries (kSecAttrAccessibleAfterFirstUnlock) don't.
        WWAVKeychain.setJSON(deletedTrackIds, for: WWAVKeychainKeys.tombstones)
        WWAVKeychain.setJSON(localEdits, for: WWAVKeychainKeys.localEdits)
    }
}
