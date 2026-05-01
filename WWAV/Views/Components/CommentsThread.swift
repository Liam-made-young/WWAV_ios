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
                Text("no replies yet — be first.")
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
        .task { await loadComments() }
    }

    // MARK: – Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    prompt: Text(replyingTo == nil ? "post your reply" : "tweet your reply…")
                        .foregroundStyle(theme.muted)
                )
                .font(.wwav(13, weight: .light, italic: true))
                .foregroundStyle(theme.ink)
                .submitLabel(.send)
                .onSubmit { Task { await submit() } }
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
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || posting)
                .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
        }
    }

    // MARK: – Tree build

    struct Node: Equatable {
        let comment: WWAVComment
        let children: [Node]
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
        guard let uploadId = track.userUploadId else {
            loading = false
            return
        }
        loading = true
        defer { loading = false }
        do {
            let data = try await API.get("/api/social/comments/\(uploadId)?type=upload")
            let decoded = try JSONDecoder().decode([WWAVComment].self, from: data)
            comments = decoded
        } catch {
            print("[CommentsThread] load failed: \(error)")
        }
    }

    @MainActor
    private func submit() async {
        guard let token = auth.token,
              let uploadId = track.userUploadId else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        posting = true
        defer { posting = false }

        var body: [String: Any] = ["text": trimmed]
        if let target = replyingTo { body["parentId"] = target.id }

        do {
            let data = try await API.post(
                "/api/social/comment/\(uploadId)?type=upload",
                body: body, token: token
            )
            let posted = try JSONDecoder().decode(WWAVComment.self, from: data)
            comments.append(posted)
            draft = ""
            replyingTo = nil
        } catch {
            print("[CommentsThread] post failed: \(error)")
        }
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
