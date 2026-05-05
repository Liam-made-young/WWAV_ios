import SwiftUI
import UIKit
import PhotosUI

private let feedTabLabels = ["for you", "following", "friends"]

struct HomeView: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var auth: AuthManager
    @Environment(\.theme) private var theme
    @State private var feedTab: Int = 0
    @State private var showingSearch: Bool = false
    @State private var showingRadioLive: Bool = false
    @State private var visibleFeedLimit: Int = Self.initialFeedWindow
    @State private var showingStorySourceDialog: Bool = false
    @State private var storyCameraOpen: Bool = false
    @State private var storyLibraryOpen: Bool = false
    @State private var storyLibraryItem: PhotosPickerItem?
    @State private var viewingStoryGroup: StoryGroup?

    private static let initialFeedWindow = 18
    private static let feedWindowIncrement = 12

    private var currentFeed: [Track] {
        library.feed(for: feedTab)
    }

    private var groupedStories: [StoryGroup] {
        var groupOrder: [String] = []
        var groupMap: [String: (handle: String, authorName: String, pictureURL: URL?, stories: [WWAVStory])] = [:]
        for story in library.activeStories {
            let key = story.handle.lowercased()
            if groupMap[key] == nil {
                groupOrder.append(key)
                groupMap[key] = (story.handle, story.authorName, story.authorProfilePictureURL, [])
            }
            groupMap[key]?.stories.append(story)
        }
        return groupOrder.compactMap { key -> StoryGroup? in
            guard var entry = groupMap[key] else { return nil }
            entry.stories.reverse() // chronological order for sequential viewing
            return StoryGroup(
                id: key,
                handle: entry.handle,
                authorName: entry.authorName,
                authorProfilePictureURL: entry.pictureURL,
                stories: entry.stories
            )
        }
    }

    var body: some View {
        ZStack {
            theme.pageRadial.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                storiesRail
                tabPicker
                ScrollViewReader { proxy in
                    ScrollView {
                        let feed = currentFeed
                        let visibleFeed = Array(feed.prefix(visibleFeedLimit))
                        LazyVStack(spacing: 0) {
                            Color.clear
                                .frame(height: 0)
                                .id("feedTop")
                            FeedComposerCard()
                                .padding(.horizontal, 24)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                            SoftRule()

                            if feed.isEmpty {
                                EmptyState(
                                    title: emptyTitle,
                                    body: emptyBody
                                )
                                .frame(minHeight: 320)
                            } else {
                                ForEach(Array(visibleFeed.enumerated()), id: \.element.id) { idx, track in
                                    FeedItemView(track: track, accent: idx == 0) {
                                        nav.openPost(track, in: library, with: player)
                                    }
                                    if idx < visibleFeed.count - 1 {
                                        SoftRule()
                                    }
                                }
                                if visibleFeed.count < feed.count {
                                    FeedPageSentinel {
                                        showMoreFeedItems(total: feed.count)
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .refreshable {
                        visibleFeedLimit = Self.initialFeedWindow
                        await library.refresh(token: auth.token, force: true)
                    }
                    .onChange(of: nav.homeFeedPing) { _, _ in
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                            proxy.scrollTo("feedTop", anchor: .top)
                        }
                        visibleFeedLimit = Self.initialFeedWindow
                        Task { await library.refresh(token: auth.token, force: true) }
                    }
                }
            }
        }
        .task(id: auth.token) { await library.refresh(token: auth.token) }
        .onChange(of: feedTab) { _, _ in
            visibleFeedLimit = Self.initialFeedWindow
        }
        .fullScreenCover(item: $nav.imageViewerPost) { post in
            FullscreenImageViewer(post: post)
        }
        .fullScreenCover(item: $viewingStoryGroup) { group in
            GroupedStoryViewer(group: group)
        }
        .fullScreenCover(isPresented: $storyCameraOpen) {
            WWAVCameraImagePicker { image in
                createStory(from: image)
            }
            .ignoresSafeArea()
        }
        .photosPicker(
            isPresented: $storyLibraryOpen,
            selection: $storyLibraryItem,
            matching: .images,
            preferredItemEncoding: .compatible,
            photoLibrary: .shared()
        )
        .confirmationDialog("post story", isPresented: $showingStorySourceDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("open camera") {
                    storyCameraOpen = true
                }
            }
            Button("open camera roll") {
                storyLibraryOpen = true
            }
            Button("cancel", role: .cancel) {}
        }
        .onChange(of: storyLibraryItem) { _, item in
            Task { await loadStoryImage(from: item) }
        }
        .sheet(isPresented: $showingSearch) {
            SearchView()
        }
        .sheet(isPresented: $showingRadioLive) {
            RadioLiveFeedSheet()
        }
    }

    private var emptyTitle: String {
        switch feedTab {
        case 1: return "no follows yet"
        case 2: return "no friends yet"
        default: return "no waves yet"
        }
    }

    private var emptyBody: String {
        switch feedTab {
        case 1: return "follow artists from profiles or the feed to build this tab."
        case 2: return "liked, remixed, followed, and your own posts collect here."
        default: return "pull down to refresh, or post from here."
        }
    }

    private var header: some View {
        HStack {
            Image("WWAVLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
                .accessibilityLabel("WWAV")
            Spacer()
            Button {
                showingSearch = true
            } label: {
                headerButton(icon: "magnifyingglass", label: "search")
            }
            .buttonStyle(.plain)
            Button {
                showingRadioLive = true
            } label: {
                headerButton(icon: "dot.radiowaves.left.and.right", label: "live")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    private var storiesRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                StoryPostButton(
                    profilePictureURL: Track.resolveImageURL(library.profile.profilePicture),
                    handle: library.profile.handle
                ) {
                    showingStorySourceDialog = true
                }

                ForEach(groupedStories) { group in
                    StoryBubble(group: group) {
                        viewingStoryGroup = group
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .padding(.bottom, 4)
    }

    private func headerButton(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(.wwav(10, weight: .medium, italic: true))
                .tracking(1.3)
        }
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Capsule().fill(theme.sand.opacity(WWAVOpacity.firm)))
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [theme.glow.opacity(0.45), theme.muted.opacity(WWAVOpacity.soft)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        )
    }

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { feedTab = i }
                } label: {
                    VStack(spacing: 6) {
                        Text(feedTabLabels[i])
                            .font(.wwav(13, weight: feedTab == i ? .medium : .light, italic: true))
                            .foregroundStyle(feedTab == i ? theme.ink : theme.muted)
                            .background(
                                Group {
                                    if feedTab == i {
                                        Capsule()
                                            .fill(theme.accent.opacity(0.18))
                                            .frame(height: 6)
                                            .blur(radius: 8)
                                            .offset(y: 4)
                                    }
                                }
                            )
                        Rectangle()
                            .fill(feedTab == i ? theme.accent : theme.muted.opacity(0.15))
                            .frame(height: feedTab == i ? 2 : 1)
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
    }

    private func showMoreFeedItems(total: Int) {
        guard visibleFeedLimit < total else { return }
        visibleFeedLimit = min(total, visibleFeedLimit + Self.feedWindowIncrement)
    }

    private func createStory(from image: UIImage) {
        let data = image.jpegData(compressionQuality: 0.86) ?? Data()
        guard !data.isEmpty else { return }
        library.createStory(image: data, token: auth.token)
    }

    private func loadStoryImage(from item: PhotosPickerItem?) async {
        guard let item else { return }
        var selectedImage: UIImage?
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            selectedImage = image
        }
        await MainActor.run {
            if let selectedImage {
                createStory(from: selectedImage)
            }
            storyLibraryItem = nil
        }
    }
}

private let feedComposerKinds: [PostKind] = [.text, .music, .image, .video]

private struct FeedPageSentinel: View {
    let onAppear: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ProgressView()
            .tint(theme.accent)
            .scaleEffect(0.82)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .onAppear(perform: onAppear)
    }
}

private struct StoryGroup: Identifiable {
    let id: String       // lowercased handle — one group per user
    let handle: String
    let authorName: String
    let authorProfilePictureURL: URL?
    let stories: [WWAVStory]  // chronological order (oldest first)
}

private struct StoryPostButton: View {
    let profilePictureURL: URL?
    let handle: String
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    ProfileAvatar(url: profilePictureURL, size: 62)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [theme.glow.opacity(0.78), theme.accent.opacity(0.58)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )

                    ZStack {
                        Circle().fill(theme.accent)
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.glow)
                    }
                    .frame(width: 23, height: 23)
                    .overlay(Circle().stroke(theme.sand, lineWidth: 2))
                    .offset(x: 2, y: 2)
                }
                Text(handle.normalizedStoryHandle.isEmpty ? "you" : "@\(handle.normalizedStoryHandle)")
                    .font(.wwav(10, weight: .light))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .frame(width: 70)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Post story")
    }
}

