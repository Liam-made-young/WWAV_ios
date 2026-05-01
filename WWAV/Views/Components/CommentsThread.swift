import SwiftUI

/// Inline Twitter-style comment thread for a single track. Lives directly
/// under a feed card — no modal. Loads on first appearance, lets the user
/// reply to any comment, and stays scoped to its track so multiple feed
/// items can have independent threads expanded at the same time.
///
/// Comments are arranged into a `Node` tree by `parentId`. Until the
/// backend `Comment.parentId` column ships, every reply lands at the top
/// level — when it ships, the recursive renderer surfaces real threads
/// with no iOS-side changes.
struct CommentsThread: View {
    let track: Track

    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme

    @State private var comments: [WWAVComment] = []
    @State private var loading: Bool = true
    @State private var draft: String = ""
    @State private var posting: Bool = false
    @State private var replyingTo: WWAVComment? = nil
    @State private var resolvedEndpoint: CommentEndpoint? = nil
    @State private var repliesUnavailable: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Visual divider so the thread is clearly attached to the post above.
            Rectangle()
                .fill(theme.muted.opacity(0.15))
                .frame(height: 1)
                .padding(.bottom, 8)

            if loading && comments.isEmpty {
                HStack {
                    ProgressView().tint(theme.muted)
                    Text("loading replies…")
                        .font(.wwav(11, weight: .light, italic: true))
                        .foregroundStyle(theme.muted)
                }
                .padding(.vertical, 6)
            } else if comments.isEmpty {
                Text(emptyMessage)
                    .font(.wwav(12, weight: .light, italic: true))
                    .foregroundStyle(theme.muted)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(threadedNodes, id: \.comment.id) { node in
                        NodeRow(node: node, depth: 0,
                                replyingTo: $replyingTo, theme: theme)
                    }
                }
            }

            composer.padding(.top, 6)
        }
        .task(id: commentTaskID) { await loadComments() }
    }

    // MARK: – Composer

    private var composer: some View {
        let repliesReady = !commentEndpoints.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            if let target = replyingTo {
                HStack(spacing: 6) {
                    Text("replying to @\(target.displayName)")
                        .font(.wwav(11, weight: .light, italic: true))
                        .foregroundStyle(theme.muted)
                    Spacer()
                    Button {
                        replyingTo = nil
                    } label: {
                        Text("cancel")
                            .font(.wwav(11, weight: .light, italic: true))
                            .foregroundStyle(theme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                ProfileAvatar(url: auth.user?.profilePictureURL, size: 26)
                TextField(
                    "",
                    text: $draft,
                    prompt: Text(replyPrompt(repliesReady: repliesReady))
                        .foregroundStyle(theme.muted)
                )
                .font(.wwav(13, weight: .light, italic: true))
                .foregroundStyle(theme.ink)
                .submitLabel(.send)
                .onSubmit { Task { await submit() } }
                .disabled(!repliesReady)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.sand.opacity(0.5)))
                .overlay(Capsule().stroke(theme.muted.opacity(0.20), lineWidth: 1))

                Button {
                    Task { await submit() }
                } label: {
                    Text(posting ? "…" : "post")
                        .font(.wwav(11, weight: .regular, italic: true))
                        .tracking(1.5)
                        .foregroundStyle(theme.glow)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(
                            Capsule().fill(LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top, endPoint: .bottom
                            ))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!repliesReady || draft.trimmingCharacters(in: .whitespaces).isEmpty || posting)
                .opacity(!repliesReady || draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
        }
    }

    // MARK: – Tree build

    struct Node: Equatable {
        let comment: WWAVComment
        let children: [Node]
    }

    private struct CommentEndpoint: Equatable {
        let label: String
        let commentsPath: String
        let postPath: String
    }

    private struct CommentListEnvelope: Decodable {
        let values: [WWAVComment]

        enum CodingKeys: String, CodingKey {
            case comments, data, results, items, replies
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            for key in [CodingKeys.comments, .data, .results, .items, .replies] {
                if let values = try? c.decode([WWAVComment].self, forKey: key) {
                    self.values = values
                    return
                }
                if let nested = try? c.decode(CommentListEnvelope.self, forKey: key) {
                    self.values = nested.values
                    return
                }
            }
            self.values = []
        }
    }

    private struct CommentEnvelope: Decodable {
        let value: WWAVComment?

        enum CodingKeys: String, CodingKey {
            case comment, data, result, item, reply
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = (try? c.decode(WWAVComment.self, forKey: .comment))
                ?? (try? c.decode(WWAVComment.self, forKey: .data))
                ?? (try? c.decode(WWAVComment.self, forKey: .result))
                ?? (try? c.decode(WWAVComment.self, forKey: .item))
                ?? (try? c.decode(WWAVComment.self, forKey: .reply))
        }
    }

    private var commentEndpoints: [CommentEndpoint] {
        if track.kind == .music {
            var endpoints: [CommentEndpoint] = []
            if let uploadId = track.userUploadId {
                endpoints.append(
                    CommentEndpoint(
                        label: "upload",
                        commentsPath: "/api/social/comments/\(uploadId)?type=upload",
                        postPath: "/api/social/comment/\(uploadId)?type=upload"
                    )
                )
            }
            if let publishedId = track.publishedTrackId {
                endpoints.append(
                    CommentEndpoint(
                        label: "published",
                        commentsPath: "/api/social/comments/\(publishedId)?type=published",
                        postPath: "/api/social/comment/\(publishedId)?type=published"
                    )
                )
            }
            if !endpoints.isEmpty { return endpoints }
        }

        if let uploadId = track.userUploadId {
            return [
                CommentEndpoint(
                    label: "upload",
                    commentsPath: "/api/social/comments/\(uploadId)?type=upload",
                    postPath: "/api/social/comment/\(uploadId)?type=upload"
                ),
            ]
        }
        guard let postId = track.remotePostId else { return [] }

        var endpoints: [CommentEndpoint] = [
            CommentEndpoint(
                label: "post-social",
                commentsPath: "/api/posts/\(postId)/social",
                postPath: "/api/social/comment/\(postId)?type=post"
            ),
            CommentEndpoint(
                label: "posts",
                commentsPath: "/api/posts/\(postId)/comments",
                postPath: "/api/posts/\(postId)/comments"
            ),
            CommentEndpoint(
                label: "post",
                commentsPath: "/api/post/\(postId)/comments",
                postPath: "/api/post/\(postId)/comments"
            ),
            CommentEndpoint(
                label: "comments-post",
                commentsPath: "/api/comments/post/\(postId)",
                postPath: "/api/comments/post/\(postId)"
            ),
            CommentEndpoint(
                label: "text-posts",
                commentsPath: "/api/text-posts/\(postId)/comments",
                postPath: "/api/text-posts/\(postId)/comments"
            ),
        ]
        for type in ["post", "textpost", "textPost"] {
            endpoints.append(
                CommentEndpoint(
                    label: "social-\(type)",
                    commentsPath: "/api/social/comments/\(postId)?type=\(type)",
                    postPath: "/api/social/comment/\(postId)?type=\(type)"
                )
            )
        }
        return endpoints
    }

    private var commentTaskID: String {
        "\(track.kind.rawValue)-\(track.userUploadId ?? -1)-\(track.publishedTrackId ?? -1)-\(track.remotePostId ?? -1)"
    }

    private func replyPrompt(repliesReady: Bool) -> String {
        guard repliesReady else { return "syncing replies…" }
        return replyingTo == nil ? "post your reply" : "tweet your reply…"
    }

    private var emptyMessage: String {
        guard !commentEndpoints.isEmpty else { return "replies available after sync." }
        return repliesUnavailable ? "no replies loaded yet — try replying." : "no replies yet — be first."
    }

    private var threadedNodes: [Node] {
        var byParent: [Int?: [WWAVComment]] = [:]
        for c in comments {
            byParent[c.parentId, default: []].append(c)
        }
        func build(parent: Int?) -> [Node] {
            (byParent[parent] ?? []).map {
                Node(comment: $0, children: build(parent: $0.id))
            }
        }
        return build(parent: nil)
    }

    // MARK: – Network

    @MainActor
    private func loadComments() async {
        let endpoints = commentEndpoints
        guard !endpoints.isEmpty else {
            loading = false
            repliesUnavailable = false
            return
        }
        loading = true
        repliesUnavailable = false
        defer { loading = false }
        for endpoint in endpoints {
            do {
                let data = try await API.get(endpoint.commentsPath, token: auth.token)
                let decoded = try Self.decodeCommentList(data)
                resolvedEndpoint = endpoint
                comments = decoded
                return
            } catch {
                print("[CommentsThread] load failed for \(endpoint.label): \(error)")
            }
        }
        repliesUnavailable = true
    }

    @MainActor
    private func submit() async {
        guard let token = auth.token else { return }
        let endpoints = resolvedEndpoint.map { [$0] } ?? commentEndpoints
        guard !endpoints.isEmpty else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        posting = true
        defer { posting = false }

        let parentId = replyingTo?.id

        for endpoint in endpoints {
            for key in ["text", "content", "body", "comment"] {
                var body: [String: Any] = [key: trimmed]
                if let parentId {
                    body["parentId"] = parentId
                    body["parent_id"] = parentId
                }

                do {
                    let data = try await API.post(endpoint.postPath, body: body, token: token)
                    let posted = Self.decodePostedComment(data)
                        ?? localComment(text: trimmed, parentId: parentId)
                    resolvedEndpoint = endpoint
                    repliesUnavailable = false
                    comments.append(posted)
                    draft = ""
                    replyingTo = nil
                    return
                } catch {
                    print("[CommentsThread] post failed for \(endpoint.label)/\(key): \(error)")
                }
            }
        }
    }

    private static func decodeCommentList(_ data: Data) throws -> [WWAVComment] {
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        if let comments = try? decoder.decode([WWAVComment].self, from: data) {
            return comments
        }
        return try decoder.decode(CommentListEnvelope.self, from: data).values
    }

    private static func decodePostedComment(_ data: Data) -> WWAVComment? {
        guard !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        if let comment = try? decoder.decode(WWAVComment.self, from: data) {
            return comment
        }
        if let wrapped = try? decoder.decode(CommentEnvelope.self, from: data) {
            return wrapped.value
        }
        if let list = try? decodeCommentList(data) {
            return list.first
        }
        return nil
    }

    private func localComment(text: String, parentId: Int?) -> WWAVComment {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let localId = -Int(Date().timeIntervalSince1970 * 1000)
        return WWAVComment(
            id: localId,
            text: text,
            userId: auth.user?.id,
            username: auth.user?.username,
            profilePicture: auth.user?.profilePicture,
            createdAt: stamp,
            parentId: parentId
        )
    }
}

private struct NodeRow: View {
    let node: CommentsThread.Node
    let depth: Int
    @Binding var replyingTo: WWAVComment?
    let theme: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                ProfileAvatar(url: node.comment.profilePictureURL, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("@\(node.comment.displayName)")
                            .font(.wwav(12, weight: .medium))
                            .foregroundStyle(theme.ink)
                        Text(node.comment.timeAgo)
                            .font(.wwav(10, weight: .light))
                            .foregroundStyle(theme.muted)
                    }
                    Text(node.comment.text)
                        .font(.wwav(13, weight: .light))
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        replyingTo = node.comment
                    } label: {
                        Text("reply")
                            .font(.wwav(10, weight: .light, italic: true))
                            .foregroundStyle(theme.muted)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 18)
            .padding(.vertical, 6)

            ForEach(node.children, id: \.comment.id) { child in
                NodeRow(node: child, depth: depth + 1,
                        replyingTo: $replyingTo, theme: theme)
            }
        }
    }
}