private struct StoryBubble: View {
    let group: StoryGroup
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ProfileAvatar(url: group.authorProfilePictureURL, size: 62)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [theme.accent, theme.clayDeep, theme.glow.opacity(0.72)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2.5
                            )
                    )

                Text(group.handle.normalizedStoryHandle.isEmpty ? "..." : "@\(group.handle.normalizedStoryHandle)")
                    .font(.wwav(10, weight: .light))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .frame(width: 70)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct GroupedStoryViewer: View {
    let group: StoryGroup

    @State private var currentIndex: Int = 0
    @State private var storyToken: UUID = .init()
    @State private var progress: CGFloat = 0
    @State private var showingDeleteConfirmation: Bool = false

    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private let storyDuration: Double = 5.0

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if let story = currentStory {
                CachedAsyncImage(url: story.imageURL, contentMode: .fit) {
                    ProgressView().tint(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            }

            // Scrim so top UI is legible
            LinearGradient(
                colors: [.black.opacity(0.52), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 160)
            .frame(maxWidth: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            // Tap zones: left half = previous, right half = next
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { goToPrevious() }
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { goToNext() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            // Top UI
            VStack(spacing: 10) {
                // Progress bars — one segment per story
                HStack(spacing: 4) {
                    ForEach(0..<group.stories.count, id: \.self) { i in
                        StoryProgressSegment(progress: segmentProgress(for: i))
                    }
                }
                .padding(.horizontal, 14)

                // Author header
                HStack(spacing: 10) {
                    ProfileAvatar(url: group.authorProfilePictureURL, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.authorName)
                            .font(.wwav(13, weight: .medium))
                            .foregroundStyle(.white)
                        if !group.handle.normalizedStoryHandle.isEmpty {
                            Text("@\(group.handle.normalizedStoryHandle)")
                                .font(.wwav(10, weight: .light))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                    Spacer()
                    if let story = currentStory,
                       library.isAuthoredByCurrentUser(story) {
                        Button {
                            showingDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(.white.opacity(0.16)))
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 12)
        }
        .task(id: storyToken) {
            withAnimation(.none) { progress = 0 }
            try? await Task.sleep(for: .milliseconds(32))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: storyDuration)) { progress = 1.0 }
            try? await Task.sleep(for: .seconds(storyDuration))
            guard !Task.isCancelled else { return }
            goToNext()
        }
        .confirmationDialog("delete story", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("delete story", role: .destructive) {
                deleteCurrentStory()
            }
            Button("cancel", role: .cancel) {}
        }
    }

    private var currentStory: WWAVStory? {
        guard currentIndex < group.stories.count else { return nil }
        return group.stories[currentIndex]
    }

    private func segmentProgress(for i: Int) -> CGFloat {
        if i < currentIndex { return 1.0 }
        if i == currentIndex { return progress }
        return 0.0
    }

    private func advanceTo(_ index: Int) {
        let clamped = max(0, index)
        guard clamped < group.stories.count else { dismiss(); return }
        currentIndex = clamped
        storyToken = UUID()
    }

    private func goToNext() { advanceTo(currentIndex + 1) }
    private func goToPrevious() { advanceTo(currentIndex - 1) }

    private func deleteCurrentStory() {
        guard let story = currentStory else { return }
        library.deleteStory(id: story.id, token: auth.token)
        dismiss()
    }
}

private struct StoryProgressSegment: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.35))
                Capsule()
                    .fill(Color.white)
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: 3)
    }
}

struct WWAVCameraImagePicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

private extension String {
    var normalizedStoryHandle: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }
}

private struct FeedComposerCard: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.theme) private var theme

    @FocusState private var focused: Bool
    @State private var selectedKind: PostKind = .text
    @State private var draft: String = ""
    @State private var imageItems: [PhotosPickerItem] = []
    @State private var imageData: [Data] = []
    @State private var imagePreviews: [UIImage] = []
    @State private var showingImageSourceDialog: Bool = false
    @State private var imageCameraOpen: Bool = false
    @State private var imageLibraryOpen: Bool = false

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmitText: Bool {
        !trimmedDraft.isEmpty || !imageData.isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProfileAvatar(url: auth.user?.profilePictureURL, size: 40)

            VStack(alignment: .leading, spacing: 12) {
                composerBody

                HStack(spacing: 8) {
                    ForEach(feedComposerKinds) { kind in
                        kindButton(kind)
                    }

                    Spacer(minLength: 0)

                    actionButtons
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.sand.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.glow.opacity(0.45),
                            theme.muted.opacity(WWAVOpacity.soft),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .onChange(of: imageItems) { _, newItems in
            Task { await loadTextImages(from: newItems) }
        }
        .photosPicker(
            isPresented: $imageLibraryOpen,
            selection: $imageItems,
            maxSelectionCount: 10,
            matching: .images,
            preferredItemEncoding: .compatible,
            photoLibrary: .shared()
        )
        .fullScreenCover(isPresented: $imageCameraOpen) {
            WWAVCameraImagePicker { image in
                appendCameraImage(image)
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("add image", isPresented: $showingImageSourceDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("open camera") {
                    imageCameraOpen = true
                }
            }
            Button("open camera roll") {
                imageLibraryOpen = true
            }
            Button("cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var composerBody: some View {
        if selectedKind == .text {
            VStack(alignment: .leading, spacing: 10) {
                TextField(
                    "",
                    text: $draft,
                    prompt: Text("what's happening?").foregroundStyle(theme.muted),
                    axis: .vertical
                )
                .focused($focused)
                .textFieldStyle(.plain)
                .font(.wwav(16, weight: .light))
                .foregroundStyle(theme.ink)
                .lineLimit(2...5)
                .frame(minHeight: 56, alignment: .topLeading)
                .padding(.horizontal, 2)
                .padding(.vertical, 6)

                if !imagePreviews.isEmpty {
                    composerImagePreview
                }
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: iconName(for: selectedKind))
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(theme.muted.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedKind.label) post")
                        .font(.wwav(16, weight: .medium, italic: true))
                        .foregroundStyle(theme.ink)
                    Text(kindSubtitle(for: selectedKind))
                        .font(.wwav(12, weight: .light, italic: true))
                        .foregroundStyle(theme.muted)
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: 56)
        }
    }

    private var actionButtons: some View {
        Group {
            if selectedKind == .text {
                HStack(spacing: 8) {
                    Button {
                        showingImageSourceDialog = true
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(imagePreviews.isEmpty ? theme.muted : theme.accent)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(theme.muted.opacity(WWAVOpacity.veil)))
                            .overlay(Circle().stroke(theme.muted.opacity(WWAVOpacity.soft), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    composerActionButton("save", publication: .draft, filled: false)
                    composerActionButton("post", publication: .published, filled: true)
                }
            } else {
                Button {
                    nav.compose(selectedKind)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 10, weight: .medium))
                        Text("open")
                            .font(.wwav(11, weight: .regular, italic: true))
                            .tracking(1.3)
                    }
                    .foregroundStyle(theme.glow)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 13)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func composerActionButton(
        _ label: String,
        publication: PublicationState,
        filled: Bool
    ) -> some View {
        let enabled = canSubmitText
        return Button {
            submitText(publication: publication)
        } label: {
            Text(label)
                .font(.wwav(11, weight: .regular, italic: true))
                .tracking(1.3)
                .foregroundStyle(filled ? theme.glow : theme.accent)
                .padding(.vertical, filled ? 9 : 7)
                .padding(.horizontal, 12)
                .background(
                    Capsule().fill(
                        filled
                            ? AnyShapeStyle(LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            : AnyShapeStyle(theme.sand.opacity(WWAVOpacity.firm))
                    )
                )
                .overlay(Capsule().stroke(theme.accent.opacity(filled ? 0 : 0.25), lineWidth: 1))
                .shadow(
                    color: (filled && enabled) ? theme.clay.opacity(0.30) : .clear,
                    radius: 10, y: 6
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func kindButton(_ kind: PostKind) -> some View {
        let active = selectedKind == kind
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                selectedKind = kind
            }
            focused = kind == .text
        } label: {
            Image(systemName: iconName(for: kind))
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? theme.glow : theme.muted)
                .frame(width: 30, height: 30)
                .background(
                    Group {
                        if active {
                            Circle().fill(
                                RadialGradient(
                                    colors: [
                                        theme.glow.opacity(0.55),
                                        theme.accent,
                                        theme.clayDeep,
                                    ],
                                    center: WWAVLight.sun,
                                    startRadius: 1, endRadius: 28
                                )
                            )
                        } else {
                            Circle().fill(theme.muted.opacity(WWAVOpacity.veil))
                        }
                    }
                )
                .overlay(
                    Circle().stroke(theme.muted.opacity(active ? 0 : WWAVOpacity.soft), lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func submitText(publication: PublicationState) {
        let body = trimmedDraft
        guard canSubmitText else { return }
        _ = library.createTextPost(
            title: "",
            body: body,
            images: imageData,
            token: auth.token,
            publication: publication
        )
        draft = ""
        imageItems = []
        imageData = []
        imagePreviews = []
        focused = false
    }

    private var composerImagePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(imagePreviews.count) image\(imagePreviews.count == 1 ? "" : "s")")
                    .font(.wwav(10, weight: .medium))
                    .tracking(1.3)
                    .foregroundStyle(theme.muted)
                Spacer()
                Button {
                    imageItems = []
                    imageData = []
                    imagePreviews = []
                } label: {
                    Text("clear")
                        .font(.wwav(10, weight: .light, italic: true))
                        .foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
            }

            TabView {
                ForEach(Array(imagePreviews.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: imagePreviews.count > 1 ? .automatic : .never))
            .frame(height: 154)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.muted.opacity(0.18), lineWidth: 1))
        }
    }

    private func loadTextImages(from items: [PhotosPickerItem]) async {
        var datas: [Data] = []
        var previews: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                datas.append(image.jpegData(compressionQuality: 0.85) ?? data)
                previews.append(image)
            }
        }
        await MainActor.run {
            imageData = datas
            imagePreviews = previews
        }
    }

    private func appendCameraImage(_ image: UIImage) {
        guard imagePreviews.count < 10 else { return }
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        imageData.append(data)
        imagePreviews.append(image)
    }

    private func iconName(for kind: PostKind) -> String {
        switch kind {
        case .music: return "music.note"
        case .album: return "rectangle.stack"
        case .radio: return "antenna.radiowaves.left.and.right"
        case .image: return "photo"
        case .text: return "text.bubble"
        case .video: return "play.rectangle"
        }
    }

    private func kindSubtitle(for kind: PostKind) -> String {
        switch kind {
        case .music: return "stem upload"
        case .album: return "tracklist post"
        case .radio: return "live queue"
        case .image: return "photo set"
        case .text: return "quick thought"
        case .video: return "video clip"
        }
    }
}

/// One feed cell. Header (avatar + name) + body that varies by post kind +
/// the social bar (plays / reply / repost / love). Edit-metadata is one tap
/// away on every cell so the user can patch a missing cover or rename.
struct FeedItemView: View {
    let track: Track
    let accent: Bool
    let onPlay: () -> Void
    @Environment(\.theme) private var theme
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @State private var showingComments: Bool = false
    @State private var editing: Bool = false
    @State private var previewExpanded: Bool = false
    @State private var previewPreparing: Bool = false
    @State private var previewFailed: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                nav.openProfile(for: track)
            } label: {
                ProfileAvatar(url: track.authorProfilePictureURL, size: 44)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button {
                        nav.openProfile(for: track)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(track.artist)
                                .font(.wwav(15, weight: .medium))
                                .foregroundStyle(theme.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(2)
                            Text("@\(track.handle)")
                                .font(.wwav(12, weight: .light))
                                .foregroundStyle(theme.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)
                        }
                        .minimumScaleFactor(0.85)
                    }
                    .buttonStyle(.plain)

                    PostKindBadge(kind: track.kind)
                        .fixedSize()
                    Spacer(minLength: 4)
                    Text(timeAgo(track.createdAt))
                        .font(.wwav(12, weight: .light))
                        .foregroundStyle(theme.muted)
                        .fixedSize()
                    if library.canFollow(track) {
                        FollowMiniButton(isFollowing: library.isFollowing(track)) {
                            Task { await library.toggleFollow(track: track, token: auth.token) }
                        }
                        .fixedSize()
                    }
                    if library.isAuthoredByCurrentUser(track) {
                        Button { editing = true } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(theme.muted)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                    }
                }

                bodyContent

                socialBar
                    .padding(.top, 10)

                if showingComments {
                    CommentsThread(track: track)
                        .padding(.top, 10)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .sheet(isPresented: $editing) {
            EditMetadataSheet(track: track)
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch track.kind {
        case .music: musicBody
        case .album: albumBody
        case .radio: textBody
        case .image: imageBody
        case .text:  textBody
        case .video: videoBody
        }
    }

    // MARK: – Music

    private var musicBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover.padding(.top, 12)
            titleRow
                .padding(.top, 12)
                .contentShape(Rectangle())
                .onTapGesture(perform: handleMusicBodyTap)
            if !track.bio.isEmpty {
                Text(track.bio)
                    .font(.wwav(13, weight: .light))
                    .foregroundStyle(theme.ink)
                    .padding(.top, 6)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: handleMusicBodyTap)
            }
        }
    }

    private var cover: some View {
        ZStack {
            if previewExpanded {
                FeedInlineStemPreview(
                    track: track,
                    isPreparing: previewPreparing,
                    failed: previewFailed,
                    onPreviewTap: onPlay
                )
            } else {
                FeedMediaImage(url: track.coverImageURL, fallbackAspectRatio: 1)
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onTapGesture { openInlinePreview() }
            }
        }
    }

    private func openInlinePreview() {
        guard track.kind == .music else { return }
        guard !previewExpanded else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            previewExpanded = true
        }
        previewFailed = false

        if player.currentTrack?.id == track.id {
            player.resume()
        } else {
            loadInlinePreview()
        }
    }

    private func handleMusicBodyTap() {
        if previewExpanded {
            onPlay()
        } else {
            openInlinePreview()
        }
    }

    private func loadInlinePreview() {
        if track.stems != nil {
            player.load(track)
            return
        }

        previewPreparing = true
        Task {
            let primed = await library.prepareForPlayback(track)
            await MainActor.run {
                previewPreparing = false
                guard previewExpanded, nav.active == .home else { return }
                guard let primed else {
                    previewFailed = true
                    return
                }
                player.load(primed)
            }
        }
    }

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(track.title)
                .wwavTitle(size: 22)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)

            if track.isRemix {
                HStack(spacing: 6) {
                    // Remix badge chip
                    Text("remix")
                        .font(.wwav(9, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(theme.glow)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.accent))

                    // Genealogy button — opens parent track
                    if let parent = library.parentTrack(of: track) {
                        Button {
                            nav.openPost(parent, in: library, with: player)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.left.circle")
                                    .font(.system(size: 10, weight: .regular))
                                Text("source")
                                    .font(.wwav(9, weight: .light))
                                    .tracking(1.0)
                            }
                            .foregroundStyle(theme.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.muted.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: – Album

    private var albumBody: some View {
        let tracks = library.albumTracks(for: track)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                FeedMediaImage(url: track.coverImageURL, fallbackAspectRatio: 1, cornerRadius: 14)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture(perform: onPlay)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.46)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .allowsHitTesting(false)

                VStack {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.stack.fill")
                                .font(.system(size: 10, weight: .medium))
                            Text("\(tracks.count) tracks")
                                .font(.wwav(10, weight: .medium, italic: true))
                                .tracking(1.1)
                        }
                        .foregroundStyle(theme.glow)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.24)))
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
                .allowsHitTesting(false)

                if !tracks.isEmpty {
                    Button(action: onPlay) {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 10, weight: .semibold))
                            Text("open album")
                                .font(.wwav(11, weight: .medium, italic: true))
                                .tracking(1.1)
                        }
                        .foregroundStyle(theme.glow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(theme.clayDeep.opacity(0.92)))
                        .overlay(Capsule().stroke(theme.glow.opacity(0.18), lineWidth: 1))
                        .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
            }
            .padding(.top, 12)

            titleRow.padding(.top, 12)
            if !track.bio.isEmpty {
                Text(track.bio)
                    .font(.wwav(13, weight: .light))
                    .foregroundStyle(theme.ink)
                    .padding(.top, 6)
            }

            VStack(spacing: 0) {
                if tracks.isEmpty {
                    Text("no songs in this album yet")
                        .font(.wwav(12, weight: .light, italic: true))
                        .foregroundStyle(theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(tracks.prefix(6).enumerated()), id: \.element.id) { index, song in
                        HStack(spacing: 10) {
                            Text(String(format: "%02d", index + 1))
                                .font(.wwav(10, weight: player.currentTrack?.id == song.id ? .medium : .light))
                                .monospacedDigit()
                                .foregroundStyle(player.currentTrack?.id == song.id ? theme.accent : theme.muted)
                                .frame(width: 28, alignment: .center)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .font(.wwav(13, weight: .medium))
                                    .foregroundStyle(theme.ink)
                                    .lineLimit(1)
                                Text("@\(song.handle)")
                                    .font(.wwav(10, weight: .light))
                                    .tracking(1)
                                    .foregroundStyle(theme.muted)
                            }
                            Spacer(minLength: 0)
                            if player.currentTrack?.id == song.id {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(theme.accent)
                            } else {
                                Image(systemName: "music.note")
                                    .font(.system(size: 10, weight: .regular))
                                    .foregroundStyle(theme.muted.opacity(0.72))
                            }
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                        if index < min(tracks.count, 6) - 1 {
                            Rectangle()
                                .fill(theme.muted.opacity(0.14))
                                .frame(height: 1)
                        }
                    }
                    if tracks.count > 6 {
                        Text("+ \(tracks.count - 6) more")
                            .font(.wwav(11, weight: .light, italic: true))
                            .foregroundStyle(theme.muted)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.sand.opacity(0.58)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.muted.opacity(0.16), lineWidth: 1))
            .padding(.top, 10)
        }
    }

    // MARK: – Image

    private var imageBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !track.resolvedImageURLs.isEmpty {
                ImageCarousel(urls: track.resolvedImageURLs)
                    .padding(.top, 12)
                    .onTapGesture { onPlay() }
            } else if case .separating = track.status {
                placeholderBox(text: "uploading images…")
            } else if case .uploading = track.status {
                placeholderBox(text: "uploading…")
            } else {
                placeholderBox(text: "no images")
            }
            if track.title != "image post" && !track.title.isEmpty {
                titleRow.padding(.top, 12)
            }
            if !track.bio.isEmpty {
                Text(track.bio)
                    .font(.wwav(14, weight: .light))
                    .foregroundStyle(theme.ink)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: – Text

    private var textBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if track.title != "text post" && !track.title.isEmpty {
                Text(track.title)
                    .wwavTitle(size: 22)
                    .padding(.top, 10)
            }
            Text(track.displayText.isEmpty ? "(empty)" : track.displayText)
                .font(.wwav(17, weight: .light))
                .foregroundStyle(theme.ink)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            if !track.resolvedImageURLs.isEmpty {
                ImageCarousel(urls: track.resolvedImageURLs)
                    .padding(.top, 10)
            }
        }
    }

    // MARK: – Video

    private var videoBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .center) {
                FeedMediaImage(url: track.coverImageURL, fallbackAspectRatio: 16.0 / 9.0)

                Button(action: onPlay) {
                    ZStack {
                        Circle().fill(
                            RadialGradient(colors: [theme.clay, theme.clayDeep],
                                           center: UnitPoint(x: 0.35, y: 0.30),
                                           startRadius: 2, endRadius: 50)
                        )
                        Triangle().fill(theme.glow).frame(width: 18, height: 22)
                            .offset(x: 2)
                    }
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.40), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)

            titleRow.padding(.top, 12)
            if !track.bio.isEmpty {
                Text(track.bio)
                    .font(.wwav(13, weight: .light))
                    .foregroundStyle(theme.ink)
                    .padding(.top, 6)
            }
        }
    }

    private func placeholderBox(text: String) -> some View {
        ZStack {
            LinearGradient(colors: [theme.clay.opacity(0.18), theme.clayDeep.opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(text).font(.wwav(13, weight: .light, italic: true)).foregroundStyle(theme.muted)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(theme.muted.opacity(0.20), lineWidth: 1))
        .padding(.top, 12)
    }

    private var socialBar: some View {
        HStack(spacing: 18) {
            Text("\(short(track.plays)) \(track.kind == .music || track.kind == .video ? "plays" : "views")")
                .font(.wwav(11, weight: .light))
                .tracking(1)
                .foregroundStyle(theme.muted)
                .monospacedDigit()

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showingComments.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showingComments ? "bubble.left.fill" : "bubble.left")
                        .font(.system(size: 12, weight: .regular))
                    Text(showingComments ? "hide" : "reply")
                        .font(.wwav(11, weight: .light))
                        .tracking(1)
                }
                .foregroundStyle(showingComments ? theme.accent : theme.muted)
                .padding(.vertical, 6).padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { library.toggleRepost(track: track) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 12, weight: track.reposted ? .semibold : .regular))
                    Text("\(track.reposts)")
                        .font(.wwav(11, weight: .light)).tracking(1)
                        .monospacedDigit()
                }
                .foregroundStyle(track.reposted ? theme.accent : theme.muted)
                .padding(.vertical, 6).padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await library.toggleLike(track: track, token: auth.token) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: track.liked ? "heart.fill" : "heart")
                        .font(.system(size: 12, weight: .regular))
                    Text("\(track.loves)")
                        .font(.wwav(11, weight: .light)).tracking(1)
                        .monospacedDigit()
                }
                .foregroundStyle(track.liked ? likedColor : theme.muted)
                .padding(.vertical, 6).padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    /// Hearts harmonize with the active palette: a soft red on the cool
    /// light-blue palette (where it reads as a familiar like), the palette
    /// accent on warmer colorways so it doesn't clash.
    private var likedColor: Color {
        // We can't introspect the palette case directly, so blend palette
        // accent with red: the red dominates on cool palettes (where accent
        // is blue) and the accent dominates on warm/red-adjacent palettes.
        Color.red.opacity(0.78).wwavBlended(with: theme.accent, by: 0.30)
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }

    private func short(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
        return "\(n)"
    }
}

private extension Color {
    /// Linear blend of two SwiftUI colors via UIColor for runtime accuracy.
    func wwavBlended(with other: Color, by t: CGFloat) -> Color {
        let a = UIColor(self)
        let b = UIColor(other)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return Color(
            red: Double(ar + (br - ar) * t),
            green: Double(ag + (bg - ag) * t),
            blue: Double(ab + (bb - ab) * t),
            opacity: Double(aa + (ba - aa) * t)
        )
    }
}

private struct PostKindBadge: View {
    let kind: PostKind
    @Environment(\.theme) private var theme
    var body: some View {
        if kind == .music { EmptyView() } else {
            Text(kind.label)
                .font(.wwav(9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(theme.muted.opacity(0.14))
                )
        }
    }
}

private struct FollowMiniButton: View {
    let isFollowing: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isFollowing ? "checkmark" : "plus")
                    .font(.system(size: 9, weight: .bold))
                Text(isFollowing ? "following" : "follow")
                    .font(.wwav(9, weight: .medium, italic: true))
                    .tracking(1)
            }
            .foregroundStyle(isFollowing ? theme.ink : theme.glow)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isFollowing ? theme.muted.opacity(0.12) : theme.accent)
            )
            .overlay(
                Capsule().stroke(theme.muted.opacity(isFollowing ? 0.18 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct FeedInlineStemPreview: View {
    let track: Track
    let isPreparing: Bool
    let failed: Bool
    /// Fired when the user taps the expanded feed preview. The embedded
    /// stem widget is rendered as preview art here; full controls live in
    /// the playback view.
    let onPreviewTap: () -> Void

    @EnvironmentObject var player: StemPlayerEngine
    @Environment(\.theme) private var theme

    private var isLoadedTrack: Bool {
        player.currentTrack?.id == track.id
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                // Background chrome. The full expanded preview receives the
                // navigation tap below, while the SceneKit widget is drawn
                // non-interactively inside feed cards.
                ZStack {
                    LinearGradient(
                        colors: [
                            theme.sand.opacity(0.92),
                            theme.clay.opacity(0.20),
                            theme.clayDeep.opacity(0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    CachedAsyncImage(url: track.coverImageURL, contentMode: .fill) {
                        Color.clear
                    }
                    .opacity(isLoadedTrack ? 0.14 : 0.34)
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                if isLoadedTrack {
                    StemPlayerWidget(engine: player, size: side * 0.82)
                        .frame(width: side * 0.90, height: side * 0.90)
                        .allowsHitTesting(false)
                }

                if isPreparing || failed || !isLoadedTrack {
                    VStack(spacing: 8) {
                        if isPreparing {
                            ProgressView()
                                .tint(theme.accent)
                                .scaleEffect(0.82)
                        } else {
                            Image(systemName: failed ? "exclamationmark.triangle" : "waveform")
                                .font(.system(size: 17, weight: .light))
                        }
                        Text(failed ? "stems unavailable" : "loading preview")
                            .font(.wwav(11, weight: .light, italic: true))
                            .tracking(1.4)
                    }
                    .foregroundStyle(theme.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(theme.sand.opacity(0.72)))
                    .overlay(Capsule().stroke(theme.muted.opacity(0.18), lineWidth: 1))
                    .allowsHitTesting(false)
                }

                VStack {
                    HStack {
                        Text("preview")
                            .font(.wwav(9, weight: .medium, italic: true))
                            .tracking(1.8)
                            .foregroundStyle(theme.muted)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { onPreviewTap() }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.muted.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct FeedMediaImage: View {
    let url: URL?
    let fallbackAspectRatio: CGFloat
    var cornerRadius: CGFloat = 16

    @Environment(\.theme) private var theme
    @State private var loadedAspectRatio: CGFloat?

    private var aspectRatio: CGFloat {
        Self.clampedFeedAspectRatio(loadedAspectRatio ?? fallbackAspectRatio)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            CachedAsyncImage(url: url, contentMode: .fit, onImageLoad: { image in
                let ratio = image.size.height > 0 ? image.size.width / image.size.height : fallbackAspectRatio
                loadedAspectRatio = ratio
            }) {
                Color.clear
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(0)
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(theme.muted.opacity(0.20), lineWidth: 1)
        )
        .clipped()
        .animation(.easeInOut(duration: 0.18), value: aspectRatio)
    }

    private static func clampedFeedAspectRatio(_ raw: CGFloat) -> CGFloat {
        guard raw.isFinite, raw > 0 else { return 1 }
        return min(max(raw, 4.0 / 5.0), 16.0 / 9.0)
    }
}

struct PublicProfileSheet: View {
    let route: PublicProfileRoute

    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private var posts: [Track] {
        library.posts(for: route)
    }

    private var totalViews: Int {
        posts.reduce(0) { $0 + $1.plays }
    }

    private var totalLoves: Int {
        posts.reduce(0) { $0 + $1.loves }
    }

    private var isCurrentUser: Bool {
        if let routeId = route.authorUserId, let myId = library.profile.remoteUserId {
            return routeId == myId
        }
        return route.handle.lowercased() == library.profile.handle.lowercased()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.pageRadial.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header

                        SoftRule()

                        if posts.isEmpty {
                            EmptyState(
                                title: "no posts yet",
                                body: "posts from @\(route.handle) will collect here once the feed sees them."
                            )
                            .frame(minHeight: 220)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(posts.enumerated()), id: \.element.id) { index, track in
                                    PublicProfilePostRow(track: track, index: index) {
                                        nav.openPost(track, in: library, with: player)
                                        dismiss()
                                    }
                                    if index < posts.count - 1 { SoftRule() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 28)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.ink)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(theme.muted.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                ProfileAvatar(url: route.profilePictureURL, size: 74)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(route.displayName)
                            .wwavTitle(size: 30)
                            .lineLimit(1)
                        if isCurrentUser {
                            Text("you")
                                .font(.wwav(9, weight: .medium, italic: true))
                                .tracking(1.3)
                                .foregroundStyle(theme.glow)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(theme.accent))
                        }
                    }
                    Text("@\(route.handle)")
                        .font(.wwav(13, weight: .light))
                        .foregroundStyle(theme.muted)
                }

                Spacer(minLength: 0)

                if !isCurrentUser {
                    Button {
                        Task { await library.toggleFollow(route: route, token: auth.token) }
                    } label: {
                        let following = library.isFollowing(
                            authorUserId: route.authorUserId,
                            handle: route.handle
                        )
                        HStack(spacing: 6) {
                            Image(systemName: following ? "checkmark" : "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text(following ? "following" : "follow")
                                .font(.wwav(11, weight: .medium, italic: true))
                                .tracking(1.3)
                        }
                        .foregroundStyle(following ? theme.ink : theme.glow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(following ? theme.muted.opacity(0.12) : theme.accent)
                        )
                        .overlay(Capsule().stroke(theme.muted.opacity(following ? 0.20 : 0), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                profileStat("\(posts.count)", "posts")
                profileStat(short(totalViews), "views")
                profileStat(short(totalLoves), "loves")
            }
        }
    }

    private func profileStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.wwav(16, weight: .medium))
                .foregroundStyle(theme.ink)
            Text(label)
                .font(.wwav(10, weight: .light))
                .tracking(1.2)
                .foregroundStyle(theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.sand.opacity(0.58)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.muted.opacity(0.16), lineWidth: 1))
    }

    private func short(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
        return "\(n)"
    }
}

private struct PublicProfilePostRow: View {
    let track: Track
    let index: Int
    let onTap: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                thumbnail
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.muted.opacity(0.22), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(track.title)
                            .wwavTitle(size: 20)
                            .lineLimit(1)
                        PostKindBadge(kind: track.kind)
                    }
                    Text(rowSubtitle)
                        .font(.wwav(11, weight: .light))
                        .tracking(1)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                    if track.kind == .text, !track.displayText.isEmpty {
                        Text(track.displayText)
                            .font(.wwav(12, weight: .light))
                            .foregroundStyle(theme.ink.opacity(0.80))
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.muted.opacity(0.65))
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch track.kind {
        case .music, .album, .video, .image:
            ZStack {
                LinearGradient(
                    colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                CachedAsyncImage(url: track.thumbnailURL) { Color.clear }
                if track.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                }
            }
        case .text, .radio:
            ZStack {
                LinearGradient(
                    colors: [theme.sand, theme.sandDeep.opacity(0.64)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: track.kind == .radio ? "antenna.radiowaves.left.and.right" : "text.bubble")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(theme.muted)
            }
        }
    }

    private var rowSubtitle: String {
        let views = track.kind == .music || track.kind == .video ? "plays" : "views"
        return "\(track.plays) \(views) · \(track.loves) loves"
    }
}

/// Fullscreen carousel viewer presented when an image post is tapped from
/// the feed. Tap anywhere outside the image to dismiss.
struct FullscreenImageViewer: View {
    let post: Track
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if !post.resolvedImageURLs.isEmpty {
                TabView {
                    ForEach(Array(post.resolvedImageURLs.enumerated()), id: \.offset) { _, url in
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().aspectRatio(contentMode: .fit)
                            case .empty:
                                ProgressView().tint(.white)
                            case .failure:
                                Image(systemName: "photo")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.white.opacity(0.5))
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .tabViewStyle(.page)
                .indexViewStyle(.page(backgroundDisplayMode: .always))
            }
            Button { nav.imageViewerPost = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Circle().fill(.black.opacity(0.5)))
            }
            .padding(.top, 50)
            .padding(.trailing, 18)
        }
    }
}

struct RadioLiveFeedSheet: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var listener: LiveRadioListener
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ZStack {
                theme.pageRadial.ignoresSafeArea()
                if !library.liveRadioSessions.isEmpty {
                    LiveBroadcastBackdrop()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("live radio").wwavTitle(size: 36)
                            if !library.liveRadioSessions.isEmpty {
                                LiveBroadcastHeaderMeter()
                                    .frame(height: 42)
                            }
                        }
                        .padding(.top, 8)

                        if library.liveRadioSessions.isEmpty {
                            EmptyState(
                                title: "nothing live",
                                body: "audio-only streams from DJs and musicians will appear here."
                            )
                            .frame(minHeight: 240)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(library.liveRadioSessions) { session in
                                    RadioLiveFeedRow(session: session) {
                                        listener.tuneIn(sessionId: session.id)
                                        nav.tuneIn(session: session)
                                        dismiss()
                                    }
                                }
                            }
                        }

                        Button {
                            nav.compose(.radio)
                            dismiss()
                        } label: {
                            Text("manage radio")
                                .font(.wwav(13, weight: .medium, italic: true))
                                .tracking(1.5)
                                .foregroundStyle(theme.glow)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Capsule().fill(theme.accent))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.ink)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(theme.muted.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct LiveBroadcastBackdrop: View {
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { geo in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let barCount = 18
                HStack(alignment: .center, spacing: 8) {
                    ForEach(0..<barCount, id: \.self) { index in
                        let phase = t * 2.4 + Double(index) * 0.42
                        let height = 42 + (sin(phase) + 1) * 34
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(theme.accent.opacity(0.055))
                            .frame(width: 5, height: height)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .padding(.top, 88)
            }
        }
    }
}

private struct LiveBroadcastHeaderMeter: View {
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<28, id: \.self) { index in
                    let phase = t * 3.2 + Double(index) * 0.36
                    let height = 8 + (sin(phase) + 1) * 14
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index.isMultiple(of: 3) ? theme.accent : theme.clayDeep.opacity(0.72))
                        .frame(width: 4, height: height)
                        .opacity(0.32 + (sin(phase + 0.8) + 1) * 0.22)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.sand.opacity(0.48)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.muted.opacity(0.16), lineWidth: 1))
        }
    }
}

private struct LiveBroadcastRowPulse: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.red.opacity(0.34), lineWidth: 1.4)
                .scaleEffect(pulsing ? 1.42 : 0.88)
                .opacity(pulsing ? 0 : 0.9)
            Circle()
                .stroke(Color.red.opacity(0.20), lineWidth: 1)
                .scaleEffect(pulsing ? 1.75 : 1.0)
                .opacity(pulsing ? 0 : 0.7)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.05).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

private struct RadioLiveFeedRow: View {
    let session: RadioSession
    let onListen: () -> Void

    @EnvironmentObject var library: TrackLibrary
    @Environment(\.theme) private var theme

    private var currentTrack: Track? {
        library.currentTrack(for: session)
    }

    var body: some View {
        Button(action: onListen) {
            HStack(spacing: 12) {
                ZStack {
                    LiveBroadcastRowPulse()
                    Circle().fill(theme.accent)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.glow)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(session.title)
                            .wwavTitle(size: 22)
                            .lineLimit(1)
                        Text("live")
                            .font(.wwav(9, weight: .medium, italic: true))
                            .tracking(1.3)
                            .foregroundStyle(theme.glow)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.accent))
                    }
                    Text("@\(session.hostHandle) · \(currentTrack?.title ?? "queue warming up")")
                        .font(.wwav(11, weight: .light))
                        .tracking(1)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                    if !session.notes.isEmpty {
                        Text(session.notes)
                            .font(.wwav(12, weight: .light))
                            .foregroundStyle(theme.ink.opacity(0.82))
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)
                Triangle()
                    .fill(theme.accent)
                    .frame(width: 10, height: 12)
                    .offset(x: 1)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.sand.opacity(0.64)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.muted.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    @Environment(\.theme) private var theme

    init(title: String, body: String) {
        self.title = title
        self.message = body
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Text(title).wwavTitle(size: 28)
            Text(message)
                .font(.wwav(13, weight: .light))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: rect.height))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height / 2))
        p.closeSubpath()
        return p
    }
}
